#!/usr/bin/env python3
import argparse
import asyncio
import pathlib
import socket
import subprocess
import sys
import time

import aiohttp


ROOT = pathlib.Path(__file__).resolve().parent.parent
TEXT_BASE = "zwebsocket soak payload "
BINARY_PAYLOAD = bytes(((i * 29 + 11) & 0xFF) for i in range(512))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-bin", required=True)
    parser.add_argument("--port", type=int, default=9200)
    parser.add_argument("--connections", type=int, default=32)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--compression", action="store_true")
    return parser.parse_args()


def wait_for_port(port: int, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError as err:
            last_err = err
            time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for 127.0.0.1:{port}: {last_err}")


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


async def worker(session: aiohttp.ClientSession, url: str, compression: bool, idx: int, end_at: float) -> int:
    compress = 15 if compression else 0
    count = 0
    async with session.ws_connect(url, compress=compress, max_msg_size=4 * 1024 * 1024) as ws:
        while time.time() < end_at:
            text_payload = f"{TEXT_BASE}{idx} " + ("x" * 256)
            await ws.send_str(text_payload)
            msg = await ws.receive()
            if msg.type is not aiohttp.WSMsgType.TEXT or msg.data != text_payload:
                raise RuntimeError("text echo mismatch during soak")
            count += 1

            await ws.send_bytes(BINARY_PAYLOAD)
            msg = await ws.receive()
            if msg.type is not aiohttp.WSMsgType.BINARY or bytes(msg.data) != BINARY_PAYLOAD:
                raise RuntimeError("binary echo mismatch during soak")
            count += 1

        await ws.close()
    return count


async def run_soak(args: argparse.Namespace) -> int:
    url = f"ws://127.0.0.1:{args.port}/"
    timeout = aiohttp.ClientTimeout(total=None)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        end_at = time.time() + args.duration
        counts = await asyncio.gather(*[
            worker(session, url, args.compression, idx, end_at)
            for idx in range(args.connections)
        ])
    return sum(counts)


def main() -> int:
    args = parse_args()
    server_cmd = [args.server_bin, f"--port={args.port}"]
    if args.compression:
        server_cmd.append("--compression")
    exit_code = 0

    proc = subprocess.Popen(
        server_cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        wait_for_port(args.port)
        started = time.time()
        total_messages = asyncio.run(run_soak(args))
        elapsed = time.time() - started
        rate = total_messages / elapsed if elapsed > 0 else 0.0
        print(
            f"[soak] connections={args.connections} duration={args.duration:.1f}s compression={args.compression} "
            f"messages={total_messages} msg_per_sec={rate:.2f}"
        )
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        exit_code = 1
    finally:
        stop_process(proc)
        output = proc.stdout.read() if proc.stdout else ""
        if proc.returncode not in (None, 0, -15):
            print(output, file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
