# PAR2 Cleanroom Plan

## Goal
Document a cleanroom-derivable PAR2 file format specification and algorithm (implementation-ready, no code) and recommend an implementation language for a macOS product.

## Done Criteria
- [x] PAR2_SPECIFICATION.md describes the full PAR2 packet format (core + optional), data conventions, and recovery algorithm at implementation detail.
- [x] PAR2_SPECIFICATION.md includes explicit recovery math and slice ordering rules from primary sources.
- [x] Cleanroom approach and sources are recorded here.
- [x] Language recommendation provided with brief pros/cons and a request for direction.
- [x] flake.nix provides Zig toolchain, fuzzing tools, and par2cmdline for compatibility tests.
- [x] Licensing notes recorded for MD5 and par2cmdline dev tooling vs distribution.
- [x] TOOLCHAIN.md created with build presets and safe C++ subset rules.
- [x] PROJECT_PLAN.md created with TDD implementation steps.

## Cleanroom Method (Process Notes)
- [x] Use only published specifications and public documentation; do not read or rely on any implementation source code.
- [x] Record all sources and dates accessed.
- [x] Keep derived text as a paraphrase (no verbatim copy beyond short, necessary excerpts).

## Sources Collected (To Cite)
- [x] Parity Volume Set Specification 2.0 (Parchive, 2003-05-11) official spec (SourceForge) — accessed 2025-12-24.
- [x] Bilingual mirror of spec (for optional packet sections) — accessed 2025-12-24.
- [x] Parchive project site (context, reference implementation note) — accessed 2025-12-24.
- [x] Library of Congress format description (format context) — accessed 2025-12-24.

## Licensing Notes (Initial)
- [x] MD5 licensing note: implementation now uses Zig stdlib (`std.crypto.hash.Md5`), so no RFC 1321 code is shipped; keep attribution note only if a standalone RFC 1321 implementation is added later.
- [x] par2cmdline is GPL; confirmed test-only usage (not shipped), not linkable for Mac App Store distribution.

## Progress Log
- [x] 2025-12-24: Collected official spec metadata and a mirror for detailed packet/algorithm content.
- [x] 2025-12-24: Draft PAR2_SPECIFICATION.md.
- [x] 2025-12-24: Add flake.nix safety toolchain and par2cmdline for compatibility testing.
- [x] 2025-12-24: Draft TOOLCHAIN.md with safety policy and build presets.
- [x] 2025-12-24: Draft PROJECT_PLAN.md with TDD implementation steps.

## Implementation Phase
- [x] CLI recover command uses core recovery API and writes recovered output to disk or stdout.
- [x] CLI tar streaming (`--tar`) for create/recover with tests.
- [x] File-backed store adapter for streaming disk access.
- [x] Full-file recovery integration test with larger fixture vs par2.
- [x] CLI tests using Zig 0.15 process API or bash harness.
- [x] Optional packet support: parse FileSlic/RFSC/PkdMain/PkdRecvS; emit FileSlic (flag) and PkdMain/PkdRecvS (flag).
- [x] Expanded integration interoperability tests (multi-file, volume-only, no-RFSC, seeded data).
- [x] Streaming encode for file-backed store (avoid loading all slices in memory).

## TODO: par2cmdline-turbo Flags (Compatibility)
- [x] Empirically verify par2cmdline-turbo flag behavior (no source code).
- [x] Implement behavior for `-B` (basepath), `-R` (recurse), `-m` (memory), `-v`/`-q` (verbosity).
- [x] Implement recovery file splitting flags: `-u`, `-l`, `-n`, and `-f` (first recovery block).

### Empirical Notes (par2cmdline-turbo 1.3.0)
- `-B` stores relative paths and is required for verify/repair to search basepath; files outside basepath are ignored with a warning (error if none remain).
- `-R` is create-only; verify/repair reject it.
- `-u` (uniform) evens recovery blocks across files; can combine with `-n`.
- `-n` splits evenly across `n` volumes; `-l` is incompatible with `-n`; `-u` incompatible with `-l`.
- `-f` offsets recovery block indices and volume names (e.g. `-f5` starts at `vol05+...`).

## Review Findings (2025-12-26)
- [x] Verify packet hash before parsing packets (skip invalid hash).
- [x] Enforce single recovery_set_id when loading main + volume files.
- [x] Guard against GF16 exponent exhaustion (TooManySlices).
- [x] Add overflow checks for recovery block planning and slice count.
- [x] Free temporary buffers in core APIs for long-lived clients.
- [x] Remove 1 GiB cap in par2 file load (read exact file size).

## Review Findings (2025-12-27)
- [x] `par2z-cli verify` maps inputs by FileDesc name (order-independent) with CLI tests for reversed input order. (`src/cli.zig`, `tests/tests.zig`)
- [x] Buffer FileDesc/IFSC packets received before Main; attach after Main/PkdMain. (`src/core/api.zig`, `tests/tests.zig`)
- [x] Accept space-separated short flags (`-s 4096`, `-r 10`, etc.) in create parsing. (`src/cli.zig`, `tests/tests.zig`)
- [x] Sanitize absolute paths in FileDesc by storing basename; verify on-disk packets. (`src/cli.zig`, `tests/tests.zig`)
- [x] Detect basename ambiguity; require exact path matches to disambiguate. (`src/cli.zig`, `tests/tests.zig`)

