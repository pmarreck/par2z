# Resume Here

## Hi (Context Reset)
- Hi from future‑me. You: curious, precise, ambitious — and refreshingly brave about Zig.

## Current State (2025-12-26)
- Cleanroom specs in `PAR2_SPECIFICATION.md`; process notes in `PLAN.md` / `PROJECT_PLAN.md`.
- Tooling: `flake.nix` uses Zig + zls + OpenSSL + mktmp; par2cmdline is dev/test only.
- CLI (`src/cli.zig`): `verify`, `recover`, and `create` (basic) implemented.
	- `create` supports `--block-size`, `--block-count`, `--redundancy-percent`, `--recovery-blocks`, `--comment`, `--mute-defaults` / `PAR2_MUTE_DEFAULTS`.
	- Derived plan is printed to stderr unless muted.
	- Safe path handling for recovery; unsafe via `--allow-unsafe-paths`.
- Create now:
	- Uses Bitrot Guard heuristic for default block size.
	- Computes FileDesc, IFSC, RecvSlic.
	- Splits recovery volumes in power-of-two groups (par2cmdline pattern) with zero-padded `.volXXX+YYY.par2`.
	- Includes main packets in volume files.
	- Emits Unicode filename packets for non-ASCII names.
	- Emits ASCII + Unicode comment packets when transliteration is possible; otherwise Unicode only.
- Recovery: file-backed store + `--stdout` + `-o/--out-dir`.

## Tests
- Unit tests: `nix develop -c ./test`
- Integration: `nix develop -c ./test-integration`
  - Verifies recovery vs par2, SHA-256 checks
  - Verifies CLI create by par2 verify + repair

## Key Recent Changes
- Added `packet_write` and `create_packets` to build packets.
- Added `create_plan` for block/recovery planning and volume split.
- Added `gf16.exponentForIndex`.
- Added transliteration map (Latin-1) with exhaustive tests in `src/cli.zig`.

## Next Steps (Order Requested)
1) Optional packets beyond Unicode/comments: RFSC, FileSlic, Packed Main/RecvS.
2) Streaming create: avoid reading whole files; stream hashing + IFSC + RS encode.
3) (Later) memory allocator split for recovery to reduce peak usage.

## Notes
- par2cmdline defaults inferred: volume split 1,2,4,8… remainder; include main packets in volumes.
- CommASCI is 7-bit only; CommUni MD5 uses ASCII comment when transliteration exists.

## 2025-12-28 Update (Context Save)
- TDD note: I started implementing CLI flag parsing without adding tests first (TDD lapse). Please add tests for new flags before continuing changes.

### Recent Changes
- Par2 volume layout aligned more closely to par2cmdline-turbo:
  - Main `.par2` now writes packets with `Creator` last (after Main + optional packets).
  - Volume files now (by default) duplicate Main/FileDesc/IFSC/Creator metadata, appended after recovery slices; `--no-volume-meta` disables duplication.
  - RFSC emission remains optional via `--no-rfsc` and still appears before volume metadata when present.
- Recovery bug fixed: duplicate Main packets no longer reset the recovery set, preventing FileDesc/IFSC loss when volume files include Main. (`src/core/api.zig`)
- Volume-only input support: `loadVolumeFiles` now accepts `.vol*.par2` as the input file by stripping `.vol` suffix from base when scanning. (`src/cli.zig`)
- Streaming encode for file-backed store:
  - Added `rs.accumulateRecoverySlice` to XOR a single slice into a recovery buffer with a factor.
  - `core/block_api.computeRecoverySlicesFileStoreBatch*` now uses a streaming path (per-slice) instead of loading all slices into memory.

### Interop Tests Expanded
`test-integration` now uses deterministic `prng-gen` instead of `/dev/urandom` and adds:
- multi-file recover (par2 creates; our CLI recovers)
- volume-only recover (main removed; recover from .vol)
- no-RFSC create (our CLI) verified by par2
Other cases remain: full-missing, partial corruption, optional packets.
`./test` and `./test-integration` pass.

