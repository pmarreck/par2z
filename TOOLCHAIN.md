# Toolchain and Safety Policy

## Scope
This document defines the Zig safety toolchain, build presets, and coding rules for the PAR2 cleanroom implementation.

## Build Presets (Zig)

### Debug (default during development)
- Safety: Zig default safety checks enabled
- Debug info: on

### Debug-Strict
- Safety: Zig safety checks enabled + explicit bounds/overflow checks
- Extra invariants: enabled

### Release
- Safety: Zig ReleaseSafe for general builds
- Optional: ReleaseFast for benchmarks only (requires explicit opt-in)

## Compile-Time Safety Switches
- Default: bounds/overflow checks enabled in all build modes.
- Optional: PAR2_UNSAFE_FAST disables explicit checks (never for production).

## Static Analysis
- zig fmt (required on CI)
- zig build test (required on CI)

## Fuzzing
- AFL++ targets for:
	- Packet header parsing
	- Packet body parsing (each packet type)
	- IFSC verification
	- Recovery slice decoding

## Compatibility Testing
- par2cmdline is used as an external, dev/test-only tool.
- It is GPL; do not link or ship it in any distribution.

## Safe Zig Subset (Mandatory)
- No raw pointer arithmetic for parsing; use slices with explicit bounds checks.
- No unchecked integer math in parsing; use checked add/mul helpers.
- No implicit aliasing of byte buffers; use explicit slice copies/views.
- Error handling uses explicit error sets; no panics in library code.
- All I/O is isolated to adapters; core logic is pure where possible.

## Buffer Access Patterns
- Use a small set of helpers:
	- readU32Le(slice, offset) -> error!u32
	- readU64Le(slice, offset) -> error!u64
	- readBytes(slice, offset, len) -> error![]const u8
- All helpers check bounds before read and advance offsets explicitly.

## GC Policy
- Boehm GC is not used in Zig mode.