## Review Findings (2025-12-28)
- [x] Ignore duplicate Main packets to avoid resetting attached FileDesc/IFSC when volume files also contain Main. (`src/core/api.zig`, `tests/tests.zig`)
- [x] memtest output label matches units (bytes). (`memtest`)

## TODO (Performance/Portability)
- [ ] Optional platform-specific SIMD intrinsics (x86_64 SSE2/AVX2, ARM NEON) behind target checks; keep portable SIMD + scalar fallback as default.

## Recommendations Backlog (Merged Gemini + Claude, 2025-12-30)
### High Priority (Correctness / Portability / Perf)
- [x] Replace platform-specific MD5 bindings with `std.crypto.hash.Md5` (pure Zig, portable); delete `src/core/md5_macos.zig` and `src/core/md5_linux.zig` after migration.
- [x] Optimize GF16 mul/pow to avoid `% 65535` (conditional subtract or doubled LUT).
- [x] CRC32: replace bit-loop with 256-entry lookup table.
- [x] Make `isMissingIndex` O(1) (hash set or bitmap) in recovery hot path.
- [x] Remove per-slice `page_allocator` in RS hot loops; accept scratch allocator/buffer or use arena reset per batch.
- [x] Use a persistent `std.Thread.Pool` instead of per-chunk thread spawn/join.

### Medium Priority (Architecture / Maintainability)
- [x] Split `src/ops.zig` into `create.zig`, `verify.zig`, `recover.zig`, `common.zig`.
- [x] Consolidate duplicated `verify*Store` and `computeRecoverySlices*` functions (generic/store interface).
- [x] Normalize error naming across modules for validation failures.
- [x] Either remove `checked.zig` or standardize on checked wrappers across codebase.
- [x] Reduce temp allocations in `findMismatchedSlices` (two-pass or exact-size allocation).
- [x] Remove empty `src/ffi/` dir or implement it (decide).

### Test Coverage Gaps
- [x] Add tests for `LimitedAllocator` edge cases (cap exhaustion, resize).
- [x] Add direct tests for `transliterateAscii` / `mapLatin1`.
- [x] Add edge-case tests for `volumePath` and `volumeIndexWidth`.
- [x] Add tests for error paths in streaming ops (`recoverStreams`, `verifyStreams`).
- [x] Add tests for C API error messages (`par2_*_last_error`).
- [x] Add thread-safety tests for concurrent volume building.

### Low Priority / Cleanup
- [x] Remove or relocate `data.bin` if it’s a stray artifact (confirm intended use).
- [x] Simplify repeated path-building helpers into shared util.
- [x] Reduce verbose `while` loops / redundant casts where safe.

## Streaming Core Interface (No Temp Files)
### Goal
Support true streaming inputs/outputs (no temp file spooling), suitable for SQLite-backed storage or in-memory pipelines.

### Design Decisions (Agreed)
- Forward-only output is supported; no requirement for random access.
- RFSC emission in streaming mode:
  - Buffer the first 16 KiB of each output stream.
  - Emit RFSC after 16 KiB is available (or skip if total output < 16 KiB).
  - If output supports random access, optional in-place patching is allowed but not required.
- Streaming inputs are modeled as logical files: name + length + read-at callback.
- Streaming outputs are modeled as per-file outputs: open(path) → writer/close.

### Steps (TDD, small increments)
- [x] Define stream interfaces in core/ops (InputFileStream, OutputStreamOpener) with strict bounds/overflow checks.
- [x] Implement streaming create for main file (emit packets directly to OutputStream without temp files).
- [x] Implement streaming volume emit with buffered RFSC (16 KiB) and late emission.
- [x] Implement streaming recover output (write recovered slices to OutputStream).
- [x] Implement streaming verify path (read-at without file paths).
- [x] Add tests for streaming create/recover/verify with in-memory sinks (small fixtures).
- [ ] Add SQLite adapter example (in docs/tests) showing zero-disk usage.

## C ABI Library (New)
### Goal
Expose a stable C API with separate handles for create/verify/recover, supporting file paths and in-memory/streaming inputs, optional memory caps, configurable threading, and last-error strings.

### Done Criteria
- [x] `include/par2.h` documents the C ABI: handles, options, callbacks, error codes.
- [x] `src/lib.zig` implements C ABI with separate handles (create/verify/recover).
- [x] Supports file-path inputs and memory/streaming inputs (read-at callback).
- [x] Recover can write to file path (default: directory of par2 file) or write callback.
- [x] Optional memory cap and optional custom allocator callbacks.
- [x] Threading configurable (0 = all cores).
- [x] TDD: add unit tests for C API behaviors (memory input + verify + recover happy path).
