# 🚀 zwebsocket

Low-allocation RFC 6455 websocket primitives for Zig with a specialized frame hot path, strict handshake validation, and `zhttp` integration helpers.

![zig](https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?logo=zig&logoColor=111)
![protocol](https://img.shields.io/badge/protocol-rfc%206455-0f766e)
![core](https://img.shields.io/badge/core-pure%20zig-111827)
![mode](https://img.shields.io/badge/io-streaming-1d4ed8)

## ⚡ Features

- 🧱 **RFC 6455 core**: frame parsing, masking, fragmentation, ping/pong, close handling, and server handshake validation.
- 🏎 **Tight hot path**: `Conn(comptime static)` specializes role and policy at comptime to keep runtime branches out of the core path.
- 📦 **Low-allocation reads**: stream frames chunk-by-chunk, read full frames, or borrow buffered payload slices when they fit.
- 🧠 **Strict protocol checks**: rejects malformed control frames, invalid close payloads, bad UTF-8, bad mask bits, and non-minimal extended lengths.
- 🔁 **Convenience helpers**: `readMessage`, `echoFrame`, `writeText`, `writeBinary`, `writePing`, `writePong`, and `writeClose`.
- 🪝 **`zhttp` helpers**: accept websocket upgrade requests from `zhttp` handlers and build `101 Switching Protocols` responses without re-parsing raw headers.
- 🧪 **Benchmarks + tests**: benchmark harness and an extensive in-tree test suite live alongside the library.

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

## 🪝 `zhttp` Integration

`zhttp` already provides the raw stream handoff needed for websocket upgrades. `zwebsocket` includes helpers for the current `zhttp` model:

- `zws.zhttpRequest(req)` converts a `zhttp` upgrade request into `ServerHandshakeRequest`.
- `zws.acceptZhttpUpgrade(req, opts)` validates the websocket handshake directly from a `zhttp` request.
- `zws.fillZhttpResponseHeaders(...)` and `zws.makeZhttpUpgradeResponse(...)` build the `101` response header set.

Example handler shape:

```zig
const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zwebsocket");

const WsHeaders = struct {
    connection: zhttp.parse.Optional(zhttp.parse.String),
    upgrade: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_key: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_version: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_protocol: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_extensions: zhttp.parse.Optional(zhttp.parse.String),
    origin: zhttp.parse.Optional(zhttp.parse.String),
    host: zhttp.parse.Optional(zhttp.parse.String),
};

fn upgrade(req: anytype) !zhttp.Res {
    const accepted = try zws.acceptZhttpUpgrade(req, .{});
    const ZhttpHeader = std.meta.Child(@FieldType(zhttp.Res, "headers"));
    var headers: [4]ZhttpHeader = undefined;
    return try zws.makeZhttpUpgradeResponse(zhttp.Res, ZhttpHeader, headers[0..], accepted);
}
```

The route must declare those websocket headers in its `zhttp` `.headers` schema so `req.header(...)` is available.

## 📎 In-Tree Files

- `src/root.zig`: public package surface
- `src/conn.zig`: connection state machine and frame I/O
- `src/handshake.zig`: server handshake validation and response generation
- `src/zhttp_compat.zig`: `zhttp` adapter helpers
- `benchmark/bench.zig`: benchmark client
- `benchmark/zwebsocket_server.zig`: standalone benchmark server

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
zig build bench-server
zig build bench-compare -Doptimize=ReleaseFast
```

## ⚠️ Current Scope

`zwebsocket` is intentionally focused on a small websocket core.

- Server-side RFC 6455 handshake validation is included.
- Connection state is synchronous and stream-oriented.
- No TLS, HTTP server, or event loop abstraction is bundled.
- `permessage-deflate` and extension negotiation are not implemented.
- The `zhttp` adapter targets the current upgrade-route model rather than trying to wrap all of `zhttp`.