### Commits (Git, branch: yolo)
- 38ec5c3 par2: align volume metadata layout and add no-volume-meta
- b42cf7e interop: expand integration tests and support volume input
- 6529c3e plan: note expanded interop coverage
- 2710b10 core: stream recovery slice encoding for file store
- 09d7b4a plan: mark streaming encode complete

## What’s Next (Priority Order)
1) Finish CLI parity flags (par2cmdline-turbo): `-B`, `-R`, `-m`, `-v/-q`, plus create flags `-u/-l/-n/-f`.
2) Add full-file hash verification after recovery.
3) Refresh perf/memory baselines and logs.

## Immediate TODOs / Fixups
- Add tests for new/parsed flags before further CLI parsing changes (TDD).
- `parseRecoverArgs` still needs new flag handling (`-B`, `-v/-q`, `-m`) wired in and tested.
- Consider `-B` (basepath) semantics: likely for matching file names by relative path (not implemented yet).

## Notes
- Volume-only recover fails if recovery slices < missing slices; ensure redundancy >= total missing slices when designing tests.

## 2025-12-28 Update (Recent Work)
- Implemented par2cmdline-turbo flag behavior and parity tests:
  - `-B` basepath, `-R` recurse, `-m` memory, `-v/-q` verbosity, plus `-u/-l/-n/-f` recovery split.
  - Basepath affects create/verify/recover; out-of-base files ignored with warning.
  - Recovery volume naming now matches par2cmdline (start padding only; width based on total + `-f`).
- Added full-file hash verification after recovery (MD5 vs FileDesc file_hash); recovery errors if mismatch.
- Enforced `-m` memory cap in create/recover with TDD tests.
- Added volume layout parity checks to `test-integration` using par2cmdline for comparison.
- Bench/mem baselines refreshed with smaller sizes (16MiB) via env vars; logs updated in `bench-results.tsv` and `mem-results.tsv`.

### Tests
- `nix develop -c ./test` OK
- `nix develop -c ./test-integration` OK

### Next Ideas
- Implement full-file hash verification in verify path (currently recover-only).
- Consider enforcing memory cap via a limited allocator (instead of estimation).

## 2025-12-28 Update (Later)
- Verify now falls back to full-file MD5 when IFSC packets are missing; corruption is detected in that case.
- Added LimitedAllocator-backed enforcement for `-m` in recover/create; still keeps conservative cap checks.
- New tests cover verify fallback and memory-cap failures; `./test` and `./test-integration` pass.

## 2025-12-28 Update (Ops Refactor + Fixes)
- CLI now thin; operational logic moved into `src/ops.zig` (importable from C/C++/Swift).
- Fixed RFSC validation map indexing in `loadPar2File` (exponent → index).
- Fixed volume file discovery for relative paths; recover now loads `.vol*.par2` correctly.
- Added extra `PAR2_DEBUG_RECOVER` logging for loaded volumes (debug only).
- Build/test: `nix develop -c ./test` and `./test-integration` pass.

## 2025-12-28 Update (Verify Streaming + Bench)
- `verify` now streams from disk using `FileStore` + `core.api.verifyStoreFile` (low memory).
- Added `slices.computeIfscEntry` and a low-memory-cap verify test.
- `block_api` file-store recovery now reads each file sequentially (one open per file).
- Bench script now always builds ReleaseFast by default; create perf is near par2cmdline when ReleaseFast is used.

## 2025-12-28 Update (C ABI WIP)
- Added C ABI plan section to `PLAN.md`.
- Implemented C ABI in `src/lib.zig` (separate handles, path/memory/stream inputs, options with memory cap + allocator, last-error strings).
- Updated `include/par2.h` with full API surface.
- `ops.create` now takes an allocator param; CLI updated to call `ops.create(allocator, ...)`.
- `ops.CreateOptions` gained `thread_count` (CLI currently sets null).
- Removed `ops` → `par2` import loop; creator text is now literal `"par2z 0.1.0"`.
- Added tests in `tests/tests.zig`:
  - `c api create/verify with memory input` passes.
  - `c api recover writes to output dir` fails with `Par2Error.invalid_argument`.

