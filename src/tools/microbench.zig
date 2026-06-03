//! Microbenchmark runner for the GF(2^16) multiply and CRC32 kernels.
//! Built and run via `zig build bench-micro` (or `./bm`). These are timing
//! loops, deliberately kept OUT of the test suite — correctness/parity of the
//! kernels is covered by `test` blocks in gf16.zig / crc32.zig.

const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    core.io_singleton.set(init.io);
    core.io_singleton.setEnvMap(init.environ_map);
    const io = core.io_singleton.getOrInit();

    try core.gf16.runBenchmarks(io);
    core.crc32.runBenchmark(io);
}
