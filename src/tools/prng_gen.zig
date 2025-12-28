const std = @import("std");
const core = @import("core");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	if (args.len < 3) {
		try std.fs.File.stderr().writeAll("Usage: prng-gen <path> <size> [seed] [seq]\n");
		return error.InvalidInput;
	}

	const path = args[1];
	const size = try std.fmt.parseInt(u64, args[2], 10);
	const seed = if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 1;
	const seq = if (args.len > 4) try std.fmt.parseInt(u64, args[4], 10) else 1;

	var rng = core.prng.Pcg32.init(seed, seq);
	var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
	defer file.close();

	var remaining = size;
	var buf: [1024 * 1024]u8 = undefined;
	while (remaining > 0) {
		const chunk = @min(remaining, buf.len);
		rng.fillBytes(buf[0..chunk]);
		try file.writeAll(buf[0..chunk]);
		remaining -= chunk;
	}
}
