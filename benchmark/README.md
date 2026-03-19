# WebSocket Benchmarks

This benchmark compares two standalone websocket echo servers on the same local machine:

- `zwebsocket-bench-server`
- `uWebSockets` via `benchmark/uws_server.cpp`

The client in `benchmark/bench.zig`:

- opens N TCP connections
- performs one websocket upgrade per connection
- sends one prebuilt masked websocket frame per iteration
- discards the echoed frame by fixed byte count in the hot loop

This keeps the client overhead small and makes the comparison mostly about server-side frame parsing, dispatch, and echo writeback.

## Run

```sh
zig build bench-compare -Doptimize=ReleaseFast
```

Environment overrides:

```sh
CONNS=16 ITERS=200000 WARMUP=10000 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
```

Notes:

- `uWebSockets` and `uSockets` are cloned on demand under `.zig-cache/`.
- The `uWebSockets` benchmark build uses no TLS and no websocket compression.
- The default workload is a small binary echo frame, which is a transport-focused benchmark rather than an application benchmark.
