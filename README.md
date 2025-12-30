# par2z

## Overview
Cleanroom PAR2 implementation with a Zig core, C ABI for FFI (Swift/LuaJIT), and a CLI for testing.

## API Layers
- High-level recovery/verification API in `src/core/api.zig`.
- Block-level API in `src/core/block_api.zig` for slice-by-slice workflows and custom storage backends.
- Storage adapters in `src/core/storage.zig` (memory-backed and file-backed) so recovery can run without loading whole files up front.
- CLI operations moved into `src/ops.zig` (callable from Zig and suitable for C/Swift wrappers). `src/cli.zig` is now a thin CLI parser + I/O shim.

## C API Examples
The C ABI is declared in `include/par2.h`. Memory and stream inputs do not touch disk.

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
par2_verify_set_par2_data(verify, par2_bytes, par2_len);
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

Behavior notes:
- `verify`/`recover` match inputs by exact path when possible, then by basename. Ambiguous basenames cause an error unless exact paths are used.
- Defaults: redundancy 5%, block size via file-size heuristic (bitrot_guard).
- Use `--mute-defaults` or set `PAR2_MUTE_DEFAULTS` (non-empty, not `0`/`false`) to suppress default reporting and derived plan on stderr.
- Set `STDOUT_TO_STDERR` (non-empty, not `0`/`false`) to redirect informational stdout messages to stderr (does not affect `--stdout` file data).
- `--tar` on `create` or `recover` emits a tar stream on stdout (main+volumes or recovered files).
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

## Crypto Backend Configuration
MD5 is provided via a small Zig wrapper that selects a platform crypto backend:
- macOS: CommonCrypto
- Linux: OpenSSL (libcrypto)

This avoids shipping GPL components and keeps the core algorithm independent of a particular crypto library.

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
Run `bench` to compare our CLI against another PAR2 implementation (defaults to `par2cmdline-turbo` if `par2` is in PATH).

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

## License
Apache-2.0. See `LICENSE`.
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
