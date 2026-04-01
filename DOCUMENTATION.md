# Documentation

## API Stability

`zwebsocket` is still pre-`1.0`, but it now has an explicit compatibility policy.

### Stable Surface

The public exports in `src/root.zig` are the supported package API:

- `Handshake`
- `Conn`
- frame/message read and write helpers
- `Extensions.PerMessageDeflate` and `Conn.PerMessageDeflateConfig`
- timeout runtime hook types (`Observe.TimeoutConfig`, `Observe.DefaultRuntimeHooks`)

Within a patch release, those symbols and their documented semantics should not break.

### Provisional Surface

These areas are still allowed to evolve more aggressively before `1.0`:

- the exact shape of `Conn.Config` and `Conn.StaticConfig` if a feature needs another field
- compression tuning knobs beyond the negotiated `permessage-deflate` parameters
- validation/build helper steps under `zig build`

If a breaking change lands in a provisional area, it should come with a migration note in the changelog or commit message.

### Breaking-Change Policy

Before `1.0`:

- patch releases should be source-compatible for the stable surface
- minor releases may contain targeted breaking changes, but only with clear motivation
- protocol correctness fixes are allowed even if they cause previously-accepted malformed traffic to start failing

After `1.0`, the intent is standard semver for the stable surface.

## Transports

`zwebsocket` is a synchronous, stream-oriented websocket core.

### Expected Integration Shape

The library expects:

- a reader positioned at the first websocket frame byte
- a writer targeting the same upgraded TCP stream
- the HTTP upgrade already accepted, or a caller using the handshake helpers to do it

That makes it fit two common models:

- raw `std.Io.net.Stream`
- custom runtimes that can hand over borrowed reader/writer pairs

For message-oriented application code, you can also run a typed handler loop with `Handler.run(...)` and keep state in user-owned structs via `Ctx.T()`.

### Message Handlers

`Handler.run(...)` is the built-in typed message loop adapter. It does not introduce runtime interfaces/vtables; handler dispatch is comptime-specialized.

- Handler signatures:
  - sync: `fn(ctx: *Handler.SliceContext(...)) ResponseType`
  - async-style: `fn(io: std.Io, ctx: *Handler.SliceContext(...)) !ResponseType`
- `Ctx.T()` gives typed access to user-owned per-loop/per-connection state.
- Receive mode is configured through `Handler.Options.receive_mode`:
  - `.solid_slice`: handlers receive a fully assembled message slice from caller-provided message buffer.
  - `.stream`: handlers pull chunks with `ctx.readChunk(...)` and can avoid full-message assembly in the library.
- Supported sync return shapes:
  - `[]const u8`
  - `[][]const u8` / `[]const []const u8`
  - `Handler.Response`
  - structs with `body` (and optional `opcode`)

Response writing stays on the core websocket writer path (`Conn.writeText` / `Conn.writeBinary` / fragmented frames for chunk arrays), and flushing is controlled by `Handler.Options.auto_flush`.
Control replies (auto-pong / auto-close) can be flushed independently with `Handler.Options.flush_control_replies`.

### Buffering

The connection API assumes buffered I/O.

- borrowed frame reads only work when the entire frame fits in the reader buffer
- frame and message helpers operate correctly without borrowing, but may copy into caller buffers
- write batching is left to the caller’s writer buffering and flush policy

### Timeouts

Timeouts are configured per connection through `Conn.Config.timeouts`.

- `read_ns`, `write_ns`, and `flush_ns` bound individual blocking operations
- `Conn.TypeWithHooks(..., Hooks)` lets the embedding framework provide the elapsed-time source and deadline mapping
- `Conn.Default`, `Conn.Server`, `Conn.Client`, and plain handshake helpers use `Observe.DefaultRuntimeHooks`

Without custom hooks, timeout enforcement is cooperative: the library can detect an operation ran longer than budget once that operation returns. With hook-provided deadline methods, the framework can map the same budget into socket or runtime deadlines so blocking I/O can fail promptly.

### Runtime Hooks

Runtime hooks are now timeout-only.

- connection flows can use `Conn.TypeWithHooks(.{ ... }, Hooks)` plus `initWithHooks(...)`
- hook types provide `nowNs`, `setReadDeadlineNs`, `setWriteDeadlineNs`, and `setFlushDeadlineNs`
- there is no event callback surface in the core hook contract

### Compression

`permessage-deflate` is optional.

- enable it during the handshake with `Handshake.Options.enable_permessage_deflate`
- propagate the negotiated `Handshake.Response.permessage_deflate` into `Conn.Config.permessage_deflate`
- compressed message I/O uses `std.compress.flate` for RFC7692 framing and optional context-takeover support
- compression remains disabled by default (`Conn.Config.permessage_deflate = null`)
- outgoing compressed writes are opt-in (`Conn.PerMessageDeflateConfig.compress_outgoing = false` by default)
- context takeover runtime support is disabled by default (`Conn.StaticConfig.permessage_deflate_context_takeover = false`)
- enable takeover support by instantiating `Conn.Type(.{ .permessage_deflate_context_takeover = true, ... })`
- when enabled, `Conn.StaticConfig` has conservative compile-time defaults:
  - `permessage_deflate_min_payload_len = 64`
  - `permessage_deflate_require_compression_gain = true`

The library negotiates the extension conservatively and defaults to:

- `server_no_context_takeover`
- `client_no_context_takeover`

With context takeover support disabled, this keeps the runtime model simple and avoids cross-message compressor state.

### Deployment Notes

`benchmark/zwebsocket_server.zig` is a benchmark harness, not a hardened application server.

For a real integration reference, use:

- `examples/echo_server.zig` for a message-oriented raw-stream server
- `examples/frame_echo_server.zig` for a frame-oriented raw-stream server
- `examples/ws_client.zig` for a client-side handshake plus `Conn.Client` flow

Production callers should still decide their own:

- accept loop / task model
- connection limits
- timeout budgets and idle handling policy
- how to collect timeout counters/latency metrics in your runtime
- TLS termination

## Validation

`zwebsocket` now ships with four validation layers.

### 1. Core Tests

```bash
zig build test
```

This covers protocol parsing, close handling, masking, fragmentation, handshake validation, and compression helpers.

### 2. Fuzz + Property Tests

The in-tree test suite includes:

- malformed frame fuzzing
- randomized client/server roundtrips
- randomized fragmented masked message reconstruction

Those live in `src/validation_tests.zig`.

### 3. Interoperability Matrix

```bash
zig build interop
```

This runs `zwebsocket` against real external peers in both directions:

- Node `ws` client/server
- Python `aiohttp` client/server
- compressed and uncompressed paths

The matrix is orchestrated by `validation/run_interop.zig`.

### 4. Soak Tests

```bash
zig build soak
```

This starts the example echo server and drives it with many concurrent long-lived websocket connections using the in-tree Zig soak runner.

The default soak step runs both:

- uncompressed
- `permessage-deflate`

### Combined Validation

```bash
zig build validate
```

That runs:

- unit and property tests
- interop
- soak

Benchmarks remain separate:

```bash
zig build bench-compare -Doptimize=ReleaseFast
```
