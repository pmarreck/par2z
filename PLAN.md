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
- [ ] MD5 reference implementation in RFC 1321 allows use/modify with attribution notice; suitable for proprietary use with notice retention.
- [x] par2cmdline is GPL; confirmed test-only usage (not shipped), not linkable for Mac App Store distribution.

## Progress Log
- [x] 2025-12-24: Collected official spec metadata and a mirror for detailed packet/algorithm content.
- [x] 2025-12-24: Draft PAR2_SPECIFICATION.md.
- [x] 2025-12-24: Add flake.nix safety toolchain and par2cmdline for compatibility testing.
- [x] 2025-12-24: Draft TOOLCHAIN.md with safety policy and build presets.
- [x] 2025-12-24: Draft PROJECT_PLAN.md with TDD implementation steps.

## Implementation Phase
- [x] CLI recover command uses core recovery API and writes recovered output to disk or stdout.
- [x] File-backed store adapter for streaming disk access.
- [x] Full-file recovery integration test with larger fixture vs par2.
- [x] CLI tests using Zig 0.15 process API or bash harness.
- [x] Optional packet support: parse FileSlic/RFSC/PkdMain/PkdRecvS; emit FileSlic (flag) and PkdMain/PkdRecvS (flag).

## TODO: par2cmdline-turbo Flags (Compatibility)
- [ ] Implement behavior for `-B` (basepath), `-R` (recurse), `-m` (memory), `-v`/`-q` (verbosity).
- [ ] Implement recovery file splitting flags: `-u`, `-l`, `-n`, and `-f` (first recovery block).

## Review Findings (2025-12-26)
- [x] Verify packet hash before parsing packets (skip invalid hash).
- [x] Enforce single recovery_set_id when loading main + volume files.
- [x] Guard against GF16 exponent exhaustion (TooManySlices).
- [x] Add overflow checks for recovery block planning and slice count.
- [x] Free temporary buffers in core APIs for long-lived clients.
- [x] Remove 1 GiB cap in par2 file load (read exact file size).

## Review Findings (2025-12-27)
- [x] `par2-cli verify` maps inputs by FileDesc name (order-independent) with CLI tests for reversed input order. (`src/cli.zig`, `tests/tests.zig`)
- [x] Buffer FileDesc/IFSC packets received before Main; attach after Main/PkdMain. (`src/core/api.zig`, `tests/tests.zig`)
- [x] Accept space-separated short flags (`-s 4096`, `-r 10`, etc.) in create parsing. (`src/cli.zig`, `tests/tests.zig`)
- [x] Sanitize absolute paths in FileDesc by storing basename; verify on-disk packets. (`src/cli.zig`, `tests/tests.zig`)
- [x] Detect basename ambiguity; require exact path matches to disambiguate. (`src/cli.zig`, `tests/tests.zig`)

## Review Findings (2025-12-28)
- [x] Ignore duplicate Main packets to avoid resetting attached FileDesc/IFSC when volume files also contain Main. (`src/core/api.zig`, `tests/tests.zig`)
- [x] memtest output label matches units (bytes). (`memtest`)

## TODO (Performance/Portability)
- [ ] Optional platform-specific SIMD intrinsics (x86_64 SSE2/AVX2, ARM NEON) behind target checks; keep portable SIMD + scalar fallback as default.
