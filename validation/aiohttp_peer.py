#!/usr/bin/env python3
import argparse
import asyncio
import aiohttp
from aiohttp import web, WSMsgType

TEXT_PAYLOAD = "zwebsocket interop text payload with enough repetition to exercise permessage-deflate"
BINARY_PAYLOAD = bytes(((i * 13 + 7) & 0xFF) for i in range(256))


async def run_client(url: str, compression: bool) -> None:
    compress = 15 if compression else 0
    timeout = aiohttp.ClientTimeout(total=None)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.ws_connect(url, compress=compress, max_msg_size=4 * 1024 * 1024) as ws:
            await ws.send_str(TEXT_PAYLOAD)
            msg = await ws.receive()
            if msg.type is not WSMsgType.TEXT or msg.data != TEXT_PAYLOAD:
                raise RuntimeError("text echo mismatch")

            await ws.send_bytes(BINARY_PAYLOAD)
            msg = await ws.receive()
            if msg.type is not WSMsgType.BINARY or bytes(msg.data) != BINARY_PAYLOAD:
                raise RuntimeError("binary echo mismatch")

            await ws.close()


async def echo_handler(request: web.Request) -> web.WebSocketResponse:
    compression = request.app["compression"]
    ws = web.WebSocketResponse(compress=compression, max_msg_size=4 * 1024 * 1024)
    await ws.prepare(request)

    async for msg in ws:
        if msg.type is WSMsgType.TEXT:
            await ws.send_str(msg.data)
        elif msg.type is WSMsgType.BINARY:
            await ws.send_bytes(msg.data)
        elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED):
            break
        elif msg.type is WSMsgType.ERROR:
            raise ws.exception() or RuntimeError("websocket error")
    return ws


async def run_server(port: int, compression: bool) -> None:
    app = web.Application()
    app["compression"] = compression
    app.router.add_get("/", echo_handler)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", port)
    await site.start()
    await asyncio.Future()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    server = sub.add_parser("server")
    server.add_argument("--port", type=int, default=9100)
    server.add_argument("--compression", action="store_true")

    client = sub.add_parser("client")
    client.add_argument("--url", default="ws://127.0.0.1:9100/")
    client.add_argument("--compression", action="store_true")
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    if args.mode == "server":
        await run_server(args.port, args.compression)
    else:
        await run_client(args.url, args.compression)


if __name__ == "__main__":
    asyncio.run(main())
