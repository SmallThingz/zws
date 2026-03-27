# Validation

`zwebsocket` now ships with four validation layers.

## 1. Core Tests

```bash
zig build test
```

This covers protocol parsing, close handling, masking, fragmentation, handshake validation, and compression helpers.

## 2. Fuzz + Property Tests

The in-tree test suite includes:

- malformed frame fuzzing
- randomized client/server roundtrips
- randomized fragmented masked message reconstruction

Those live in `src/validation_tests.zig`.

## 3. Interoperability Matrix

```bash
zig build interop
```

This runs `zwebsocket` against real external peers in both directions:

- Node `ws` client/server
- Python `aiohttp` client/server
- compressed and uncompressed paths

The matrix is orchestrated by `validation/run_interop.py`.

## 4. Soak Tests

```bash
zig build soak
```

This starts the example echo server and drives it with many concurrent long-lived websocket connections using `aiohttp`.

The default soak step runs both:

- uncompressed
- `permessage-deflate`

## Combined Validation

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
