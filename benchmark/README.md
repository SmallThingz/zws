# WebSocket Benchmarks

This benchmark compares standalone websocket echo servers on the same local machine:

- `zwebsocket-bench-server`
- `uWebSockets` via `benchmark/uws_server.cpp`
- `uWebSockets` with a deadline-enabled websocket idle timeout via `benchmark/uws_server.cpp --deadline-ms=...`

The client in `benchmark/bench.zig`:

- opens N TCP connections
- performs one websocket upgrade per connection
- sends prebuilt masked websocket frames in batches of configurable in-flight depth
- flushes once per batch and then discards the echoed frames by fixed byte count

This keeps the client overhead small and lets the benchmark cover both:

- ping-pong mode with `PIPELINE=1`
- pipelined mode with `PIPELINE>1`

That makes the comparison more useful for implementations such as `uWebSockets` that can benefit from higher in-flight depth.

## Run

```sh
zig build bench-compare -Doptimize=ReleaseFast
```

Environment overrides:

```sh
CONNS=16 ITERS=200000 WARMUP=10000 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
```

Notes:

- `uWebSockets` and `uSockets` are cloned on demand under `.zig-cache/`.
- The `uWebSockets` benchmark build uses no TLS and no websocket compression.
- The default workload is a small binary echo frame, which is a transport-focused benchmark rather than an application benchmark.

## Harness

`bench-compare` is the low-noise harness:

- builds `zwebsocket` binaries once
- builds `uWebSockets` benchmark server once
- starts all benchmark servers once
- runs strict interleaved rounds (`zwebsocket`, `uWebSockets`, `uWebSockets+deadline`) and prints averages

Environment overrides:

```sh
ROUNDS=6 CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
ROUNDS=6 CONNS=1 ITERS=150000 WARMUP=10000 PIPELINE=1 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
UWS_DEADLINE_MS=30000 zig build bench-compare -Doptimize=ReleaseFast
```
