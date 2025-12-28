# par2-cleanroom

## Overview
Cleanroom PAR2 implementation with a Zig core, C ABI for FFI (Swift/LuaJIT), and a CLI for testing.

## API Layers
- High-level recovery/verification API in `src/core/api.zig`.
- Block-level API in `src/core/block_api.zig` for slice-by-slice workflows and custom storage backends.
- Storage adapters in `src/core/storage.zig` (memory-backed and file-backed) so recovery can run without loading whole files up front.

## CLI
- Verify: `par2-cli verify <par2 file> <data files...>`
- Recover: `par2-cli recover [-o|--out-dir <dir>] [--allow-unsafe-paths] <par2 file> <data files...>`
- Recover to stdout: `par2-cli recover --stdout [--allow-unsafe-paths] <par2 file> <data files...>`
- Create: `par2-cli create [--block-size <bytes> | --block-count <n>] [--redundancy-percent <n> | --recovery-blocks <n>] [--comment <text>] <par2 file> <data files...>`
  - `verify`/`recover` match inputs by exact path when possible, then by basename. Ambiguous basenames cause an error unless exact paths are used.
  - Planned defaults: redundancy 5%, block size via file-size heuristic (bitrot_guard).
  - Use `--mute-defaults` or set `PAR2_MUTE_DEFAULTS` (non-empty, not `0`/`false`) to suppress default reporting and derived plan on stderr.
  - Use `--include-input-slices` to emit `FileSlic` packets (stores input slices inside the PAR2 set; large size increase).
  - Use `--emit-packed` to emit `PkdMain` and `PkdRecvS` packets (optional packed format).
  - RFSC packets are emitted by default when the recovery volume is >16 KiB; use `--no-rfsc` to skip them.
  - Volume files duplicate `Main`, `FileDesc`, `IFSC`, and `Creator` packets by default for compatibility; use `--no-volume-meta` to omit them.
  - Emits Unicode filename packets when non-ASCII file names are present.
  - Emits Unicode comment packets for non-ASCII comments.

## Crypto Backend Configuration
MD5 is provided via a small Zig wrapper that selects a platform crypto backend:
- macOS: CommonCrypto
- Linux: OpenSSL (libcrypto)

This avoids shipping GPL components and keeps the core algorithm independent of a particular crypto library.

## Testing
- Unit tests: `nix develop -c ./test`
- Integration recovery test (par2 cross-check): `nix develop -c ./test-integration`
- Optional stress tests:
  - `PAR2_STRESS=1` enables stress-only unit tests.
  - `PAR2_STRESS_SIZE=<bytes>` sets large-file size for the stress test (default 134217728).
  - Example: `PAR2_STRESS=1 PAR2_STRESS_SIZE=268435456 nix develop -c ./test`
- Memory usage (RSS) logging: `./memtest`
  - Uses `/usr/bin/time -l` on macOS or `/usr/bin/time -v` on Linux.
  - Logs max RSS in bytes to `mem-results.tsv` by default.
  - `PAR2_MEM_SIZE`, `PAR2_MEM_BLOCK_SIZE`, `PAR2_MEM_REDUNDANCY`, `PAR2_MEM_ITERS`, `PAR2_MEM_SEED`, `PAR2_MEM_SEQ` are supported.

## Benchmarks
Run `bench` to compare our CLI against another PAR2 implementation (defaults to `par2cmdline-turbo` if `par2` is in PATH).

Env vars:
- `PAR2_CLI_BIN` path to our CLI (default `zig-out/bin/par2-cli`)
- `PAR2_OTHER_BIN` path to other PAR2 CLI (default `par2`)
- `PAR2_BENCH_SIZE` bytes (default 67108864)
- `PAR2_BENCH_BLOCK_SIZE` bytes (default 4096)
- `PAR2_BENCH_REDUNDANCY` percent (default 10)
- `PAR2_BENCH_ITERS` iterations (default 3)
- `PAR2_BENCH_CORRUPT_BYTES` bytes to corrupt before repair (default 4096)
- `PAR2_PRNG_GEN` path to deterministic generator (default `zig-out/bin/prng-gen`)
- `PAR2_BENCH_SEED` seed for deterministic data (default 1)
- `PAR2_BENCH_SEQ` stream selector for deterministic data (default 1)

Example:
```
PAR2_BENCH_SIZE=134217728 PAR2_BENCH_ITERS=1 ./bench
```
