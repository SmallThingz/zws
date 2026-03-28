#!/usr/bin/env python3
import argparse
import base64
import os
import socket
import struct


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9100)
    return parser.parse_args()


def recv_exact(sock: socket.socket, n: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < n:
        chunk = sock.recv(n - len(chunks))
        if not chunk:
            raise RuntimeError("unexpected EOF")
        chunks.extend(chunk)
    return bytes(chunks)


def send_masked_text_frame(sock: socket.socket, payload: bytes) -> None:
    if len(payload) > 125:
        raise ValueError("payload too large for regression client")
    mask = b"\x11\x22\x33\x44"
    masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
    sock.sendall(bytes((0x81, 0x80 | len(payload))) + mask + masked)


def recv_text_frame(sock: socket.socket) -> bytes:
    first, second = recv_exact(sock, 2)
    if first != 0x81:
        raise RuntimeError(f"unexpected opcode/flags: 0x{first:02x}")
    payload_len = second & 0x7F
    masked = (second & 0x80) != 0
    if masked:
        raise RuntimeError("server frame must not be masked")
    if payload_len == 126:
        payload_len = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif payload_len == 127:
        payload_len = struct.unpack("!Q", recv_exact(sock, 8))[0]
    return recv_exact(sock, payload_len)


def main() -> int:
    args = parse_args()
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {args.host}:{args.port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits, permessage-deflate\r\n"
        f"\r\n"
    ).encode("ascii")

    with socket.create_connection((args.host, args.port), timeout=5.0) as sock:
        sock.sendall(request)

        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                raise RuntimeError("unexpected EOF during handshake")
            response.extend(chunk)

        header_block, pending = bytes(response).split(b"\r\n\r\n", 1)
        header_text = header_block.decode("ascii")
        if "101 Switching Protocols" not in header_text:
            raise RuntimeError(f"handshake failed:\n{header_text}")
        if "sec-websocket-extensions:" not in header_text.lower():
            raise RuntimeError(f"compression was not negotiated:\n{header_text}")

        if pending:
            raise RuntimeError("unexpected post-handshake bytes before first frame")

        payload = b"repeat-offer-ok"
        send_masked_text_frame(sock, payload)
        echoed = recv_text_frame(sock)
        if echoed != payload:
            raise RuntimeError(f"echo mismatch: expected {payload!r}, got {echoed!r}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
