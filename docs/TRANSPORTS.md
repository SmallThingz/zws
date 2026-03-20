# Transports

`zwebsocket` is a synchronous, stream-oriented websocket core.

## Expected Integration Shape

The library expects:

- a reader positioned at the first websocket frame byte
- a writer targeting the same upgraded TCP stream
- the HTTP upgrade already accepted, or a caller using the handshake helpers to do it

That makes it fit three common models:

- raw `std.Io.net.Stream`
- `zhttp` upgrade routes
- custom runtimes that can hand over borrowed reader/writer pairs

## Buffering

The connection API assumes buffered I/O.

- borrowed frame reads only work when the entire frame fits in the reader buffer
- frame and message helpers operate correctly without borrowing, but may copy into caller buffers
- write batching is left to the caller’s writer buffering and flush policy

## Compression

`permessage-deflate` is optional.

- enable it during the handshake with `ServerHandshakeOptions.enable_permessage_deflate`
- propagate the negotiated `ServerHandshakeResponse.permessage_deflate` into `Config.permessage_deflate`
- compressed message I/O currently depends on system `zlib`

The library negotiates the extension conservatively and defaults to:

- `server_no_context_takeover`
- `client_no_context_takeover`

That keeps the runtime model simple and avoids cross-message compressor state.

## Deployment Notes

`benchmark/zwebsocket_server.zig` is a benchmark harness, not a hardened application server.

For a real integration reference, use:

- `examples/echo_server.zig` for a standalone raw-stream server
- `src/zhttp_compat.zig` plus the README example for `zhttp`

Production callers should still decide their own:

- accept loop / task model
- connection limits
- timeouts and idle handling
- logging and metrics
- TLS termination
