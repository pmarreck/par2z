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
