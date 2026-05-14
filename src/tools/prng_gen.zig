const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    core.io_singleton.set(init.io);
    core.io_singleton.setEnvMap(init.environ_map);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        try std.Io.File.stderr().writeStreamingAll(core.io_singleton.getOrInit(), "Usage: prng-gen <path> <size> [seed] [seq]\n");
        return error.InvalidInput;
    }

    const path = args[1];
    const size = try std.fmt.parseInt(u64, args[2], 10);
    const seed = if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 1;
    const seq = if (args.len > 4) try std.fmt.parseInt(u64, args[4], 10) else 1;

    var rng = core.prng.Pcg32.init(seed, seq);
    var file = try std.Io.Dir.cwd().createFile(core.io_singleton.getOrInit(), path, .{ .truncate = true });
    defer file.close(core.io_singleton.getOrInit());

    var remaining = size;
    var buf: [1024 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        rng.fillBytes(buf[0..chunk]);
        try file.writeStreamingAll(core.io_singleton.getOrInit(), buf[0..chunk]);
        remaining -= chunk;
    }
}
