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
- Bench script now builds ReleaseFast by default; perf gap on create remains large, verify memory now ~2–3MB.
