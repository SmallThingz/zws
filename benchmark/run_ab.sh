#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROUNDS="${ROUNDS:-6}"
HOST="${HOST:-127.0.0.1}"
WS_PATH="${WS_PATH:-/}"
CONNS="${CONNS:-16}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"
PIPELINE="${PIPELINE:-1}"
MSG_SIZE="${MSG_SIZE:-16}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"
ZWS_PORT="${ZWS_PORT:-9101}"
UWS_PORT="${UWS_PORT:-9102}"

ZWS_BENCH_BIN="$ROOT/zig-out/bin/zwebsocket-bench"
ZWS_SERVER_BIN="$ROOT/zig-out/bin/zwebsocket-bench-server"
UWS_SERVER_BIN="$ROOT/zig-out/bin/uws-bench-server"
UWS_DIR="$ROOT/.zig-cache/uWebSockets-bench"
USOCKETS_DIR="$ROOT/.zig-cache/uSockets-bench"

zws_pid=""
uws_pid=""

float_add() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a + b }'
}

float_div() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a / b }'
}

ensure_clone() {
    local dir="$1"
    local url="$2"
    if [[ -d "$dir" ]]; then
        return 0
    fi
    git clone --depth 1 "$url" "$dir"
}

cleanup() {
    if [[ -n "$zws_pid" ]]; then
        kill "$zws_pid" >/dev/null 2>&1 || true
        wait "$zws_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$uws_pid" ]]; then
        kill "$uws_pid" >/dev/null 2>&1 || true
        wait "$uws_pid" >/dev/null 2>&1 || true
    fi
}

build_zwebsocket_bins() {
    (
        cd "$ROOT"
        zig build install -Doptimize="$OPTIMIZE" >/dev/null
    )
}

build_uws_server_bin() {
    ensure_clone "$UWS_DIR" "https://github.com/uNetworking/uWebSockets"
    ensure_clone "$USOCKETS_DIR" "https://github.com/uNetworking/uSockets"

    (
        cd "$USOCKETS_DIR"
        make WITH_ZLIB=0 >/dev/null
    )

    g++ \
        -O3 \
        -march=native \
        -flto=auto \
        -std=c++2b \
        -DUWS_NO_ZLIB \
        -I"$UWS_DIR/src" \
        -I"$USOCKETS_DIR/src" \
        "$ROOT/benchmark/uws_server.cpp" \
        "$USOCKETS_DIR/uSockets.a" \
        -pthread \
        -o "$UWS_SERVER_BIN"
}

run_bench() {
    local label="$1"
    local port="$2"
    local out
    out="$(
        BENCH_LABEL="$label" "$ZWS_BENCH_BIN" \
            --host="$HOST" \
            --port="$port" \
            --path="$WS_PATH" \
            --conns="$CONNS" \
            --iters="$ITERS" \
            --warmup="$WARMUP" \
            --pipeline="$PIPELINE" \
            --msg-size="$MSG_SIZE" \
            --quiet 2>&1
    )"
    local msgps
    msgps="$(printf '%s\n' "$out" | sed -nE 's/.*: ([0-9]+\.[0-9]+) msg\/s,.*/\1/p' | tail -n1)"
    if [[ -z "$msgps" ]]; then
        echo "failed to parse benchmark output: $out" >&2
        exit 1
    fi
    printf '%s\n' "$msgps"
}

main() {
    trap cleanup EXIT

    echo "== build =="
    build_zwebsocket_bins
    build_uws_server_bin

    echo "== start servers =="
    "$ZWS_SERVER_BIN" --port="$ZWS_PORT" --pipeline="$PIPELINE" --msg-size="$MSG_SIZE" >/dev/null 2>&1 &
    zws_pid="$!"
    "$UWS_SERVER_BIN" --port="$UWS_PORT" >/dev/null 2>&1 &
    uws_pid="$!"
    sleep 0.2

    local zws_sum="0"
    local uws_sum="0"

    echo "== interleaved rounds (${ROUNDS}) =="
    for ((i = 1; i <= ROUNDS; i++)); do
        echo "[${i}/${ROUNDS}] zwebsocket"
        local zws_mps
        zws_mps="$(run_bench "zwebsocket" "$ZWS_PORT")"
        echo "  zwebsocket: ${zws_mps} msg/s"
        zws_sum="$(float_add "$zws_sum" "$zws_mps")"

        echo "[${i}/${ROUNDS}] uWebSockets"
        local uws_mps
        uws_mps="$(run_bench "uWebSockets" "$UWS_PORT")"
        echo "  uWebSockets: ${uws_mps} msg/s"
        uws_sum="$(float_add "$uws_sum" "$uws_mps")"
    done

    local zws_avg
    local uws_avg
    zws_avg="$(float_div "$zws_sum" "$ROUNDS")"
    uws_avg="$(float_div "$uws_sum" "$ROUNDS")"

    local delta
    local pct
    delta="$(awk -v z="$zws_avg" -v u="$uws_avg" 'BEGIN { printf "%.2f", z - u }')"
    pct="$(awk -v z="$zws_avg" -v u="$uws_avg" 'BEGIN { if (u == 0) { printf "inf" } else { printf "%.2f", ((z - u) / u) * 100 } }')"

    echo
    echo "== summary =="
    echo "zwebsocket avg: ${zws_avg} msg/s"
    echo "uWebSockets avg: ${uws_avg} msg/s"
    echo "delta: ${delta} msg/s (${pct}%)"
}

main "$@"
