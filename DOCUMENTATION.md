# Documentation

## API Stability

`zwebsocket` is still pre-`1.0`, but it now has an explicit compatibility policy.

### Stable Surface

The public exports in `src/root.zig` are the supported package API:

- handshake types and functions
- `ConnType`, `Conn`, `ServerConn`, `ClientConn`
- frame/message read and write helpers
- `PerMessageDeflate` and `PerMessageDeflateConfig`
- timeout and observer types (`TimeoutConfig`, `Clock`, `DeadlineController`, `Observer`, `ObserveEvent`)

Within a patch release, those symbols and their documented semantics should not break.

### Provisional Surface

These areas are still allowed to evolve more aggressively before `1.0`:

- the exact shape of `Config` and `StaticConfig` if a feature needs another field
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

### Buffering

The connection API assumes buffered I/O.

- borrowed frame reads only work when the entire frame fits in the reader buffer
- frame and message helpers operate correctly without borrowing, but may copy into caller buffers
- write batching is left to the caller’s writer buffering and flush policy

### Timeouts

Timeouts are configured per connection through `Config.timeouts`.

- `read_ns`, `write_ns`, and `flush_ns` bound individual blocking operations
- `clock` provides the elapsed-time source
- `deadlines` lets the embedding framework translate those budgets into transport-level deadlines

Without a `DeadlineController`, timeout enforcement is cooperative: the library can detect an operation ran longer than budget once that operation returns. With a `DeadlineController`, the framework can map the same budget into socket or runtime deadlines so blocking I/O can fail promptly.

### Observability

The library exposes an optional event stream through `Config.observer` and `ServerHandshakeOptions.observer`.

Current event coverage includes:

- handshake acceptance and rejection
- frame reads and writes
- completed message reads
- ping, pong, and close reception
- auto-pong emission
- timeout detection
- surfaced protocol errors from core sequencing and frame validation paths

### Compression

`permessage-deflate` is optional.

- enable it during the handshake with `ServerHandshakeOptions.enable_permessage_deflate`
- propagate the negotiated `ServerHandshakeResponse.permessage_deflate` into `Config.permessage_deflate`
- compressed message I/O currently depends on system `zlib`

The library negotiates the extension conservatively and defaults to:

- `server_no_context_takeover`
- `client_no_context_takeover`

That keeps the runtime model simple and avoids cross-message compressor state.

### Deployment Notes

`benchmark/zwebsocket_server.zig` is a benchmark harness, not a hardened application server.

For a real integration reference, use:

- `examples/echo_server.zig` for a message-oriented raw-stream server
- `examples/frame_echo_server.zig` for a frame-oriented raw-stream server
- `examples/ws_client.zig` for a client-side handshake plus `ClientConn` flow

Production callers should still decide their own:

- accept loop / task model
- connection limits
- timeout budgets and idle handling policy
- how to export observer events into logs, metrics, or traces
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

The matrix is orchestrated by `validation/run_interop.py`.

### 4. Soak Tests

```bash
zig build soak
```

This starts the example echo server and drives it with many concurrent long-lived websocket connections using `aiohttp`.

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
