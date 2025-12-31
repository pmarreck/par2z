# Resume Here

## Latest Work
- Added `repair` alias in `src/cli.zig` so `par2z-cli repair` behaves like `recover`.
- Added `-a <par2_file>` create flag (par2cmdline-compatible output path) and `-T <count>` thread count flag; both parsed in `parseCreateArgs` and passed to ops.
- Updated CLI usage text to include `repair`, `-a`, and `-T` options.
- Added parser test for `-a` and `-T` in `src/cli.zig` tests.
- Built static-ish CLI variants via `zig build`:
  - macOS (as static as macOS allows): `zig-out/bin-static/macos/par2z-cli`
  - Linux x86_64 musl (fully static): `zig-out/bin-static/linux-x86_64/par2z-cli`
- Copied both to `../bitrot_guard/bin/{macos,linux-x86_64}/par2z-cli`.
- Removed external AI recommendation files.
- Added hidden helper script `tools/bitrot_guard_run` (no README mention) to run `../bitrot_guard` with `BRG_PAR2_BIN` defaulted by OS.

## Current Goal
Get `../bitrot_guard` tests passing using our CLI. Investigate failures if any remain.

## Hypotheses for bitrot_guard failures
- CLI mismatch (should now be fixed: `repair` alias, `-a`, `-T`).
- Format differences: our output may be valid but not identical to par2cmdline expectations used by tests.
- Some other behavioral mismatch (packet ordering, RFSC/IFSC emission, volume layout, etc.).

## Next Steps (proposed)
1) Run bitrot_guard tests with our CLI:
   - Use `tools/bitrot_guard_run` or set `BRG_PAR2_BIN=../bitrot_guard/bin/macos/par2z-cli`.
   - Example: `BRG_PAR2_BIN=./bin/macos/par2z-cli ./test/test.sh` (from bitrot_guard) or `tools/bitrot_guard_run ...`.
2) Capture exact failing tests and reproduce minimal case(s).
3) Compare `.par2` outputs against par2cmdline for the same input:
   - Packet list/order, RFSC/IFSC presence, FileSlic/PkdMain/PkdRecvS, volume names.
4) Decide whether to align to par2cmdline behavior or adjust bitrot_guard expectations.

## Notes
- macOS binaries cannot be fully static (libSystem remains dynamic); Linux musl is static.
- The helper script `tools/bitrot_guard_run` lives here and is intentionally undocumented.

