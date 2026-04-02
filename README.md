# 🚀 zwebsocket

Low-allocation RFC 6455 websocket primitives for Zig with a specialized frame hot path, strict handshake validation, and `permessage-deflate`.

![zig](https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?logo=zig&logoColor=111)
![protocol](https://img.shields.io/badge/protocol-rfc%206455-0f766e)
![core](https://img.shields.io/badge/core-pure%20zig-111827)
![mode](https://img.shields.io/badge/io-streaming-1d4ed8)

## ⚡ Features

- 🧱 **RFC 6455 core**: frame parsing, masking, fragmentation, ping/pong, close handling, and server handshake validation.
- 🏎 **Tight hot path**: `Conn(comptime static)` specializes role and policy at comptime to keep runtime branches out of the core path.
- 📦 **Low-allocation reads**: stream frames chunk-by-chunk, read full frames, or borrow buffered payload slices when they fit.
- 🧠 **Strict protocol checks**: rejects malformed control frames, invalid close payloads, bad UTF-8, bad mask bits, and non-minimal extended lengths.
- 🗜 **`permessage-deflate`**: handshake negotiation plus compressed message read/write support, with `server_no_context_takeover` and `client_no_context_takeover`.
- 🧠 **Optional context takeover**: compile-time `Conn.Type` toggle (`permessage_deflate_context_takeover`) enables cross-message compression state when negotiated.
- 🎛 **Per-message compression policy**: compile-time `Conn.Type` knobs decide when messages are compressed (`permessage_deflate_min_payload_len`, `permessage_deflate_require_compression_gain`).
- ⏱ **Timeout hooks**: optional read, write, and flush time budgets with typed runtime hooks for framework-owned transports.
- 🔁 **Convenience helpers**: `readMessage`, `writeText`, `writeBinary`, `writePing`, `writePong`, and `writeClose`.
- 🧩 **Typed message handlers**: `Handler.run(...)` with typed user state, sync/async execution modes, and response coercion from `[]const u8`, `[][]const u8`, or structs with `body`.
- 🧪 **Validation stack**: unit tests, fuzz/property tests, a cross-library interop matrix, soak runners, and benchmarks live alongside the library.

## 🚀 Quick Start

After you have already accepted the websocket upgrade and have a reader/writer pair:

```zig
const std = @import("std");
const zws = @import("zwebsocket");

fn runEcho(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var conn = zws.Conn.Server.init(reader, writer, .{});
    var message_buf: [4096]u8 = undefined;

    while (true) {
        const message = conn.readMessage(message_buf[0..]) catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => |e| return e,
        };
        switch (message.opcode) {
            .text => try conn.writeText(message.payload),
            .binary => try conn.writeBinary(message.payload),
        }
        try conn.flush();
    }
}
```

For explicit handshake validation on a raw stream:

```zig
const negotiated = try zws.Handshake.upgrade(reader, writer);
_ = negotiated;
try writer.flush();
```

For a full standalone echo server example:

```bash
zig build examples -Dexample=echo-server -- --port=9001 --compression
```

For a frame-oriented echo server that stays on the low-level frame APIs:

```bash
zig build examples -Dexample=frame-echo-server -- --port=9002
```

For a simple websocket client that performs the HTTP upgrade and then uses `zws.Conn.Client`:

```bash
zig build examples -Dexample=client -- --host=127.0.0.1 --port=9001 --message=hello
```

For a typed per-message handler loop with user-owned state:

```zig
const io = std.Io.Threaded.global_single_threaded.io();
var app_state = AppState{};
var scratch = zws.Handler.Scratch(.{
    .receive_mode = .solid_slice,
}).init();

fn onMessage(ctx: *zws.Handler.SliceContext(.{
    .receive_mode = .solid_slice,
}, zws.Conn.Server, AppState)) ![]const u8 {
    ctx.state.seen += 1;
    return ctx.message.payload;
}

try zws.Handler.run(.{
    .receive_mode = .solid_slice,
}, io, &conn, &app_state, &scratch, onMessage);
```

## 📦 Installation

Add as a dependency:

```bash
zig fetch --save <git-or-tarball-url>
```

`build.zig`:

```zig
const zws_dep = b.dependency("zwebsocket", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zwebsocket", zws_dep.module("zwebsocket"));
```

## 🧩 Library API (At a Glance)

- `zws.Conn.Type(.{ ... })` creates a websocket connection type specialized for a fixed role and policy set.
- `zws.Conn.Default`, `zws.Conn.Server`, and `zws.Conn.Client` are the common aliases.
- Low-level read path:
  `beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`, `readFrameBorrowed`.
- Convenience read path:
  `readFrame`, `readMessage`, `readMessageBorrowed`.
- Write path:
  `writeFrame`, `writeText`, `writeBinary`, `writePing`, `writePong`, `writeClose`, `flush`.
- Handshake path:
  `Handshake.computeAcceptKey`, `Handshake.upgrade`.
- Compression path:
  `Extensions.PerMessageDeflate`, `Conn.PerMessageDeflateConfig`, `Conn.Config.permessage_deflate`.
- Runtime hooks:
  `Observe.TimeoutConfig`, `Observe.DefaultRuntimeHooks`, `Conn.TypeWithHooks(...)`.
- Message handler loop:
  `Handler.run(...)`, `Handler.Options`, `Handler.SliceContext(...)`, `Handler.StreamContext(...)`, `Handler.Response`.

## 📚 Docs

- [`DOCUMENTATION.md`](./DOCUMENTATION.md): API stability, transport/runtime expectations, deployment notes, and validation entry points.

## 📎 In-Tree Files

- `src/root.zig`: public package surface
- `src/conn.zig`: connection state machine and frame I/O
- `src/handshake.zig`: server upgrade parsing, validation, and `101` response writing
- `src/extensions.zig`: extension negotiation helpers
- `benchmark/bench.zig`: benchmark client
- `benchmark/zwebsocket_server.zig`: standalone benchmark server
- `examples/echo_server.zig`: standalone echo server example
- `examples/frame_echo_server.zig`: frame-level echo server example using `readFrameBorrowed`
- `examples/ws_client.zig`: standalone client example with manual HTTP upgrade
- `validation/`: Zig interop and soak runners, plus peer dependency metadata

## 🏁 Benchmarking

Benchmark support lives under [`benchmark/`](./benchmark/).

```bash
zig build bench-compare -Doptimize=ReleaseFast
```

Environment overrides:

```bash
SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
SINGLE_CONNS=1 MULTI_CONNS=16 ITERS=200000 WARMUP=10000 PIPELINE_DEPTH=8 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
ROUNDS=2 BENCH_TIMEOUT_MS=120000 ZWS_DEADLINE_MS=30000 UWS_DEADLINE_MS=30000 zig build bench-compare -Doptimize=ReleaseFast
```

## Latest Benchmark Comparison

<!-- BENCH_COMPARE:START -->

Source: `benchmark/results/latest.json`

Config: host=`127.0.0.1` path=`/` rounds=1 single_conns=1 multi_conns=16 iters=10000 warmup=1000 pipeline_depth=8 msg_size=16 bench_timeout_ms=120000 zws_deadline_ms=30000 uws_deadline_ms=30000

| Suite | sync | sync+dl | async | async+dl |
|---|---:|---:|---:|---:|
| single / non-pipelined | +16.05% | -23.39% | +32.03% | +36.74% |
| single / pipelined | -59.77% | +12.22% | +219.00% | +128.16% |
| multi / non-pipelined | +88.96% | +76.03% | +112.56% | +95.22% |
| multi / pipelined | +80.86% | +60.20% | +879.27% | +813.75% |

Values show `zws` vs matching `uWS` throughput delta.
Fairness notes: all peers use the same benchmark client, identical per-suite client settings, and the matrix runs strict interleaved rounds for every peer inside each suite.
<!-- BENCH_COMPARE:END -->

For benchmark details, see [`benchmark/README.md`](./benchmark/README.md).

## 🧪 Build and Validation

```bash
zig build test
zig build bench -- --conns=1 --iters=2000 --warmup=100
zig build interop
zig build soak
zig build validate
zig build examples
zig build bench-compare -Doptimize=ReleaseFast
```

## ⚠️ Current Scope

`zwebsocket` is intentionally focused on a small websocket core.

- Server-side RFC 6455 handshake validation is included.
- Connection state is synchronous and stream-oriented.
- `permessage-deflate` is implemented and negotiated when enabled.
- Compression is disabled by default (`Config.permessage_deflate = null`).
- Even when negotiated, outgoing compression is opt-in (`Conn.PerMessageDeflateConfig.compress_outgoing = false` by default).
- Context takeover support is disabled by default (`Conn.StaticConfig.permessage_deflate_context_takeover = false`).
- When enabled, `Conn.StaticConfig` defaults (`permessage_deflate_min_payload_len = 64`, `permessage_deflate_require_compression_gain = true`) skip tiny messages and avoid non-beneficial compression.
- No TLS or HTTP server framework is bundled; use the raw stream API or the example server as the integration point.
- `permessage-deflate` framing is implemented with `std.compress.flate` (both non-takeover and optional context-takeover paths).