### Current blocker
- `par2_recover_run` returns `.invalid_argument` in C API test; need exact error cause.
- Suspect is in `par2_recover_run` / `ops.recover` path handling; add/expand `setLastError` or debug print to capture `@errorName(e)` (already set but not surfaced).

### Diagnostics to run
- Run cached test binary (faster): `nix develop -c ./.zig-cache/o/<hash>/test`
- Or rebuild: `nix develop -c zig build test`
- Inspect `par2_recover_last_error` in failing test and print it.

### Files changed in this WIP
- `src/lib.zig`, `include/par2.h`, `tests/tests.zig`, `src/ops.zig`, `src/cli.zig`,
  `src/core/api.zig`, `src/core/slices.zig`, `src/core/block_api.zig`, `build.zig`.

## 2025-12-29 Update (C ABI Default Fix)
- Adjusted C API defaults so `par2_create_new(null, …)` uses redundancy_percent=5 (matches CLI), ensuring small files emit recovery slices.
- Intended to fix failing test `c api recover writes to output dir`.

### Tests
- `nix develop -c zig build test` timed out multiple times (10s/120s/300s/600s). No output; needs investigation.
- `zig test tests/tests.zig --test-filter …` fails because module `par2` is only available via build.zig.

## 2025-12-29 Update (Test Runner/CLI Build Changes)
- Removed `zig build` invocations from unit tests; now use `cliPath()` / `prngPath()` helpers.
- `build.zig` now installs `par2z-cli` and `prng-gen` for the test step and adds `-Dtest-filter` support via compile-time filters.
- C API default verbosity set to `-1` (silent by default) to avoid library output on stdout.

### Tests
- `zig build test -Dtest-filter="version string"` succeeds.
- `zig build test -Dtest-filter="c api create/verify with memory input"` still hangs; root cause unclear.
- Running the emitted test binary directly (latest in `.zig-cache/o/*/test`) succeeds; C API tests pass when run manually.

### Suspected Issue
- `zig build test` hangs only on C API tests; seems to be a Zig test-runner/listen-mode handshake issue.
  - `sample` shows test binary stuck in `test_runner.mainServer` waiting on `zig.Server.receiveMessage` (stdin).
  - `sample` shows build runner stuck in `Build.Step.Run.evalZigTest` poll loop.
  - Running the same emitted test binary directly (no `--listen=-`) passes.
  - Not correlated with input size; other filtered tests run fine.

## 2025-12-29 Update (Test-Direct Workaround + STDOUT_TO_STDERR)
- Added `STDOUT_TO_STDERR` env flag; when set, info output that would go to stdout is redirected to stderr (does not affect `--stdout` file data).
- `build.zig` now provides `zig build test-direct` (installs test binary and runs it directly, bypassing `--listen`).
- README updated with `test-direct` workaround.

## 2025-12-29 Update (CLI --tar Streaming)
- Added `--tar` to CLI create/recover: emits tar stream on stdout (main+volumes or recovered files).
- Implemented tar capture/output in `src/cli.zig` (captures outputs via `output_open`, writes tar to stdout).
- Tar output disables CLI verbosity to keep stdout clean.
- Added unit tests that untar and verify outputs.

## 2025-12-30 Update (Streaming Core Interface)
- Implemented stream-based core operations (no temp files) in `src/ops.zig`:
  - `createStreams`, `verifyStreams`, `recoverStreams`
  - Stream input type uses read-at callback + length + name
- Added `core.storage.StreamStore` and `core.api.verifyStoreStream`, plus stream recovery slice batch in `core.block_api`.
- Added `buildVolumeStream` and stream volume workers; streaming volumes emit RFSC with 16 KiB buffer/late emission (same behavior as file-based).
- Added SliceOverrideStoreStream for FileSlic overrides in streaming recover.
- Added tests: `ops streaming create/verify/recover` in `tests/tests.zig` (passes via `zig build test-direct -Dtest-filter="ops streaming create/verify/recover"`).
- `./test` currently times out after 120s (needs investigation or increase timeout).

## Remaining TODOs
- Add SQLite adapter example (docs/tests) for zero-disk use.
- Consider C ABI wiring to streaming ops (avoid temp spooling).
- Investigate `./test` timeout (possibly large integration tests).
