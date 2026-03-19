# Requests For `zhttp`

`zwebsocket` is implemented as a standalone RFC 6455 core. To integrate it cleanly into `../zhttp` without adding avoidable copies or awkward escape hatches, `zhttp` should expose three guarantees:

1. Connection takeover after header parsing.
The route handler needs a supported way to stop normal HTTP response writing and take ownership of the accepted connection once the request line and headers have been parsed and validated.

2. Raw stream access.
The upgrade handler needs direct access to the underlying `std.Io.net.Stream`, or at minimum the live `*std.Io.Reader` and `*std.Io.Writer` that remain bound to that stream for the rest of the connection lifetime.

3. Borrowed upgrade headers.
The websocket handshake only needs a small fixed header set:
`Connection`, `Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version`, `Sec-WebSocket-Protocol`, `Sec-WebSocket-Extensions`, `Origin`, `Host`.
`zhttp` should surface these as borrowed slices from the already-parsed request so the upgrade path does not re-scan or copy them.

Preferred shape:

```zig
pub const Upgrade = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    stream: *std.Io.net.Stream,
};

pub fn upgradeWebSocket(req: anytype) !Upgrade;
```

Minimum behavioral guarantee:

- Once upgrade succeeds, `zhttp` stops its keep-alive request loop for that socket.
- `zhttp` does not append HTTP response bytes after the websocket handshake response.
- Any unread request body is already rejected or discarded before takeover.
