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
- 🔁 **Convenience helpers**: `readMessage`, `echoFrame`, `writeText`, `writeBinary`, `writePing`, `writePong`, and `writeClose`.
- 🧪 **Validation stack**: unit tests, fuzz/property tests, a cross-library interop matrix, soak runners, and benchmarks live alongside the library.

## 🚀 Quick Start

After you have already accepted the websocket upgrade and have a reader/writer pair:

```zig
const std = @import("std");
const zws = @import("zwebsocket");

fn runEcho(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var conn = zws.ServerConn.init(reader, writer, .{});
    var scratch: [4096]u8 = undefined;

    while (true) {
        _ = conn.echoFrame(scratch[0..]) catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => |e| return e,
        };
        try conn.flush();
    }
}
```

For explicit handshake validation on a raw stream:

```zig
const accepted = try zws.acceptServerHandshake(req, .{});
try zws.writeServerHandshakeResponse(writer, accepted);
```

For a full standalone echo server example:

```bash
zig build example-echo-server -- --port=9001 --compression
```

For a frame-oriented echo server that stays on `echoFrame(...)`:

```bash
zig build example-frame-echo-server -- --port=9002
```

For a simple websocket client that performs the HTTP upgrade and then uses `zws.ClientConn`:

```bash
zig build example-client -- --host=127.0.0.1 --port=9001 --message=hello
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

- `zws.ConnType(.{ ... })` creates a websocket connection type specialized for a fixed role and policy set.
- `zws.Conn`, `zws.ServerConn`, and `zws.ClientConn` are the common aliases.
- Low-level read path:
  `beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`, `readFrameBorrowed`.
- Convenience read path:
  `readFrame`, `readMessage`, `echoFrame`.
- Write path:
  `writeFrame`, `writeText`, `writeBinary`, `writePing`, `writePong`, `writeClose`, `flush`.
- Handshake path:
  `computeAcceptKey`, `acceptServerHandshake`, `writeServerHandshakeResponse`, `serverHandshake`.
- Compression path:
  `PerMessageDeflate`, `PerMessageDeflateConfig`, `ServerHandshakeResponse.permessage_deflate`, `Config.permessage_deflate`.

## 📚 Docs

- [`DOCUMENTATION.md`](./DOCUMENTATION.md): API stability, transport/runtime expectations, deployment notes, and validation entry points.

## 📎 In-Tree Files

- `src/root.zig`: public package surface
- `src/conn.zig`: connection state machine and frame I/O
- `src/handshake.zig`: server handshake validation and response generation
- `src/extensions.zig`: extension negotiation helpers
- `benchmark/bench.zig`: benchmark client
- `benchmark/zwebsocket_server.zig`: standalone benchmark server
- `examples/echo_server.zig`: standalone echo server example
- `examples/frame_echo_server.zig`: frame-level echo server example using `echoFrame`
- `examples/ws_client.zig`: standalone client example with manual HTTP upgrade
- `validation/`: interop peers and soak runners

## 🏁 Benchmarking

Benchmark support lives under [`benchmark/`](./benchmark/).

```bash
zig build bench-compare -Doptimize=ReleaseFast
```

Environment overrides:

```bash
CONNS=16 ITERS=200000 WARMUP=10000 MSG_SIZE=16 zig build bench-compare -Doptimize=ReleaseFast
```

For benchmark details, see [`benchmark/README.md`](./benchmark/README.md).

## 🧪 Build and Validation

```bash
zig build test
zig build interop
zig build soak
zig build validate
zig build examples
zig build bench-server
zig build bench-compare -Doptimize=ReleaseFast
```

## ⚠️ Current Scope

`zwebsocket` is intentionally focused on a small websocket core.

- Server-side RFC 6455 handshake validation is included.
- Connection state is synchronous and stream-oriented.
- `permessage-deflate` is implemented and negotiated when enabled.
- No TLS or HTTP server framework is bundled; use the raw stream API or the example server as the integration point.
- Compression support links against system `zlib`. If you do not enable `permessage-deflate`, the core RFC 6455 path remains pure Zig.
