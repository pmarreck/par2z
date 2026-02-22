# par2z

[![Garnix](https://garnix.io/repo/pmarreck/par2z/status.svg)](https://garnix.io/repo/pmarreck/par2z)
[![CI](https://github.com/pmarreck/par2z/actions/workflows/ci.yml/badge.svg)](https://github.com/pmarreck/par2z/actions/workflows/ci.yml)

## Overview
Cleanroom PAR2 implementation with a Zig core, C ABI for FFI (Swift/LuaJIT), and a standalone CLI.

## API Layers
- High-level recovery/verification API in `src/core/api.zig`.
- Block-level API in `src/core/block_api.zig` for slice-by-slice workflows and custom storage backends.
- Storage adapters in `src/core/storage.zig` (memory-backed and file-backed) so recovery can run without loading whole files up front.
- CLI operations moved into `src/ops.zig` (callable from Zig and suitable for C/Swift wrappers). `src/cli.zig` is now a thin CLI parser + I/O shim.

## C API Examples
The C ABI is declared in `include/par2.h`. Memory and stream inputs do not touch disk.

Thread pool configuration (optional): the library uses a global thread pool by default. You can configure the global pool size or supply your own pool handle via the C ABI.
Handles are independent and safe to run concurrently. The only shared global state is the thread pool configuration, so set or swap pools before starting work and avoid changing it while operations are active.

Create from memory (no temp files), write `.par2` to a path:
```c
#include "par2.h"

const uint8_t data[] = {0,1,2,3,4,5,6,7};
Par2CreateHandle *create = NULL;
par2_create_new(NULL, &create);
par2_create_add_memory(create, "data.bin", data, sizeof(data));
par2_create_set_output_path(create, "set.par2");
par2_create_run(create);
par2_create_destroy(create);

// optional: configure global pool size (0 = default)
par2_thread_pool_configure(0);
```

Verify from in-memory PAR2 bytes and a stream input:
```c
#include "par2.h"

struct MemCtx { const uint8_t *data; size_t len; };
static size_t read_at(void *ctx, uint64_t off, uint8_t *out, size_t len) {
	struct MemCtx *m = (struct MemCtx *)ctx;
	if (off >= m->len) return 0;
	size_t avail = m->len - (size_t)off;
	size_t n = (avail < len) ? avail : len;
	memcpy(out, m->data + off, n);
	return n;
}

Par2VerifyHandle *verify = NULL;
par2_verify_new(NULL, &verify);
par2_verify_add_par2_data(verify, par2_bytes, par2_len, "set.par2"); // call multiple times for volumes
par2_verify_add_stream(verify, "data.bin", data_len, read_at, &mem_ctx);
par2_verify_run(verify);
par2_verify_destroy(verify);
```

Recover with output callback (no disk output):
```c
#include "par2.h"

static size_t write_out(void *ctx, const uint8_t *data, size_t len) {
	(void)ctx;
	/* append to a buffer */
	return len;
}

static Par2Error open_out(void *ctx, const char *path, Par2Output *out) {
	(void)path;
	out->ctx = ctx;
	out->write = write_out;
	out->close = NULL;
	return PAR2_OK;
}

Par2RecoverHandle *recover = NULL;
par2_recover_new(NULL, &recover);
par2_recover_set_par2_path(recover, "set.par2");
par2_recover_add_path(recover, "data.bin");
par2_recover_set_output_open(recover, open_out, NULL);
par2_recover_run(recover);
par2_recover_destroy(recover);

// optional: caller-owned pool
Par2ThreadPool *pool = NULL;
par2_thread_pool_create(4, &pool);
par2_thread_pool_set_global(pool);
par2_thread_pool_set_global(NULL);
par2_thread_pool_destroy(pool);
```

### Swift (FFI)
Minimal Swift usage with `dlopen` (or link against a built dylib):
```swift
import Foundation

typealias Par2CreateHandle = OpaquePointer
typealias Par2Error = Int32

@_silgen_name("par2_create_new") func par2_create_new(_ opts: UnsafeRawPointer?, _ out: UnsafeMutablePointer<Par2CreateHandle?>) -> Par2Error
@_silgen_name("par2_create_add_memory") func par2_create_add_memory(_ h: Par2CreateHandle?, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<UInt8>, _ len: Int) -> Par2Error
@_silgen_name("par2_create_set_output_path") func par2_create_set_output_path(_ h: Par2CreateHandle?, _ path: UnsafePointer<CChar>) -> Par2Error
@_silgen_name("par2_create_run") func par2_create_run(_ h: Par2CreateHandle?) -> Par2Error
@_silgen_name("par2_create_destroy") func par2_create_destroy(_ h: Par2CreateHandle?)

let payload: [UInt8] = [0,1,2,3,4,5,6,7]
var handle: Par2CreateHandle?
_ = par2_create_new(nil, &handle)
payload.withUnsafeBytes { buf in
	_ = par2_create_add_memory(handle, "data.bin", buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
}
_ = par2_create_set_output_path(handle, "set.par2")
_ = par2_create_run(handle)
par2_create_destroy(handle)
```

### LuaJIT (FFI)
```lua
local ffi = require("ffi")
ffi.cdef[[
typedef struct Par2CreateHandle Par2CreateHandle;
typedef int Par2Error;
Par2Error par2_create_new(const void *opts, Par2CreateHandle **out_handle);
Par2Error par2_create_add_memory(Par2CreateHandle *h, const char *name, const uint8_t *data, size_t len);
Par2Error par2_create_set_output_path(Par2CreateHandle *h, const char *par2_path);
Par2Error par2_create_run(Par2CreateHandle *h);
void par2_create_destroy(Par2CreateHandle *h);
]]

local lib = ffi.load("par2") -- or full path to libpar2.dylib/.so
local data = ffi.new("uint8_t[8]", {0,1,2,3,4,5,6,7})
local handle = ffi.new("Par2CreateHandle*[1]")
lib.par2_create_new(nil, handle)
lib.par2_create_add_memory(handle[0], "data.bin", data, 8)
lib.par2_create_set_output_path(handle[0], "set.par2")
lib.par2_create_run(handle[0])
lib.par2_create_destroy(handle[0])
```

## CLI
- Verify: `par2z-cli verify [options] <par2 file> [data files...]`
- Recover: `par2z-cli recover [options] <par2 file> [data files...]`
- Recover to stdout: `par2z-cli recover --stdout [options] <par2 file> [data files...]`
- Create: `par2z-cli create [options] <par2 file> <data files...>`
- LuaJIT adapter CLI (FFI): `par2z-cli-luajit` (installed to `zig-out/bin/par2z-cli-luajit` by `zig build`)

Behavior notes:
- `verify`/`recover` match inputs by exact path when possible, then by basename. Ambiguous basenames cause an error unless exact paths are used.
- Defaults: redundancy 5%, block size via file-size heuristic (bitrot_guard).
- Use `--mute-defaults` or set `PAR2_MUTE_DEFAULTS` (non-empty, not `0`/`false`) to suppress default reporting and derived plan on stderr.
- Set `STDOUT_TO_STDERR` (non-empty, not `0`/`false`) to redirect informational stdout messages to stderr (does not affect `--stdout` file data).
- `--tar` on `create` or `recover` emits a tar stream on stdout (main+volumes or recovered files).
- Binary output note: for `--stdout`/`--tar`, avoid capturing stdout into shell variables unless you use a binary-safe wrapper (e.g., `capture -p`).
- `--include-input-slices` emits `FileSlic` packets (large size increase).
- `--emit-packed` emits `PkdMain` and `PkdRecvS` packets.
- RFSC packets are emitted by default when recovery volumes exceed 16 KiB; use `--no-rfsc` to skip.
- Volume files duplicate `Main`, `FileDesc`, `IFSC`, and `Creator` by default for compatibility; use `--no-volume-meta` to omit.
- Unicode filename packets are emitted when non-ASCII file names are present.
- Unicode comment packets are emitted when transliteration is possible; otherwise Unicode-only.

Verify/Recover options:
- `-B <path>`: basepath used to resolve relative `FileDesc` names.
- `-m <MB>`: memory cap (fail if estimated or actual usage exceeds).
- `-v/-q`: verbosity control (`-q -q` is silent).
- `-o, --out-dir <dir>`: output directory for recovered files.
- `--stdout`: recover to stdout (requires exactly one missing file).
- `--allow-unsafe-paths`: allow absolute/`..` paths from `FileDesc` (unsafe).

Create options:
- `-s <bytes>` / `--block-size <bytes>`: block size (mutually exclusive with `-b`).
- `-b <count>` / `--block-count <count>`: block count (mutually exclusive with `-s`).
- `-r <percent>` / `--redundancy-percent <percent>`: redundancy percent (mutually exclusive with `-c`).
- `-c <count>` / `--recovery-blocks <count>`: recovery blocks (mutually exclusive with `-r`).
- `-f <index>`: first recovery block number (offsets volume indices).
- `-u`: uniform recovery file sizes.
- `-l`: limit recovery file sizes (based on largest input file).
- `-n <count>`: number of recovery files (max 31; incompatible with `-l`).
- `-R`: recurse into subdirectories for input paths.

Full-file hash verification:
- `verify` falls back to full-file MD5 when IFSC packets are missing.
- `recover` always validates the full-file MD5 after reconstruction.

## Testing
- Unit tests: `nix develop -c ./test`
- If `zig build test` hangs on C-API tests (Zig `--listen` runner issue), use: `nix develop -c zig build test-direct`
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

Recent results (16 MiB file, 4KB blocks, 10% redundancy, Apple M-series):

| Tool | Create | Verify | Repair |
|------|--------|--------|--------|
| par2cmdline 0.8.1 | 12.2 MiB/s | 168.4 MiB/s | 85.6 MiB/s |
| par2cmdline-turbo 1.3.0 | 172.0 MiB/s | 363.6 MiB/s | 111.9 MiB/s |
| par2z-cli | 10.4 MiB/s | 166.7 MiB/s | 56.9 MiB/s |

See `bench-results.tsv` for the full benchmark log (last updated 2025-12-31T18:50:43Z).
par2z performs comparably to the original par2cmdline. par2cmdline-turbo is significantly faster, likely due to hand-optimized SIMD assembly for GF(2^16) multiplication (we have not examined its source code to maintain cleanroom status). See `TODO.md` for optimization opportunities.

Run `bench` or `bench-all` to compare implementations:

Env vars:
- `PAR2_CLI_BIN` path to our CLI (default `zig-out/bin/par2z-cli`)
- `PAR2_OTHER_BIN` path to other PAR2 CLI (default `par2`)
- `PAR2_BENCH_SIZE` bytes (default 67108864)
- `PAR2_BENCH_BLOCK_SIZE` bytes (default 4096)
- `PAR2_BENCH_REDUNDANCY` percent (default 10)
- `PAR2_BENCH_ITERS` iterations (default 3)
- `PAR2_BENCH_CORRUPT_BYTES` bytes to corrupt before repair (default 4096)
- `PAR2_PRNG_GEN` path to deterministic generator (default `zig-out/bin/prng-gen`)
- `PAR2_BENCH_SEED` seed for deterministic data (default 1)
- `PAR2_BENCH_SEQ` stream selector for deterministic data (default 1)
- `PAR2_BENCH_OPTIMIZE` Zig optimize mode (default ReleaseFast)
- `PAR2_BENCH_BUILD` rebuild par2z-cli before running (default 1; set 0 to skip)
- `PAR2_BENCH_LOG` path to bench log (default `bench-results.tsv`)

Example:
```
PAR2_BENCH_SIZE=134217728 PAR2_BENCH_ITERS=1 ./bench
```

Sweep example:
```
PAR2_BENCH_SIZE=16777216 PAR2_BENCH_ITERS=3 ./bench
PAR2_BENCH_SIZE=67108864 PAR2_BENCH_ITERS=3 ./bench
PAR2_BENCH_SIZE=268435456 PAR2_BENCH_BLOCK_SIZE=16384 PAR2_BENCH_ITERS=3 ./bench
```

## Long-Term Data Integrity (Research Notes)

These notes summarize published guidance and field studies that shape how much redundancy is needed for long-term storage. They are design constraints, not guarantees.

SSD unpowered retention (JEDEC context):
- Enterprise-class SSDs are typically required to retain data for at least 3 months at 40C when fully worn (JEDEC JESD218/JESD219 context).
- Client-class SSDs are typically required to retain data for at least 1 year at 30C when fully worn (JEDEC JESD218/JESD219 context).
- Retention degrades with higher temperature and higher wear; vendors recommend periodic power-on refresh or full read to refresh NAND charge.

HDD latent sector errors:
- Large field studies show latent sector errors are not independent and exhibit spatial/temporal locality; scrubbing helps catch these before they stack up.

Design implications for redundancy:
- Parity budgets (1-5%) are most effective when paired with periodic scrubbing.
- For SSDs stored unpowered beyond JEDEC retention windows, parity alone is not sufficient; require periodic refresh or additional independent copies.

Sources:
- Dell SSD/NVMe data retention guidance (JEDEC references and power-off recommendations): https://www.dell.com/support/kbdoc/en-mv/000198930/ssd-data-retention-considerations-when-powering-off-systems-for-a-prolonged-duration
- NetApp latent sector error study (1.53M disks over 32 months): https://www.netapp.com/atg/publications/publications-an-analysis-of-latent-sector-errors-in-disk-drives-20074817/
- Curtiss-Wright summary of JEDEC client retention requirements and temperature effects: https://defense-solutions.curtisswright.com/media-center/blog/extended-temperatures-flash-memory
- Example enterprise SSD spec listing 3 months power-off retention at 40C (JESD218): https://www.digikey.com/en/htmldatasheets/production/2042810/0/0/1/intel-ssd-dc-s3520-series-for-150gb.html

## Archival Use Guidance (Non-Normative)

This project targets long-term archival workflows that want strong integrity without full data duplication. It is designed to add a parity layer on top of existing storage, not to replace independent backups.

Practical expectations:
- 1-5% parity can address many bit-rot and small loss events when paired with periodic scrubbing.
- Parity cannot guarantee recovery after catastrophic device failure or long unpowered retention beyond vendor guidance.
- For higher confidence, use parity plus at least one independent copy stored on a separate device or location.

## License
Apache-2.0. See `LICENSE`.
