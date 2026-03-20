# API Stability

`zwebsocket` is still pre-`1.0`, but it now has an explicit compatibility policy.

## Stable Surface

The public exports in `src/root.zig` are the supported package API:

- handshake types and functions
- `ConnType`, `Conn`, `ServerConn`, `ClientConn`
- frame/message read and write helpers
- `PerMessageDeflate` and `PerMessageDeflateConfig`
- `zhttp` compatibility helpers

Within a patch release, those symbols and their documented semantics should not break.

## Provisional Surface

These areas are still allowed to evolve more aggressively before `1.0`:

- the exact shape of `Config` and `StaticConfig` if a feature needs another field
- compression tuning knobs beyond the negotiated `permessage-deflate` parameters
- validation/build helper steps under `zig build`
- the `zhttp` adapter if `zhttp` itself changes its upgrade request surface

If a breaking change lands in a provisional area, it should come with a migration note in the changelog or commit message.

## Breaking-Change Policy

Before `1.0`:

- patch releases should be source-compatible for the stable surface
- minor releases may contain targeted breaking changes, but only with clear motivation
- protocol correctness fixes are allowed even if they cause previously-accepted malformed traffic to start failing

After `1.0`, the intent is standard semver for the stable surface.
