# Requests For `zhttp`

`zhttp` already fulfills the original hard blockers for websocket integration:

- upgrade routes transfer connection ownership after a `101 Switching Protocols` response
- `WsRunner.run(...)` receives the raw `std.Io.net.Stream`
- unread request bodies are discarded before takeover
- per-upgrade state can be moved into the runner through `upgrade_data`

`zwebsocket` now has adapter helpers for the current `zhttp` model, so the remaining requests are narrower and mostly about ergonomics and API stability.

## Remaining Requests

1. Stable upgrade-request surface.

`zwebsocket`'s `zhttp` adapter depends on these request members staying available on upgrade routes:

- `req.method`
- `req.base.version`
- `req.header(.connection)`
- `req.header(.upgrade)`
- `req.header(.sec_websocket_key)`
- `req.header(.sec_websocket_version)`
- `req.header(.sec_websocket_protocol)`
- `req.header(.sec_websocket_extensions)`
- `req.header(.origin)`
- `req.header(.host)`

Those are enough to validate the handshake without re-parsing raw bytes. A documented stability guarantee for that surface would make the adapter safe to depend on long-term.

2. First-class `101` response helper.

Upgrade handlers currently have to construct the switching-protocols response manually. A built-in helper such as one of these would remove boilerplate and reduce header-shape drift:

```zig
pub fn switchingProtocols(headers: []const response.Header) response.Res;
pub fn upgrade(headers: []const response.Header) response.Res;
```

3. Public websocket upgrade example.

`zhttp` has the primitives now, but there is no canonical example showing:

- route header schema for websocket handshakes
- validating the request in the HTTP handler
- returning the `101` response
- creating reader/writer buffers inside `WsRunner.run(...)`
- handing the accepted stream off to `zwebsocket`

That example would make the intended integration path obvious and keep downstream adapters from diverging.
