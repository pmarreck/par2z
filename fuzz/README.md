# Fuzz Testing with AFL++

This directory contains fuzz targets for testing PAR2 packet parsing and recovery.

## Prerequisites

AFL++ is only available on Linux. The Nix flake includes it automatically on Linux systems.

## Building Fuzz Targets

```bash
nix develop -c zig build fuzz
```

This produces executables in `zig-out/fuzz/`:
- `fuzz_packet` - Tests packet parsing routines
- `fuzz_recovery` - Tests recovery/verification logic

## Running AFL++

```bash
# Create output directory
mkdir -p fuzz/output

# Run AFL++ on packet parser
afl-fuzz -i fuzz/corpus -o fuzz/output/packet -- ./zig-out/fuzz/fuzz_packet

# Run AFL++ on recovery logic
afl-fuzz -i fuzz/corpus -o fuzz/output/recovery -- ./zig-out/fuzz/fuzz_recovery
```

## Corpus

The `corpus/` directory contains seed inputs (valid PAR2 files from fixtures).
AFL++ will mutate these to discover edge cases and potential crashes.

## Interpreting Results

- Crashes in `fuzz/output/*/crashes/` indicate bugs that need fixing
- Hangs in `fuzz/output/*/hangs/` may indicate infinite loops or excessive allocations
- Use `zig build fuzz` with Debug mode to get useful stack traces
