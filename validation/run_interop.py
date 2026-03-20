#!/usr/bin/env python3
import argparse
import os
import pathlib
import socket
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
VALIDATION_DIR = ROOT / "validation"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-bin", required=True)
    parser.add_argument("--client-bin", required=True)
    parser.add_argument("--port-base", type=int, default=9100)
    return parser.parse_args()


def ensure_node_deps() -> None:
    if (VALIDATION_DIR / "node_modules" / "ws" / "package.json").exists():
        return
    subprocess.run(
        ["npm", "install", "--prefix", str(VALIDATION_DIR)],
        cwd=ROOT,
        check=True,
    )


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


def spawn_server(cmd: list[str], port: int) -> subprocess.Popen[str]:
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        wait_for_port(port)
        return proc
    except BaseException:
        stop_process(proc)
        raise


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def run_client(cmd: list[str]) -> None:
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"client failed: {' '.join(cmd)}\n{result.stdout}")


def scenario(name: str, server_cmd: list[str], client_cmd: list[str], port: int) -> None:
    print(f"[interop] {name}")
    proc = spawn_server(server_cmd, port)
    try:
        run_client(client_cmd)
    finally:
        stop_process(proc)
        output = proc.stdout.read() if proc.stdout else ""
        if proc.returncode not in (None, 0, -15):
            raise RuntimeError(f"server failed during {name}\n{output}")


def main() -> int:
    args = parse_args()
    ensure_node_deps()

    server_bin = pathlib.Path(args.server_bin)
    client_bin = pathlib.Path(args.client_bin)
    port = args.port_base

    scenarios = [
        (
            "node-ws client -> zwebsocket server",
            port,
            [str(server_bin), f"--port={port}"],
            ["node", str(VALIDATION_DIR / "ws_peer.mjs"), "client", f"--url=ws://127.0.0.1:{port}/"],
        ),
        (
            "node-ws client -> zwebsocket server (permessage-deflate)",
            port + 1,
            [str(server_bin), f"--port={port + 1}", "--compression"],
            ["node", str(VALIDATION_DIR / "ws_peer.mjs"), "client", f"--url=ws://127.0.0.1:{port + 1}/", "--compression"],
        ),
        (
            "aiohttp client -> zwebsocket server",
            port + 2,
            [str(server_bin), f"--port={port + 2}"],
            ["python3", str(VALIDATION_DIR / "aiohttp_peer.py"), "client", f"--url=ws://127.0.0.1:{port + 2}/"],
        ),
        (
            "aiohttp client -> zwebsocket server (permessage-deflate)",
            port + 3,
            [str(server_bin), f"--port={port + 3}", "--compression"],
            ["python3", str(VALIDATION_DIR / "aiohttp_peer.py"), "client", f"--url=ws://127.0.0.1:{port + 3}/", "--compression"],
        ),
        (
            "zwebsocket client -> node-ws server",
            port + 4,
            ["node", str(VALIDATION_DIR / "ws_peer.mjs"), "server", f"--port={port + 4}"],
            [str(client_bin), f"--port={port + 4}"],
        ),
        (
            "zwebsocket client -> node-ws server (permessage-deflate)",
            port + 5,
            ["node", str(VALIDATION_DIR / "ws_peer.mjs"), "server", f"--port={port + 5}", "--compression"],
            [str(client_bin), f"--port={port + 5}", "--compression"],
        ),
        (
            "zwebsocket client -> aiohttp server",
            port + 6,
            ["python3", str(VALIDATION_DIR / "aiohttp_peer.py"), "server", f"--port={port + 6}"],
            [str(client_bin), f"--port={port + 6}"],
        ),
        (
            "zwebsocket client -> aiohttp server (permessage-deflate)",
            port + 7,
            ["python3", str(VALIDATION_DIR / "aiohttp_peer.py"), "server", f"--port={port + 7}", "--compression"],
            [str(client_bin), f"--port={port + 7}", "--compression"],
        ),
    ]

    try:
        for name, scenario_port, server_cmd, client_cmd in scenarios:
            scenario(name, server_cmd, client_cmd, scenario_port)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print("[interop] all scenarios passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
