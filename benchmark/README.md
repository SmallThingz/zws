# WebSocket Benchmarks

This benchmark compares standalone websocket echo servers on the same local machine:

- `zwebsocket-bench-server`
- `uWebSockets` via `benchmark/uws_server.cpp`
- `uWebSockets` with a deadline-enabled websocket idle timeout via `benchmark/uws_server.cpp --deadline-ms=...`

The client in `benchmark/bench.zig` is shared across every peer:

- opens N TCP connections
- performs one websocket upgrade per connection
- sends prebuilt masked websocket frames in batches of configurable in-flight depth
- flushes once per batch and then discards the echoed frames by fixed byte count

This keeps the client overhead small and lets the benchmark cover both:

- ping-pong mode with `PIPELINE=1`
- pipelined mode with `PIPELINE>1`

That makes the comparison more useful for implementations such as `uWebSockets` that can benefit from higher in-flight depth while keeping the client implementation identical for every server under test.

## Run

```sh
zig build bench-compare -Doptimize=ReleaseFast
```

Environment overrides:

```sh
SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE_DEPTH=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
```

Notes:

- `uWebSockets` and `uSockets` are cloned on demand under `.zig-cache/`.
- The `uWebSockets` benchmark build uses no TLS and no websocket compression.
- The default workload is a small binary echo frame, which is a transport-focused benchmark rather than an application benchmark.

## Harness

`bench-compare` is the low-noise harness:

- builds `zwebsocket` binaries once
- builds `uWebSockets` benchmark server once
- runs four suites:
- `single / non-pipelined`
- `single / pipelined`
- `multi / non-pipelined`
- `multi / pipelined`
- runs strict interleaved rounds inside each suite (`zwebsocket`, `uWebSockets`, `uWebSockets+deadline`)
- prints a per-suite summary and a final matrix table

Environment overrides:

```sh
ROUNDS=6 SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE_DEPTH=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
ROUNDS=6 SINGLE_CONNS=1 MULTI_CONNS=32 ITERS=150000 WARMUP=10000 PIPELINE_DEPTH=16 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
UWS_DEADLINE_MS=30000 zig build bench-compare -Doptimize=ReleaseFast
```
