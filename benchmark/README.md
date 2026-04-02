# WebSocket Benchmarks

This benchmark compares standalone websocket echo servers on the same local machine:

- `zws` sync
- `zws` sync + deadline
- `zws` async
- `zws` async + deadline
- `uWebSockets` sync
- `uWebSockets` sync + deadline
- `uWebSockets` async
- `uWebSockets` async + deadline

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
ROUNDS=2 BENCH_TIMEOUT_MS=120000 ZWS_DEADLINE_MS=30000 UWS_DEADLINE_MS=30000 zig build bench-compare -Doptimize=ReleaseFast
```

Notes:

- `uWebSockets` and `uSockets` are cloned on demand under `.zig-cache/`.
- The `uWebSockets` benchmark build uses no TLS and no websocket compression.
- The default workload is a small binary echo frame, which is a transport-focused benchmark rather than an application benchmark.

## Latest Comparison

<!-- BENCH_COMPARE:START -->

Source: `benchmark/results/latest.json`

Config: host=`127.0.0.1` path=`/` rounds=1 single_conns=1 multi_conns=16 iters=10000 warmup=1000 pipeline_depth=8 msg_size=16 bench_timeout_ms=120000 zws_deadline_ms=30000 uws_deadline_ms=30000

| Suite | zws-sync | zws-sync+dl | zws-async | zws-async+dl | uWS-sync | uWS-sync+dl | uWS-async | uWS-async+dl |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| single / non-pipelined | 139085.54 | 128635.18 | 161432.17 | 167977.58 | 119853.35 | 167902.59 | 122270.87 | 122840.95 |
| single / pipelined | 392443.38 | 813879.58 | 1017902.46 | 909408.29 | 975390.60 | 725284.66 | 319092.63 | 398577.84 |
| multi / non-pipelined | 765231.80 | 733158.93 | 804311.41 | 732028.01 | 404972.05 | 416493.72 | 378398.48 | 374977.17 |
| multi / pipelined | 5271946.61 | 4381020.89 | 5369743.96 | 4864972.39 | 2914964.83 | 2734686.85 | 548342.21 | 532420.56 |

Fairness notes: all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.
<!-- BENCH_COMPARE:END -->

## Harness

`bench-compare` is the low-noise harness:

- builds `zws` binaries once
- builds `uWebSockets` benchmark server once
- runs four suites:
- `single / non-pipelined`
- `single / pipelined`
- `multi / non-pipelined`
- `multi / pipelined`
- runs strict interleaved rounds inside each suite across eight peers:
- `zws-sync`
- `zws-sync+dl`
- `zws-async`
- `zws-async+dl`
- `uWS-sync`
- `uWS-sync+dl`
- `uWS-async`
- `uWS-async+dl`
- prints a per-suite summary and a final matrix table
- defaults to `2` rounds per suite because the expanded matrix is much larger

Environment overrides:

```sh
ROUNDS=2 SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE_DEPTH=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
ROUNDS=2 SINGLE_CONNS=1 MULTI_CONNS=32 ITERS=150000 WARMUP=10000 PIPELINE_DEPTH=16 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
BENCH_TIMEOUT_MS=120000 ZWS_DEADLINE_MS=30000 UWS_DEADLINE_MS=30000 zig build bench-compare -Doptimize=ReleaseFast
```
