const std = @import("std");
const lib = @import("par2");
const core = @import("core");
const c_std = @cImport({
    @cInclude("stdlib.h");
});
const ops = @import("ops");

fn cliPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.cwd().realpathAlloc(allocator, "zig-out/bin/par2z-cli");
}

fn prngPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.cwd().realpathAlloc(allocator, "zig-out/bin/prng-gen");
}

test "version string" {
    try std.testing.expectEqualStrings("par2z 0.1.0", lib.zigVersion());
}

test "readU32Le reads little-endian" {
    const data = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    const v = try core.bytes.readU32Le(&data, 0);
    try std.testing.expectEqual(@as(u32, 0x12345678), v);
}

test "readU32Le bounds check" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    try std.testing.expectError(error.OutOfBounds, core.bytes.readU32Le(&data, 0));
}

test "crc32 standard check value" {
    const data = "123456789";
    const v = core.crc32.crc32(data);
    try std.testing.expectEqual(@as(u32, 0xCBF43926), v);
}

test "md5 standard check value" {
    const data = "123456789";
    var out: [16]u8 = undefined;
    try core.md5.md5Digest(data, &out);
    const expect = [_]u8{ 0x25, 0xF9, 0xE7, 0x94, 0x32, 0x3B, 0x45, 0x38, 0x85, 0xF5, 0x18, 0x1F, 0x1B, 0x62, 0x4D, 0x0B };
    try std.testing.expectEqualSlices(u8, &expect, &out);
}

test "md5_16k uses first 16k" {
    const data = "abc";
    const v = try core.file_id.md5_16k(data);
    const expect = [_]u8{ 0x90, 0x01, 0x50, 0x98, 0x3C, 0xD2, 0x4F, 0xB0, 0xD6, 0x96, 0x3F, 0x7D, 0x28, 0xE1, 0x7F, 0x72 };
    try std.testing.expectEqualSlices(u8, &expect, &v);
}

test "fileId computes MD5 over md5-16k + length + filename" {
    const data = "abc";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try core.file_id.fileId(arena.allocator(), data, 3, "a.txt");
    const expect = [_]u8{ 0xFF, 0x60, 0x25, 0x48, 0x34, 0x7C, 0x96, 0x97, 0x39, 0x13, 0xDB, 0xE0, 0x1A, 0x1E, 0xDB, 0x39 };
    try std.testing.expectEqualSlices(u8, &expect, &v);
}

test "ops stdout-to-stderr env flag" {
    try std.testing.expectEqual(@as(c_int, 0), c_std.setenv("STDOUT_TO_STDERR", "1", 1));
    try std.testing.expect(ops.stdoutToStderrEnabled());
    try std.testing.expectEqual(@as(c_int, 0), c_std.setenv("STDOUT_TO_STDERR", "0", 1));
    try std.testing.expect(!ops.stdoutToStderrEnabled());
    _ = c_std.unsetenv("STDOUT_TO_STDERR");
}

const StreamMemCtx = struct {
	data: []const u8,
};

fn streamReadAt(ctx: *anyopaque, offset: u64, out: []u8) usize {
	const mem: *StreamMemCtx = @ptrCast(@alignCast(ctx));
	if (offset >= mem.data.len) return 0;
	const avail = mem.data.len - @as(usize, @intCast(offset));
	const n = @min(avail, out.len);
	@memcpy(out[0..n], mem.data[@as(usize, @intCast(offset)) .. @as(usize, @intCast(offset)) + n]);
	return n;
}

const OutBuffer = struct {
	allocator: std.mem.Allocator,
	data: std.ArrayList(u8),
};

const OutCapture = struct {
	allocator: std.mem.Allocator,
	map: std.StringHashMap(OutBuffer),
};

fn outCaptureInit(allocator: std.mem.Allocator) OutCapture {
	return .{ .allocator = allocator, .map = std.StringHashMap(OutBuffer).init(allocator) };
}

fn outCaptureDeinit(cap: *OutCapture) void {
	var it = cap.map.iterator();
	while (it.next()) |entry| {
		entry.value_ptr.data.deinit(cap.allocator);
		cap.allocator.free(entry.key_ptr.*);
	}
	cap.map.deinit();
}

fn outWrite(ctx: *anyopaque, data: []const u8) anyerror!usize {
	const buf: *OutBuffer = @ptrCast(@alignCast(ctx));
	try buf.data.appendSlice(buf.allocator, data);
	return data.len;
}

fn outClose(_: *anyopaque) void {}

fn outOpen(ctx: *anyopaque, path: []const u8) anyerror!ops.OutputTarget {
	const cap: *OutCapture = @ptrCast(@alignCast(ctx));
	const name = std.fs.path.basename(path);
	if (cap.map.getPtr(name)) |existing| {
		existing.*.data.clearRetainingCapacity();
		return .{ .ctx = existing, .writeFn = outWrite, .closeFn = outClose };
	}
	const key = try cap.allocator.dupe(u8, name);
	const buf_val = OutBuffer{ .allocator = cap.allocator, .data = std.ArrayList(u8).empty };
	try cap.map.put(key, buf_val);
	const buf = cap.map.getPtr(key).?;
	return .{ .ctx = buf, .writeFn = outWrite, .closeFn = outClose };
}

fn commandAvailable(allocator: std.mem.Allocator, name: []const u8) bool {
	const res = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &.{ "which", name },
	}) catch return false;
	defer allocator.free(res.stdout);
	defer allocator.free(res.stderr);
	return switch (res.term) {
		.Exited => |code| code == 0,
		else => false,
	};
}

fn sharedLibPath(allocator: std.mem.Allocator) ![]const u8 {
	const builtin = @import("builtin");
	const ext = switch (builtin.os.tag) {
		.macos => "dylib",
		else => "so",
	};
	const rel = try std.fmt.allocPrint(allocator, "zig-out/lib/libpar2.{s}", .{ext});
	defer allocator.free(rel);
	return try std.fs.cwd().realpathAlloc(allocator, rel);
}

fn runCommandExpectOk(allocator: std.mem.Allocator, argv: []const []const u8, env: ?*std.process.EnvMap, cwd: ?[]const u8) !void {
	const res = try std.process.Child.run(.{
		.allocator = allocator,
		.argv = argv,
		.env_map = env,
		.cwd = cwd,
	});
	defer allocator.free(res.stdout);
	defer allocator.free(res.stderr);
	switch (res.term) {
		.Exited => |code| {
			if (code != 0) {
				if (res.stdout.len > 0) std.debug.print("stdout:\n{s}\n", .{res.stdout});
				if (res.stderr.len > 0) std.debug.print("stderr:\n{s}\n", .{res.stderr});
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.UnexpectedTerm,
	}
}

fn libPathEnvName() []const u8 {
    const builtin = @import("builtin");
    return if (builtin.os.tag == .macos) "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
}

fn swiftSdkRootFromXcrun(allocator: std.mem.Allocator) !?[]const u8 {
	var env = try std.process.getEnvMap(allocator);
	defer env.deinit();
	_ = env.remove("SDKROOT");
	_ = env.remove("DEVELOPER_DIR");
	_ = env.remove("TOOLCHAINS");
	const xcrun_path = if (std.fs.accessAbsolute("/usr/bin/xcrun", .{})) |_| "/usr/bin/xcrun" else |_| "xcrun";
	const res = try std.process.Child.run(.{
		.allocator = allocator,
		.argv = &.{ xcrun_path, "--sdk", "macosx", "--show-sdk-path" },
		.env_map = &env,
	});
	defer allocator.free(res.stdout);
	defer allocator.free(res.stderr);
	switch (res.term) {
		.Exited => |code| {
			if (code != 0 or res.stdout.len == 0) return null;
			const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
			return try allocator.dupe(u8, trimmed);
		},
		else => return null,
	}
}

fn xcodeSelectPath(allocator: std.mem.Allocator) ?[]const u8 {
	if (!commandAvailable(allocator, "xcode-select")) return null;
	const res = std.process.Child.run(.{
		.allocator = allocator,
		.argv = &.{ "xcode-select", "-p" },
	}) catch return null;
	defer allocator.free(res.stdout);
	defer allocator.free(res.stderr);
	switch (res.term) {
		.Exited => |code| {
			if (code != 0 or res.stdout.len == 0) return null;
			const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
			return allocator.dupe(u8, trimmed) catch null;
		},
		else => return null,
	}
}

fn swiftCompileArgv(allocator: std.mem.Allocator, swift_path: []const u8, lib_dir: []const u8, bin_path: []const u8, sdk_path: ?[]const u8) ![]const []const u8 {
	if (xcodeSelectPath(allocator)) |dev| {
		defer allocator.free(dev);
		const swiftc_path = try std.fmt.allocPrint(allocator, "{s}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", .{dev});
		if (std.fs.accessAbsolute(swiftc_path, .{})) |_| {
			const use_sdk = sdk_path != null;
			const argv = try allocator.alloc([]const u8, if (use_sdk) 9 else 7);
			argv[0] = swiftc_path;
			argv[1] = swift_path;
			argv[2] = "-L";
			argv[3] = lib_dir;
			argv[4] = "-lpar2";
			argv[5] = "-o";
			argv[6] = bin_path;
			if (use_sdk) {
				argv[7] = "-sdk";
				argv[8] = sdk_path.?;
			}
			return argv;
		} else |_| {}
	}
	if (std.fs.accessAbsolute("/usr/bin/swiftc", .{})) |_| {
		const use_sdk = sdk_path != null;
		const argv = try allocator.alloc([]const u8, if (use_sdk) 9 else 7);
		argv[0] = "/usr/bin/swiftc";
		argv[1] = swift_path;
		argv[2] = "-L";
		argv[3] = lib_dir;
		argv[4] = "-lpar2";
		argv[5] = "-o";
		argv[6] = bin_path;
		if (use_sdk) {
			argv[7] = "-sdk";
			argv[8] = sdk_path.?;
		}
		return argv;
	} else |_| {}
	if (commandAvailable(allocator, "xcrun")) {
		const xcrun_path = if (std.fs.accessAbsolute("/usr/bin/xcrun", .{})) |_| "/usr/bin/xcrun" else |_| "xcrun";
		const use_sdk = sdk_path != null;
		const argv = try allocator.alloc([]const u8, if (use_sdk) 12 else 10);
		argv[0] = xcrun_path;
		argv[1] = "--sdk";
		argv[2] = "macosx";
		argv[3] = "swiftc";
		argv[4] = swift_path;
		argv[5] = "-L";
		argv[6] = lib_dir;
		argv[7] = "-lpar2";
		argv[8] = "-o";
		argv[9] = bin_path;
		if (use_sdk) {
			argv[10] = "-sdk";
			argv[11] = sdk_path.?;
		}
		return argv;
	}
	const use_sdk = sdk_path != null;
	const argv = try allocator.alloc([]const u8, if (use_sdk) 9 else 7);
	argv[0] = "swiftc";
	argv[1] = swift_path;
	argv[2] = "-L";
	argv[3] = lib_dir;
	argv[4] = "-lpar2";
	argv[5] = "-o";
	argv[6] = bin_path;
	if (use_sdk) {
		argv[7] = "-sdk";
		argv[8] = sdk_path.?;
	}
	return argv;
}

fn capiReadAt(ctx: ?*anyopaque, offset: u64, out: [*]u8, len: usize) callconv(.c) usize {
	if (ctx == null) return 0;
	const mem: *StreamMemCtx = @ptrCast(@alignCast(ctx.?));
	if (offset >= mem.data.len) return 0;
	const avail = mem.data.len - @as(usize, @intCast(offset));
	const n = @min(avail, len);
	@memcpy(out[0..n], mem.data[@as(usize, @intCast(offset)) .. @as(usize, @intCast(offset)) + n]);
	return n;
}

test "ops streaming create/verify/recover" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	var cap = outCaptureInit(allocator);
	defer outCaptureDeinit(&cap);

	const payload = "ABCDEFGHIJKLMNOP";
	var mem_ctx = StreamMemCtx{ .data = payload };
	const inputs = [_]ops.StreamInput{.{
		.name = "a.bin",
		.length = payload.len,
		.read_at = streamReadAt,
		.ctx = &mem_ctx,
	}};

	const create_opts = ops.CreateOptions{
		.block_size = 4,
		.block_count = null,
		.redundancy_percent = null,
		.recovery_blocks = 1,
		.first_recovery_block = null,
		.uniform_recovery = false,
		.limit_recovery = false,
		.recovery_file_count = null,
		.par2_path = "set.par2",
		.data_paths = &.{},
		.mute_defaults = true,
		.comment = null,
		.include_input_slices = false,
		.emit_packed = false,
		.emit_rfsc = true,
		.include_volume_meta = true,
		.basepath = null,
		.verbosity = -1,
		.memory_mb = null,
		.recurse = false,
		.thread_count = 1,
		.output_open = .{ .ctx = &cap, .openFn = outOpen },
	};
	try ops.createStreams(allocator, create_opts, &inputs);
	const main_buf = cap.map.getPtr("set.par2") orelse return error.NotFound;
	const vol_buf = cap.map.getPtr("set.vol0+1.par2") orelse return error.NotFound;

	const verify_opts = ops.VerifyOptions{
		.par2_path = "set.par2",
		.data_paths = &.{},
		.basepath = null,
		.verbosity = -1,
		.memory_mb = null,
	};
	try ops.verifyStreams(allocator, main_buf.data.items, verify_opts, &inputs);

	var corrupt: [16]u8 = undefined;
	@memcpy(&corrupt, payload);
	corrupt[0] = 'Z';
	var corrupt_ctx = StreamMemCtx{ .data = corrupt[0..] };
	const inputs_corrupt = [_]ops.StreamInput{.{
		.name = "a.bin",
		.length = corrupt.len,
		.read_at = streamReadAt,
		.ctx = &corrupt_ctx,
	}};

	var out_cap = outCaptureInit(allocator);
	defer outCaptureDeinit(&out_cap);
	const recover_opts = ops.RecoverOptions{
		.stdout_only = false,
		.out_dir = null,
		.par2_path = "set.par2",
		.data_paths = &.{},
		.allow_unsafe_paths = false,
		.basepath = null,
		.verbosity = -1,
		.memory_mb = null,
		.output_open = .{ .ctx = &out_cap, .openFn = outOpen },
	};
	const vols = [_][]const u8{vol_buf.data.items};
	try ops.recoverStreams(allocator, allocator, main_buf.data.items, &vols, recover_opts, &inputs_corrupt);
	const recovered = out_cap.map.getPtr("a.bin") orelse return error.NotFound;
	try std.testing.expectEqualStrings(payload, recovered.data.items);
}

test "computeIfscEntries splits and pads" {
    const data = "abcdEF";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try core.slices.computeIfscEntries(arena.allocator(), data, 4);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    var expect0_md5: [16]u8 = undefined;
    try core.md5.md5Digest("abcd", &expect0_md5);
    try std.testing.expectEqualSlices(u8, &expect0_md5, &entries[0].md5);
    try std.testing.expectEqual(core.crc32.crc32("abcd"), entries[0].crc32);
    var tmp: [4]u8 = .{ 'E', 'F', 0, 0 };
    var expect1_md5: [16]u8 = undefined;
    try core.md5.md5Digest(&tmp, &expect1_md5);
    try std.testing.expectEqualSlices(u8, &expect1_md5, &entries[1].md5);
    try std.testing.expectEqual(core.crc32.crc32(&tmp), entries[1].crc32);
}

test "sliceCount rounds up" {
    try std.testing.expectEqual(@as(usize, 2), try core.slices.sliceCount(6, 4));
}

test "sliceCount rejects oversized length" {
    const max = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidSliceSize, core.slices.sliceCount(max, 2));
}

test "buildSliceOrder orders by file then slice" {
    const files = [_]core.layout.FileInfo{
        .{ .length = 6 },
        .{ .length = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const order = try core.layout.buildSliceOrder(arena.allocator(), &files, 4);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(@as(usize, 0), order[0].file_index);
    try std.testing.expectEqual(@as(usize, 0), order[0].slice_index);
    try std.testing.expectEqual(@as(usize, 4), order[0].length);
    try std.testing.expectEqual(@as(usize, 0), order[1].file_index);
    try std.testing.expectEqual(@as(usize, 1), order[1].slice_index);
    try std.testing.expectEqual(@as(usize, 2), order[1].length);
    try std.testing.expectEqual(@as(usize, 1), order[2].file_index);
    try std.testing.expectEqual(@as(usize, 0), order[2].slice_index);
    try std.testing.expectEqual(@as(usize, 3), order[2].length);
}

test "stress overflow guards (optional)" {
    if (!shouldRunStress()) return;
    const max = std.math.maxInt(usize);
    const files = [_]core.layout.FileInfo{
        .{ .length = max },
        .{ .length = max },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Overflow, core.layout.buildSliceOrder(arena.allocator(), &files, 1));
}

fn shouldRunStress() bool {
    const val = std.process.getEnvVarOwned(std.testing.allocator, "PAR2_STRESS") catch return false;
    defer std.testing.allocator.free(val);
    if (val.len == 0) return false;
    if (std.mem.eql(u8, val, "0")) return false;
    if (std.mem.eql(u8, val, "false")) return false;
    return true;
}

fn shouldRunTurboCompat() bool {
    const val = std.process.getEnvVarOwned(std.testing.allocator, "PAR2_TURBO") catch return false;
    defer std.testing.allocator.free(val);
    if (val.len == 0) return false;
    if (std.mem.eql(u8, val, "0")) return false;
    if (std.mem.eql(u8, val, "false")) return false;
    return true;
}

fn stressSizeBytes() u64 {
    const val = std.process.getEnvVarOwned(std.testing.allocator, "PAR2_STRESS_SIZE") catch return 128 * 1024 * 1024;
    defer std.testing.allocator.free(val);
    if (val.len == 0) return 128 * 1024 * 1024;
    return std.fmt.parseInt(u64, val, 10) catch 128 * 1024 * 1024;
}

test "stress large file io (optional)" {
    if (!shouldRunStress()) return;
    const size = stressSizeBytes();
    if (size == 0) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dir_path = try mktmpDir(arena.allocator());
    defer std.fs.cwd().deleteTree(dir_path) catch {};
    const file_path = try std.fs.path.join(arena.allocator(), &.{ dir_path, "stress.bin" });
    try writeRandomFile(file_path, size);
    const slice_size: usize = 1 << 20;
    const last_index = @as(usize, @intCast((size - 1) / slice_size));
    const store = core.storage.FileStore{
        .files = &.{.{ .path = file_path, .length = size, .present = true }},
    };
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const last = try store.readSlice(scratch.allocator(), 0, slice_size, last_index);
    try std.testing.expectEqual(@as(usize, slice_size), last.len);
}

test "par2cmdline-turbo rfsc file id behavior (optional)" {
    if (!shouldRunTurboCompat()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const check = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ "par2", "-V" },
    });
    switch (check.term) {
        .Exited => |code| if (code != 0) return,
        else => return,
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tiny.bin", .data = "hello world" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ "par2", "create", "-s512", "-c1", "tiny", "tiny.bin" },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    var dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var saw_rfsc = false;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
        const full = try std.fs.path.join(arena.allocator(), &.{ tmp_path, entry.name });
        const bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), full, 1 << 20);
        var offset: usize = 0;
        while (offset + 64 <= bytes.len) : (offset += 1) {
            const remaining = bytes[offset..];
            const hdr = core.packet.parseHeader(remaining) catch {
                continue;
            };
            const end: usize = @intCast(hdr.length);
            if (end > remaining.len) break;
            const pkt = remaining[0..end];
            core.packet.verifyPacketHash(pkt) catch {
                offset += end - 1;
                continue;
            };
            const rfsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
            if (!std.mem.eql(u8, &hdr.packet_type, &rfsc_type)) {
                offset += end - 1;
                continue;
            }
            const parsed = try core.packet_types.parseRfsc(pkt, arena.allocator());
            saw_rfsc = true;
            const file = try std.fs.cwd().openFile(full, .{});
            defer file.close();
            const info = try file.stat();
            const file_len = info.size;
            if (file_len < 16384 and offset < 16384) {
                try std.testing.expect(std.mem.eql(u8, &parsed.file_id, &([_]u8{0} ** 16)));
            }
            offset += end - 1;
        }
    }
    if (!saw_rfsc) {
        const create2 = try std.process.Child.run(.{
            .allocator = arena.allocator(),
            .argv = &.{ "par2", "create", "-s4096", "-r200", "big", "tiny.bin" },
            .cwd = tmp_path,
        });
        switch (create2.term) {
            .Exited => |code| if (code != 0) return,
            else => return,
        }
        var dir2 = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
        defer dir2.close();
        var it2 = dir2.iterate();
        while (try it2.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
            const full = try std.fs.path.join(arena.allocator(), &.{ tmp_path, entry.name });
            const bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), full, 1 << 20);
            var offset: usize = 0;
            while (offset + 64 <= bytes.len) : (offset += 1) {
                const remaining = bytes[offset..];
                const hdr = core.packet.parseHeader(remaining) catch {
                    continue;
                };
                const end: usize = @intCast(hdr.length);
                if (end > remaining.len) break;
                const pkt = remaining[0..end];
                core.packet.verifyPacketHash(pkt) catch {
                    offset += end - 1;
                    continue;
                };
                const rfsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
                if (!std.mem.eql(u8, &hdr.packet_type, &rfsc_type)) {
                    offset += end - 1;
                    continue;
                }
                saw_rfsc = true;
                offset += end - 1;
            }
        }
    }
}

fn mktmpDir(allocator: std.mem.Allocator) ![]const u8 {
    var child = std.process.Child.init(&.{ "mktmp", "--tmpdir" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    var stdout = child.stdout.?;
    const raw = try stdout.readToEndAlloc(allocator, 4096);
    _ = try child.wait();
    const trimmed = std.mem.trimRight(u8, raw, "\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn writeRandomFile(path: []const u8, size: u64) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var remaining = size;
    var buf: [1024 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        std.crypto.random.bytes(buf[0..chunk]);
        try file.writeAll(buf[0..chunk]);
        remaining -= chunk;
    }
}

test "verifyIfsc detects match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "abcdEF";
    const entries = try core.slices.computeIfscEntries(arena.allocator(), data, 4);
    try core.slices.verifyIfsc(entries, entries);
}

test "findMismatchedSlices returns indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e0 = core.packet_types.IfscEntry{ .md5 = [_]u8{0} ** 16, .crc32 = 1 };
    const e1 = core.packet_types.IfscEntry{ .md5 = [_]u8{1} ** 16, .crc32 = 2 };
    const e2 = core.packet_types.IfscEntry{ .md5 = [_]u8{2} ** 16, .crc32 = 3 };
    const expected = [_]core.packet_types.IfscEntry{ e0, e1, e2 };
    const computed = [_]core.packet_types.IfscEntry{ e0, core.packet_types.IfscEntry{ .md5 = [_]u8{9} ** 16, .crc32 = 2 }, e2 };
    const mismatched = try core.slices.findMismatchedSlices(arena.allocator(), &computed, &expected);
    try std.testing.expectEqual(@as(usize, 1), mismatched.len);
    try std.testing.expectEqual(@as(usize, 1), mismatched[0]);
}

test "gf16 mul by 0 and 1" {
    try std.testing.expectEqual(@as(u16, 0), core.gf16.mul(0, 1234));
    try std.testing.expectEqual(@as(u16, 1234), core.gf16.mul(1, 1234));
}

test "gf16 exp/log invert for small values" {
    var i: u16 = 1;
    while (i < 100) : (i += 1) {
        const e = core.gf16.tables.exp[core.gf16.tables.log[i]];
        try std.testing.expectEqual(i, e);
    }
}

test "pcg32 deterministic sequence" {
    var rng_a = core.prng.Pcg32.init(42, 54);
    var rng_b = core.prng.Pcg32.init(42, 54);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(rng_a.nextU32(), rng_b.nextU32());
    }
}

test "pcg32 different seeds diverge" {
    var rng_a = core.prng.Pcg32.init(1, 1);
    var rng_b = core.prng.Pcg32.init(2, 1);
    var i: usize = 0;
    var diff = false;
    while (i < 8) : (i += 1) {
        if (rng_a.nextU32() != rng_b.nextU32()) {
            diff = true;
            break;
        }
    }
    try std.testing.expect(diff);
}

test "pcg32 non-repetition and distribution sanity" {
    var rng = core.prng.Pcg32.init(123, 456);
    const buf = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(buf);
    rng.fillBytes(buf);

    var counts: [256]u32 = [_]u32{0} ** 256;
    for (buf) |b| {
        counts[b] += 1;
    }
    var min: u32 = counts[0];
    var max: u32 = counts[0];
    var unique: u32 = 0;
    for (counts) |c| {
        if (c > 0) unique += 1;
        if (c < min) min = c;
        if (c > max) max = c;
    }
    try std.testing.expect(unique > 200);
    try std.testing.expect(min >= 100);
    try std.testing.expect(max <= 450);

    var rng2 = core.prng.Pcg32.init(123, 456);
    var prev = rng2.nextU32();
    var repeats: u32 = 0;
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const v = rng2.nextU32();
        if (v == prev) repeats += 1;
        prev = v;
    }
    try std.testing.expect(repeats == 0);
}

test "rs encode serial matches parallel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data_a = "abcd";
    const data_b = "wxyz";
    const slices = [_][]const u8{ data_a, data_b };
    var out_serial: [4]u8 = undefined;
    var out_parallel: [4]u8 = undefined;
    try core.rs.encodeRecoverySliceSerial(&out_serial, &slices, 7);
    try core.rs.encodeRecoverySlice(&out_parallel, &slices, 7);
    try std.testing.expectEqualSlices(u8, &out_serial, &out_parallel);
}

test "block_api batch parallel matches serial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "abcdefgh";
    const files = [_]core.layout.FileInfo{.{ .length = data.len }};
    const store = core.storage.MemoryStore{ .files = &.{data} };
    const exponents = [_]u32{ 1, 7 };

    const serial = try core.block_api.computeRecoverySlicesMemoryBatch(
        arena.allocator(),
        store,
        &files,
        4,
        &exponents,
    );
    const parallel = try core.block_api.computeRecoverySlicesMemoryBatchParallel(
        arena.allocator(),
        store,
        &files,
        4,
        &exponents,
    );
    try std.testing.expectEqual(@as(usize, serial.len), parallel.len);
    var i: usize = 0;
    while (i < serial.len) : (i += 1) {
        try std.testing.expectEqualSlices(u8, serial[i], parallel[i]);
    }
}

test "gf16 valid exponent filter" {
    try std.testing.expect(core.gf16.isValidExponent(1));
    try std.testing.expect(core.gf16.isValidExponent(2));
    try std.testing.expect(!core.gf16.isValidExponent(3));
    try std.testing.expect(!core.gf16.isValidExponent(5));
    try std.testing.expect(!core.gf16.isValidExponent(17));
    try std.testing.expect(!core.gf16.isValidExponent(257));
}

test "gf16 exponentForIndex returns valid exponents" {
    const e0 = core.gf16.exponentForIndex(0);
    const e1 = core.gf16.exponentForIndex(1);
    try std.testing.expect(core.gf16.isValidExponent(e0));
    try std.testing.expect(core.gf16.isValidExponent(e1));
    try std.testing.expect(e1 > e0);
}

test "gf16 max valid exponent count" {
    try std.testing.expectEqual(@as(u32, 32768), core.gf16.maxValidIndexCount());
}

test "rs encode rejects too many slices" {
    const max = core.gf16.maxValidIndexCount();
    const count = @as(usize, @intCast(max + 1));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var slices = try arena.allocator().alloc([]const u8, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        slices[i] = "aa";
    }
    var out: [2]u8 = undefined;
    try std.testing.expectError(error.TooManySlices, core.rs.encodeRecoverySlice(&out, slices, 1));
}

test "block size heuristic rounds to 4 and decreases with size" {
    const b1 = core.heuristics.blockSizeHeuristic(1024);
    const b2 = core.heuristics.blockSizeHeuristic(1024 * 1024);
    try std.testing.expect(b1 >= 4);
    try std.testing.expectEqual(@as(u64, 0), b1 % 4);
    try std.testing.expectEqual(@as(u64, 0), b2 % 4);
    const p1 = @as(f64, @floatFromInt(b1)) / 1024.0;
    const p2 = @as(f64, @floatFromInt(b2)) / (1024.0 * 1024.0);
    try std.testing.expect(p1 > p2);
}

test "packet_write builds verifiable packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{0} ** 16;
    const pkt_type: [16]u8 = .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'r', 'e', 'a', 't', 'o', 'r', 0 };
    const body = "hi";
    const pkt = try core.packet_write.buildPacket(arena.allocator(), rec_id, pkt_type, body);
    try core.packet.verifyPacketHash(pkt);
    const hdr = try core.packet.parseHeader(pkt);
    try std.testing.expectEqual(@as(u64, pkt.len), hdr.length);
}

test "parseMain reads non-recovery file ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body = try arena.allocator().alloc(u8, 12 + 32);
    const slice_size: u64 = 4096;
    body[0] = @as(u8, @intCast(slice_size & 0xFF));
    body[1] = @as(u8, @intCast((slice_size >> 8) & 0xFF));
    body[2] = @as(u8, @intCast((slice_size >> 16) & 0xFF));
    body[3] = @as(u8, @intCast((slice_size >> 24) & 0xFF));
    body[4] = @as(u8, @intCast((slice_size >> 32) & 0xFF));
    body[5] = @as(u8, @intCast((slice_size >> 40) & 0xFF));
    body[6] = @as(u8, @intCast((slice_size >> 48) & 0xFF));
    body[7] = @as(u8, @intCast((slice_size >> 56) & 0xFF));
    body[8] = 1;
    body[9] = 0;
    body[10] = 0;
    body[11] = 0;
    const rec_id = [_]u8{1} ** 16;
    const non_id = [_]u8{2} ** 16;
    @memcpy(body[12..28], &rec_id);
    @memcpy(body[28..44], &non_id);
    const pkt_type: [16]u8 = .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'M', 'a', 'i', 'n', 0, 0, 0, 0 };
    const pkt = try core.packet_write.buildPacket(arena.allocator(), .{0} ** 16, pkt_type, body);
    const parsed = try core.packet_types.parseMain(pkt, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), parsed.recovery_file_ids.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.non_recovery_file_ids.len);
}

test "create_packets builds filedesc round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{1} ** 16;
    const file_id: [16]u8 = .{2} ** 16;
    const file_hash: [16]u8 = .{3} ** 16;
    const file_hash_16k: [16]u8 = .{4} ** 16;
    const pkt = try core.create_packets.buildFileDescPacket(
        arena.allocator(),
        rec_id,
        file_id,
        file_hash,
        file_hash_16k,
        123,
        "hello.txt",
    );
    const parsed = try core.packet_types.parseFileDesc(pkt, arena.allocator());
    try std.testing.expectEqualSlices(u8, &file_id, &parsed.file_id);
    try std.testing.expectEqualSlices(u8, &file_hash, &parsed.file_hash);
    try std.testing.expectEqualSlices(u8, &file_hash_16k, &parsed.file_hash_16k);
    try std.testing.expectEqual(@as(u64, 123), parsed.file_length);
    try std.testing.expectEqualStrings("hello.txt", parsed.file_name);
}

test "create_packets builds unicode filename packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{5} ** 16;
    const file_id: [16]u8 = .{6} ** 16;
    const name = "hé";
    const pkt = try core.create_packets.buildUnicodeFilenamePacket(arena.allocator(), rec_id, file_id, name);
    const hdr = try core.packet.parseHeader(pkt);
    const body = pkt[64..@as(usize, @intCast(hdr.length))];
    try std.testing.expectEqualSlices(u8, &file_id, body[0..16]);
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(arena.allocator(), name);
    const expect_bytes = std.mem.sliceAsBytes(utf16);
    try std.testing.expectEqualSlices(u8, expect_bytes, body[16..]);
}

test "create_packets builds file slice packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{7} ** 16;
    const file_id: [16]u8 = .{8} ** 16;
    const data = "slice";
    const pkt = try core.create_packets.buildFileSlicPacket(arena.allocator(), rec_id, file_id, 12, data);
    const parsed = try core.packet_types.parseFileSlic(pkt);
    try std.testing.expectEqualSlices(u8, &file_id, &parsed.file_id);
    try std.testing.expectEqual(@as(u64, 12), parsed.slice_index);
    try std.testing.expect(std.mem.startsWith(u8, parsed.data, data));
}

test "create_packets builds packed main packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{9} ** 16;
    const rec_ids = [_][16]u8{ .{1} ** 16, .{2} ** 16 };
    const non_ids = [_][16]u8{.{3} ** 16};
    const body = try core.create_packets.buildPackedMainBody(arena.allocator(), 1024, 4096, &rec_ids, &non_ids);
    const pkt = try core.create_packets.buildPackedMainPacket(arena.allocator(), rec_id, body);
    const parsed = try core.packet_types.parsePackedMain(pkt, arena.allocator());
    try std.testing.expect(parsed.is_packed);
    try std.testing.expectEqual(@as(u64, 1024), parsed.subslice_size.?);
    try std.testing.expectEqual(@as(u64, 4096), parsed.slice_size);
    try std.testing.expectEqual(@as(usize, 2), parsed.recovery_file_ids.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.non_recovery_file_ids.len);
}

test "create_packets builds packed recovery slice packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{10} ** 16;
    const data = "abcd";
    const pkt = try core.create_packets.buildPackedRecvSlicPacket(arena.allocator(), rec_id, 7, data);
    const parsed = try core.packet_types.parsePackedRecvSlic(pkt);
    try std.testing.expectEqual(@as(u32, 7), parsed.exponent);
    try std.testing.expectEqualSlices(u8, data, parsed.data);
}

test "create_packets builds rfsc packet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec_id: [16]u8 = .{11} ** 16;
    const file_id: [16]u8 = .{12} ** 16;
    const e0 = core.packet_types.RfscEntry{ .md5 = .{0} ** 16, .crc32 = 1, .exponent = 2 };
    const e1 = core.packet_types.RfscEntry{ .md5 = .{1} ** 16, .crc32 = 3, .exponent = 4 };
    const pkt = try core.create_packets.buildRfscPacket(arena.allocator(), rec_id, file_id, &.{ e0, e1 });
    const parsed = try core.packet_types.parseRfsc(pkt, arena.allocator());
    try std.testing.expectEqualSlices(u8, &file_id, &parsed.file_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqual(@as(u32, 4), parsed.entries[1].exponent);
}

test "block size from count rounds up to 4 and covers total size" {
    const size = core.create_plan.blockSizeFromCount(10, 3);
    try std.testing.expectEqual(@as(u64, 4), size);
    try std.testing.expect(size * 3 >= 10);
}

test "recovery blocks from percent rounds up" {
    const blocks = try core.create_plan.recoveryBlocksFromPercent(10, 10);
    try std.testing.expectEqual(@as(u64, 1), blocks);
    const blocks2 = try core.create_plan.recoveryBlocksFromPercent(10, 15);
    try std.testing.expectEqual(@as(u64, 2), blocks2);
}

test "recovery blocks from percent detects overflow" {
    const max = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, core.create_plan.recoveryBlocksFromPercent(max, 2));
}

test "splitRecoveryBlocksDefault uses powers of two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try core.create_plan.splitRecoveryBlocksDefault(arena.allocator(), 256);
    try std.testing.expectEqual(@as(usize, 9), plan.len);
    try std.testing.expectEqual(@as(u64, 0), plan[0].start);
    try std.testing.expectEqual(@as(u64, 1), plan[0].count);
    try std.testing.expectEqual(@as(u64, 1), plan[1].start);
    try std.testing.expectEqual(@as(u64, 2), plan[1].count);
    try std.testing.expectEqual(@as(u64, 3), plan[2].start);
    try std.testing.expectEqual(@as(u64, 4), plan[2].count);
    try std.testing.expectEqual(@as(u64, 7), plan[3].start);
    try std.testing.expectEqual(@as(u64, 8), plan[3].count);
    try std.testing.expectEqual(@as(u64, 15), plan[4].start);
    try std.testing.expectEqual(@as(u64, 16), plan[4].count);
    try std.testing.expectEqual(@as(u64, 31), plan[5].start);
    try std.testing.expectEqual(@as(u64, 32), plan[5].count);
    try std.testing.expectEqual(@as(u64, 63), plan[6].start);
    try std.testing.expectEqual(@as(u64, 64), plan[6].count);
    try std.testing.expectEqual(@as(u64, 127), plan[7].start);
    try std.testing.expectEqual(@as(u64, 128), plan[7].count);
    try std.testing.expectEqual(@as(u64, 255), plan[8].start);
    try std.testing.expectEqual(@as(u64, 1), plan[8].count);
}

test "gf16 constants by index" {
    try std.testing.expectEqual(core.gf16.constantForExponent(1), core.gf16.constantForIndex(0));
    try std.testing.expectEqual(core.gf16.constantForExponent(2), core.gf16.constantForIndex(1));
    try std.testing.expectEqual(core.gf16.constantForExponent(4), core.gf16.constantForIndex(2));
}

test "parseHeader accepts valid header" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = 64;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 0;
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    const h = try core.packet.parseHeader(&buf);
    try std.testing.expectEqual(@as(u64, 64), h.length);
    try std.testing.expectEqual(@as(u8, 'P'), h.packet_type[0]);
}

test "parseHeader rejects short buffer" {
    var buf: [10]u8 = undefined;
    @memset(&buf, 0);
    try std.testing.expectError(error.OutOfBounds, core.packet.parseHeader(&buf));
}

test "parseHeader rejects bad magic" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'B';
    try std.testing.expectError(error.InvalidMagic, core.packet.parseHeader(&buf));
}

test "parseHeader rejects invalid length" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = 1;
    try std.testing.expectError(error.InvalidLength, core.packet.parseHeader(&buf));
}

test "verifyPacketHash accepts correct hash" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = 64;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 0;
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    var digest: [16]u8 = undefined;
    try core.md5.md5Digest(buf[32..64], &digest);
    @memcpy(buf[16..32], &digest);
    try core.packet.verifyPacketHash(&buf);
}

test "verifyPacketHash rejects mismatched hash" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = 64;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 0;
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    try std.testing.expectError(error.InvalidHash, core.packet.verifyPacketHash(&buf));
}

test "parseCreator returns body text" {
    var buf: [80]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = 80;
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    buf[56] = 'C';
    buf[57] = 'r';
    buf[58] = 'e';
    buf[59] = 'a';
    buf[60] = 't';
    buf[61] = 'o';
    buf[62] = 'r';
    buf[63] = 0;
    buf[64] = 'H';
    buf[65] = 'i';
    const p = try core.packet_types.parseCreator(&buf);
    try std.testing.expectEqualStrings("Hi", p.text);
}

test "parseMain reads slice size and file ids" {
    var buf: [64 + 12 + 16]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = @as(u8, @intCast(buf.len));
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    buf[56] = 'M';
    buf[57] = 'a';
    buf[58] = 'i';
    buf[59] = 'n';
    buf[64] = 0x00;
    buf[65] = 0x10;
    buf[66] = 0x00;
    buf[67] = 0x00;
    buf[68] = 0x00;
    buf[69] = 0x00;
    buf[70] = 0x00;
    buf[71] = 0x00;
    buf[72] = 0x01;
    buf[76] = 0xAA;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try core.packet_types.parseMain(&buf, arena.allocator());
    try std.testing.expectEqual(@as(u64, 0x1000), p.slice_size);
    try std.testing.expectEqual(@as(usize, 1), p.recovery_file_ids.len);
    try std.testing.expectEqual(@as(u8, 0xAA), p.recovery_file_ids[0][0]);
}

test "parseFileDesc reads fields and filename" {
    const name = "file.txt";
    const total_len = 64 + 56 + name.len;
    var buf = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = @as(u8, @intCast(total_len));
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    buf[56] = 'F';
    buf[57] = 'i';
    buf[58] = 'l';
    buf[59] = 'e';
    buf[60] = 'D';
    buf[61] = 'e';
    buf[62] = 's';
    buf[63] = 'c';
    buf[64] = 0xAA;
    buf[80] = 0xBB;
    buf[96] = 0xCC;
    buf[112] = 0x78;
    buf[113] = 0x56;
    buf[114] = 0x34;
    buf[115] = 0x12;
    @memcpy(buf[120 .. 120 + name.len], name);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try core.packet_types.parseFileDesc(buf, arena.allocator());
    try std.testing.expectEqual(@as(u8, 0xAA), p.file_id[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), p.file_hash[0]);
    try std.testing.expectEqual(@as(u8, 0xCC), p.file_hash_16k[0]);
    try std.testing.expectEqual(@as(u64, 0x12345678), p.file_length);
    try std.testing.expectEqualStrings(name, p.file_name);
}

test "parseIfsc reads entries" {
    const total_len = 64 + 16 + 20;
    var buf = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = @as(u8, @intCast(total_len));
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    buf[56] = 'I';
    buf[57] = 'F';
    buf[58] = 'S';
    buf[59] = 'C';
    buf[64] = 0xAB;
    buf[80] = 0xCD;
    buf[96] = 0x78;
    buf[97] = 0x56;
    buf[98] = 0x34;
    buf[99] = 0x12;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try core.packet_types.parseIfsc(buf, arena.allocator());
    try std.testing.expectEqual(@as(u8, 0xAB), p.file_id[0]);
    try std.testing.expectEqual(@as(usize, 1), p.entries.len);
    try std.testing.expectEqual(@as(u8, 0xCD), p.entries[0].md5[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), p.entries[0].crc32);
}

test "parseRecvSlic reads exponent and data" {
    const total_len = 64 + 4 + 3;
    var buf = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    buf[0] = 'P';
    buf[1] = 'A';
    buf[2] = 'R';
    buf[3] = '2';
    buf[4] = 0;
    buf[5] = 'P';
    buf[6] = 'K';
    buf[7] = 'T';
    buf[8] = @as(u8, @intCast(total_len));
    buf[48] = 'P';
    buf[49] = 'A';
    buf[50] = 'R';
    buf[51] = ' ';
    buf[52] = '2';
    buf[53] = '.';
    buf[54] = '0';
    buf[55] = 0;
    buf[56] = 'R';
    buf[57] = 'e';
    buf[58] = 'c';
    buf[59] = 'v';
    buf[60] = 'S';
    buf[61] = 'l';
    buf[62] = 'i';
    buf[63] = 'c';
    buf[64] = 0x2A;
    buf[68] = 0xAA;
    buf[69] = 0xBB;
    buf[70] = 0xCC;
    const p = try core.packet_types.parseRecvSlic(buf);
    try std.testing.expectEqual(@as(u32, 0x2A), p.exponent);
    try std.testing.expectEqual(@as(usize, 3), p.data.len);
    try std.testing.expectEqual(@as(u8, 0xAA), p.data[0]);
}

test "buildRecoverySet attaches file desc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ids = try arena.allocator().alloc([16]u8, 1);
    ids[0] = [_]u8{0x11} ** 16;
    const main = core.packet_types.MainPacket{
        .slice_size = 4096,
        .subslice_size = null,
        .recovery_file_ids = ids,
        .non_recovery_file_ids = &.{},
        .is_packed = false,
    };
    var set = try core.recovery_set.buildRecoverySet(arena.allocator(), main);
    const desc = core.packet_types.FileDescPacket{
        .file_id = ids[0],
        .file_hash = [_]u8{0} ** 16,
        .file_hash_16k = [_]u8{0} ** 16,
        .file_length = 0,
        .file_name = "x",
    };
    try core.recovery_set.attachFileDesc(&set, desc);
    try std.testing.expect(set.recovery_files[0].desc != null);
}

test "buildRecoverySet attaches non-recovery file desc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rec_ids = try arena.allocator().alloc([16]u8, 1);
    rec_ids[0] = [_]u8{0x11} ** 16;
    var non_ids = try arena.allocator().alloc([16]u8, 1);
    non_ids[0] = [_]u8{0x22} ** 16;
    const main = core.packet_types.MainPacket{
        .slice_size = 4096,
        .subslice_size = null,
        .recovery_file_ids = rec_ids,
        .non_recovery_file_ids = non_ids,
        .is_packed = false,
    };
    var set = try core.recovery_set.buildRecoverySet(arena.allocator(), main);
    const desc = core.packet_types.FileDescPacket{
        .file_id = non_ids[0],
        .file_hash = [_]u8{0} ** 16,
        .file_hash_16k = [_]u8{0} ** 16,
        .file_length = 0,
        .file_name = "y",
    };
    try core.recovery_set.attachFileDesc(&set, desc);
    try std.testing.expect(set.non_recovery_files[0].desc != null);
}

test "MemoryStore readSlice pads last slice" {
    const files = [_][]const u8{ "ABCDWXYZ", "EF" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = core.storage.MemoryStore{ .files = &files };
    const s0 = try store.readSlice(arena.allocator(), 0, 4, 1);
    try std.testing.expectEqualSlices(u8, "WXYZ", s0);
    const s1 = try store.readSlice(arena.allocator(), 1, 4, 0);
    const expect: [4]u8 = .{ 'E', 'F', 0, 0 };
    try std.testing.expectEqualSlices(u8, &expect, s1);
}

test "FileStore readSlice reads and pads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "f1.bin", .data = "ABCDWXYZ" });
    try tmp.dir.writeFile(.{ .sub_path = "f2.bin", .data = "EF" });
    const path1 = try tmp.dir.realpathAlloc(arena.allocator(), "f1.bin");
    const path2 = try tmp.dir.realpathAlloc(arena.allocator(), "f2.bin");
    const entries = [_]core.storage.FileEntry{
        .{ .path = path1, .length = 8, .present = true },
        .{ .path = path2, .length = 2, .present = true },
    };
    const store = core.storage.FileStore{ .files = &entries };
    const s0 = try store.readSlice(arena.allocator(), 0, 4, 1);
    try std.testing.expectEqualSlices(u8, "WXYZ", s0);
    const s1 = try store.readSlice(arena.allocator(), 1, 4, 0);
    const expect: [4]u8 = .{ 'E', 'F', 0, 0 };
    try std.testing.expectEqualSlices(u8, &expect, s1);
}

test "api verifyStore passes for fixture" {
    const par2_path = "fixtures/sample.par2";
    const data_path = "fixtures/sample.bin";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), data_path, 1 << 20);
    var ctx = core.api.initContext(arena.allocator());

    // Walk packets in the main .par2 and feed context.
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        try core.api.addPacket(arena.allocator(), &ctx, pkt);
        offset += end - 1;
    }

    const store = core.storage.MemoryStore{ .files = &.{data_bytes} };
    try core.api.verifyStore(arena.allocator(), &ctx, store);
}

test "api recoverMissingSlicesMemory recovers fixture slice" {
    const par2_path = "fixtures/sample.vol0+1.par2";
    const data_path = "fixtures/sample.bin";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), data_path, 1 << 20);
    const slice_size: usize = 4;

    // Find first RecvSlic packet.
    var offset: usize = 0;
    var rec: core.packet_types.RecvSlicPacket = undefined;
    var found = false;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        const t = hdr.packet_type;
        const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
        if (std.mem.eql(u8, &t, &recvslic)) {
            rec = try core.packet_types.parseRecvSlic(pkt);
            found = true;
            break;
        }
        offset += end - 1;
    }
    try std.testing.expect(found);

    const store = core.storage.MemoryStore{ .files = &.{data_bytes} };
    const files = [_]core.layout.FileInfo{.{ .length = @intCast(data_bytes.len) }};
    const missing = [_]usize{1};
    const recs = [_]core.rs.RecoverySlice{.{ .exponent = rec.exponent, .data = rec.data }};
    const recovered = try core.api.recoverMissingSlicesMemory(arena.allocator(), &files, store, &missing, &recs, slice_size);
    const expect_slice: [4]u8 = .{ 'W', 'X', 'Y', 'Z' };
    try std.testing.expectEqualSlices(u8, &expect_slice, recovered[0]);
}

test "api recoverMissingSlicesMemory skips missing slice reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slice_size: usize = 4;
    const data_s0 = "ABCD";
    const data_s1 = "WXYZ";
    var rec_buf: [4]u8 = undefined;
    try core.rs.encodeRecoverySlice(&rec_buf, &.{ data_s0, data_s1 }, 1);
    const files = [_]core.layout.FileInfo{.{ .length = 8 }};
    const store = core.storage.MemoryStore{ .files = &.{data_s0} };
    const missing = [_]usize{1};
    const recs = [_]core.rs.RecoverySlice{.{ .exponent = 1, .data = &rec_buf }};
    const recovered = try core.api.recoverMissingSlicesMemory(arena.allocator(), &files, store, &missing, &recs, slice_size);
    try std.testing.expectEqualSlices(u8, data_s1, recovered[0]);
}

test "rs encodeRecoverySlice shape" {
    var s1: [4]u8 = .{ 1, 2, 3, 4 };
    var s2: [4]u8 = .{ 5, 6, 7, 8 };
    var out: [4]u8 = undefined;
    try core.rs.encodeRecoverySlice(&out, &.{ &s1, &s2 }, 1);
    try std.testing.expect(out[0] != 0 or out[1] != 0 or out[2] != 0 or out[3] != 0);
}

test "rs matches par2cmdline fixture" {
    const par2_path = "fixtures/sample.vol0+1.par2";
    const data_path = "fixtures/sample.bin";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), data_path, 1 << 20);
    const slice_size: usize = 4;

    // Locate first RecvSlic packet in the recovery volume.
    var offset: usize = 0;
    var found = false;
    var exponent: u32 = 0;
    var rec_data: []const u8 = &.{};
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        const t = hdr.packet_type;
        const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
        if (std.mem.eql(u8, &t, &recvslic)) {
            const parsed = try core.packet_types.parseRecvSlic(pkt);
            exponent = parsed.exponent;
            rec_data = parsed.data;
            found = true;
            break;
        }
        offset += end - 1;
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, slice_size), rec_data.len);

    // Build padded data slices.
    const slice_count = try core.slices.sliceCount(@intCast(data_bytes.len), slice_size);
    var slices = try arena.allocator().alloc([]const u8, slice_count);
    var i: usize = 0;
    while (i < slice_count) : (i += 1) {
        const start = i * slice_size;
        const end = @min(start + slice_size, data_bytes.len);
        if (end - start == slice_size) {
            slices[i] = data_bytes[start..end];
        } else {
            var tmp = try arena.allocator().alloc(u8, slice_size);
            @memset(tmp, 0);
            @memcpy(tmp[0 .. end - start], data_bytes[start..end]);
            slices[i] = tmp;
        }
    }

    var out: [4]u8 = undefined;
    try core.rs.encodeRecoverySlice(&out, slices, exponent);
    try std.testing.expectEqualSlices(u8, rec_data, &out);
}

test "addPacket attaches filedesc and ifsc before main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const data = "abcdefgh";
    const file_id = try core.file_id.fileId(arena.allocator(), data, data.len, "a.bin");
    var file_hash: [16]u8 = undefined;
    try core.md5.md5Digest(data, &file_hash);
    const file_hash_16k = try core.file_id.md5_16k(data);
    const main_body = try core.create_packets.buildMainBody(arena.allocator(), 4, &.{file_id});
    var recovery_set_id: [16]u8 = undefined;
    try core.md5.md5Digest(main_body, &recovery_set_id);

    const filedesc = try core.create_packets.buildFileDescPacket(
        arena.allocator(),
        recovery_set_id,
        file_id,
        file_hash,
        file_hash_16k,
        data.len,
        "a.bin",
    );
    const ifsc = try core.create_packets.buildIfscPacket(
        arena.allocator(),
        recovery_set_id,
        file_id,
        try core.slices.computeIfscEntries(arena.allocator(), data, 4),
    );
    const main_pkt = try core.create_packets.buildMainPacket(arena.allocator(), recovery_set_id, main_body);

    var ctx = core.api.initContext(arena.allocator());
    try core.api.addPacket(arena.allocator(), &ctx, filedesc);
    try core.api.addPacket(arena.allocator(), &ctx, ifsc);
    try core.api.addPacket(arena.allocator(), &ctx, main_pkt);

    try std.testing.expect(ctx.recovery_set != null);
    const rs_set = ctx.recovery_set.?;
    try std.testing.expect(rs_set.recovery_files.len == 1);
    try std.testing.expect(rs_set.recovery_files[0].desc != null);
    try std.testing.expect(rs_set.recovery_files[0].ifsc != null);
}

test "block_api computeRecoverySliceMemory matches fixture" {
    const par2_path = "fixtures/sample.vol0+1.par2";
    const data_path = "fixtures/sample.bin";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), data_path, 1 << 20);
    const slice_size: usize = 4;

    // Find first RecvSlic packet.
    var offset: usize = 0;
    var rec: core.packet_types.RecvSlicPacket = undefined;
    var found = false;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        const t = hdr.packet_type;
        const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
        if (std.mem.eql(u8, &t, &recvslic)) {
            rec = try core.packet_types.parseRecvSlic(pkt);
            found = true;
            break;
        }
        offset += end - 1;
    }
    try std.testing.expect(found);

    const store = core.storage.MemoryStore{ .files = &.{data_bytes} };
    const files = [_]core.layout.FileInfo{.{ .length = @intCast(data_bytes.len) }};
    const out = try core.block_api.computeRecoverySliceMemory(arena.allocator(), store, &files, slice_size, rec.exponent);
    try std.testing.expectEqualSlices(u8, rec.data, out);
}

test "rs decodeMissingSlices recovers missing slice (fixture)" {
    const par2_path = "fixtures/sample.vol0+1.par2";
    const data_path = "fixtures/sample.bin";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), data_path, 1 << 20);
    const slice_size: usize = 4;

    // Find first RecvSlic packet.
    var offset: usize = 0;
    var rec: core.packet_types.RecvSlicPacket = undefined;
    var found = false;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        const t = hdr.packet_type;
        const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
        if (std.mem.eql(u8, &t, &recvslic)) {
            rec = try core.packet_types.parseRecvSlic(pkt);
            found = true;
            break;
        }
        offset += end - 1;
    }
    try std.testing.expect(found);

    const slice_count = try core.slices.sliceCount(@intCast(data_bytes.len), slice_size);
    var slices = try arena.allocator().alloc(?[]const u8, slice_count);
    var i: usize = 0;
    while (i < slice_count) : (i += 1) {
        const start = i * slice_size;
        const end = @min(start + slice_size, data_bytes.len);
        if (end - start == slice_size) {
            slices[i] = data_bytes[start..end];
        } else {
            var tmp = try arena.allocator().alloc(u8, slice_size);
            @memset(tmp, 0);
            @memcpy(tmp[0 .. end - start], data_bytes[start..end]);
            slices[i] = tmp;
        }
    }

    const missing_index: usize = 1;
    const missing = [_]usize{missing_index};
    const recs = [_]core.rs.RecoverySlice{.{ .exponent = rec.exponent, .data = rec.data }};
    slices[missing_index] = null;

    const recovered = try core.rs.decodeMissingSlices(arena.allocator(), slices, &missing, &recs, slice_size);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    const expect_slice: [4]u8 = .{ 'W', 'X', 'Y', 'Z' };
    try std.testing.expectEqualSlices(u8, &expect_slice, recovered[0]);
}

test "cli verify fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    const run = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "fixtures/sample.par2", "fixtures/sample.bin" },
    });
    switch (run.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "OK") != null);
}

test "cli verify accepts input files in any order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = "aaaa" });
    try tmp.dir.writeFile(.{ .sub_path = "b.bin", .data = "bbbb" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const cli_path = try cliPath(arena.allocator());

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4",
            "--recovery-blocks",
            "1",
            "set.par2",
            "a.bin",
            "b.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "set.par2", "b.bin", "a.bin" },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, verify.stdout, "OK") != null);
}

test "cli create accepts space separated short flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "data.bin", .data = "abcdef" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const cli_path = try cliPath(arena.allocator());

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "create", "-s", "4", "-r", "10", "out.par2", "data.bin" },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
}

test "cli create strips absolute paths in file names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "data.bin", .data = "abcdef" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const abs_path = try tmp.dir.realpathAlloc(arena.allocator(), "data.bin");
    const cli_path = try cliPath(arena.allocator());

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "create", "out.par2", abs_path },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const par2_path = try tmp.dir.realpathAlloc(arena.allocator(), "out.par2");
    const par2_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), par2_path, 1 << 20);
    var offset: usize = 0;
    var seen = false;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        const filedesc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'D', 'e', 's', 'c' };
        if (std.mem.eql(u8, &hdr.packet_type, &filedesc_type)) {
            const parsed = try core.packet_types.parseFileDesc(pkt, arena.allocator());
            try std.testing.expectEqualStrings("data.bin", parsed.file_name);
            try std.testing.expect(!std.fs.path.isAbsolute(parsed.file_name));
            seen = true;
            break;
        }
        offset += end - 1;
    }
    try std.testing.expect(seen);
}

test "cli verify resolves duplicate basenames by exact path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dir1");
    try tmp.dir.makePath("dir2");
    try tmp.dir.writeFile(.{ .sub_path = "dir1/file.bin", .data = "aaaa" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/file.bin", .data = "bbbb" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const cli_path = try cliPath(arena.allocator());

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "create", "dup.par2", "dir1/file.bin", "dir2/file.bin" },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "dup.par2", "dir1/file.bin", "dir2/file.bin" },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, verify.stdout, "OK") != null);
}

test "cli verify rejects ambiguous basenames when paths are not exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dir1");
    try tmp.dir.makePath("dir2");
    try tmp.dir.writeFile(.{ .sub_path = "dir1/file.bin", .data = "aaaa" });
    try tmp.dir.writeFile(.{ .sub_path = "dir2/file.bin", .data = "bbbb" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const abs1 = try tmp.dir.realpathAlloc(arena.allocator(), "dir1/file.bin");
    const abs2 = try tmp.dir.realpathAlloc(arena.allocator(), "dir2/file.bin");
    const cli_path = try cliPath(arena.allocator());

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "create", "dup.par2", "dir1/file.bin", "dir2/file.bin" },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "dup.par2", abs1, abs2 },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTerm,
    }
}

test "prng-gen produces deterministic output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const tool_path = try prngPath(arena.allocator());

    const run_a = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ tool_path, "a.bin", "1024", "123", "456" },
        .cwd = tmp_path,
    });
    switch (run_a.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const run_b = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ tool_path, "b.bin", "1024", "123", "456" },
        .cwd = tmp_path,
    });
    switch (run_b.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const a_bytes = try tmp.dir.readFileAlloc(arena.allocator(), "a.bin", 1 << 20);
    const b_bytes = try tmp.dir.readFileAlloc(arena.allocator(), "b.bin", 1 << 20);
    try std.testing.expectEqualSlices(u8, a_bytes, b_bytes);
}

test "cli recover writes to out-dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), "fixtures/sample.bin", 1 << 20);
    const corrupted = try arena.allocator().alloc(u8, data_bytes.len);
    @memcpy(corrupted, data_bytes);
    if (corrupted.len >= 5) {
        corrupted[4] ^= 0xFF;
    }
    try tmp.dir.writeFile(.{ .sub_path = "sample.bin", .data = corrupted });
    try tmp.dir.makePath("out");

    const data_path = try tmp.dir.realpathAlloc(arena.allocator(), "sample.bin");
    const out_dir = try tmp.dir.realpathAlloc(arena.allocator(), "out");

    const run = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "recover",
            "-o",
            out_dir,
            "fixtures/sample.par2",
            data_path,
        },
    });
    switch (run.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    const recovered_path = try std.fs.path.join(arena.allocator(), &.{ out_dir, "sample.bin" });
    const recovered_bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), recovered_path, 1 << 20);
    try std.testing.expectEqualSlices(u8, data_bytes, recovered_bytes);
}

test "cli create tar stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cli_path = try cliPath(arena.allocator());
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = "abcd" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const tar_path = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out.tar" });
    const out_dir = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out" });
    try std.fs.cwd().makePath(out_dir);

    const run = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4",
            "--recovery-blocks",
            "1",
            "--tar",
            "set.par2",
            "a.bin",
        },
        .cwd = tmp_path,
    });
    switch (run.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try tmp.dir.writeFile(.{ .sub_path = "out.tar", .data = run.stdout });

    const untar = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ "tar", "-xf", tar_path, "-C", out_dir },
    });
    switch (untar.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const main_path = try std.fs.path.join(arena.allocator(), &.{ out_dir, "set.par2" });
    const vol_path = try std.fs.path.join(arena.allocator(), &.{ out_dir, "set.vol0+1.par2" });
    _ = try std.fs.cwd().statFile(main_path);
    _ = try std.fs.cwd().statFile(vol_path);
}

test "cli recover tar stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cli_path = try cliPath(arena.allocator());
    try tmp.dir.writeFile(.{ .sub_path = "r.bin", .data = "ABCDEFGHABCDEFGH" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const tar_path = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out.tar" });
    const out_dir = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out" });
    try std.fs.cwd().makePath(out_dir);

    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4",
            "--recovery-blocks",
            "1",
            "r.par2",
            "r.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }

    try tmp.dir.writeFile(.{ .sub_path = "r.bin", .data = "XBCDEFGHABCDEFGH" });

    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "--tar", "r.par2", "r.bin" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try tmp.dir.writeFile(.{ .sub_path = "out.tar", .data = recover.stdout });

    const untar = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ "tar", "-xf", tar_path, "-C", out_dir },
    });
    switch (untar.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const recovered = try std.fs.cwd().readFileAlloc(arena.allocator(), try std.fs.path.join(arena.allocator(), &.{ out_dir, "r.bin" }), 1 << 20);
    try std.testing.expectEqualStrings("ABCDEFGHABCDEFGH", recovered);
}

test "cli create rfsc gated by volume size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cli_path = try cliPath(arena.allocator());
    try tmp.dir.writeFile(.{ .sub_path = "small.bin", .data = "0123456789abcdef" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const small_path = try tmp.dir.realpathAlloc(arena.allocator(), "small.bin");

    const create_small = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "1",
            "small.par2",
            small_path,
        },
        .cwd = tmp_path,
    });
    switch (create_small.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(!dirHasRfsc(arena.allocator(), tmp_path));

    try tmp.dir.writeFile(.{ .sub_path = "large.bin", .data = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" });
    const large_path = try tmp.dir.realpathAlloc(arena.allocator(), "large.bin");
    const create_large = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "8",
            "large.par2",
            large_path,
        },
        .cwd = tmp_path,
    });
    switch (create_large.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(dirHasRfsc(arena.allocator(), tmp_path));
}

test "cli recover from fileslic only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = "abcdefghijklmnopqrstuvwxyz" });
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "1",
            "--include-input-slices",
            "a.par2",
            "a.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try tmp.dir.deleteFile("a.bin");
    try tmp.dir.makePath("out");
    const out_dir = try tmp.dir.realpathAlloc(arena.allocator(), "out");
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-o", out_dir, "a.par2" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const recovered_path = try std.fs.path.join(arena.allocator(), &.{ out_dir, "a.bin" });
    const recovered = try std.fs.cwd().readFileAlloc(arena.allocator(), recovered_path, 1 << 20);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", recovered);
}

test "cli recover uses packed recvslic when recvslic missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "p.bin", .data = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "2",
            "--emit-packed",
            "p.par2",
            "p.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try stripPacketTypeInDir(arena.allocator(), tmp_path, recvslicType());
    try tmp.dir.writeFile(.{ .sub_path = "p.bin", .data = "X23456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" });
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-o", "out", "p.par2", "p.bin" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const out_path = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out", "p.bin" });
    const recovered = try std.fs.cwd().readFileAlloc(arena.allocator(), out_path, 1 << 20);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", recovered);
}

test "cli recover verifies full file hash after recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "h.bin", .data = "0123456789abcdef0123456789abcdef" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "2",
            "h.par2",
            "h.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try tmp.dir.writeFile(.{ .sub_path = "h.bin", .data = "X123456789abcdef0123456789abcdef" });
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-o", "out", "h.par2", "h.bin" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const out_path = try std.fs.path.join(arena.allocator(), &.{ tmp_path, "out", "h.bin" });
    const recovered = try std.fs.cwd().readFileAlloc(arena.allocator(), out_path, 1 << 20);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", recovered);
}

test "cli verify falls back to full-file hash when IFSC missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "v.bin", .data = "verify-hash-data-12345" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "1",
            "v.par2",
            "v.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try stripPacketTypeInDir(arena.allocator(), tmp_path, ifscType());
    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "v.par2", "v.bin" },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
}

test "cli verify detects corruption when IFSC missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "c.bin", .data = "verify-hash-data-ABCDE" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "1",
            "c.par2",
            "c.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try stripPacketTypeInDir(arena.allocator(), tmp_path, ifscType());
    try tmp.dir.writeFile(.{ .sub_path = "c.bin", .data = "Xerify-hash-data-ABCDE" });
    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "c.par2", "c.bin" },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTerm,
    }
}

test "cli verify succeeds under low memory cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const size: usize = 2 * 1024 * 1024;
    const buf = try arena.allocator().alloc(u8, size);
    @memset(buf, 'A');
    try tmp.dir.writeFile(.{ .sub_path = "cap.bin", .data = buf });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "2",
            "cap.par2",
            "cap.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const verify = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "verify", "-m", "1", "cap.par2", "cap.bin" },
        .cwd = tmp_path,
    });
    switch (verify.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, verify.stdout, "OK") != null);
}

test "cli create enforces memory cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const big = try arena.allocator().alloc(u8, 1024 * 1024);
    @memset(big, 'A');
    try tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = big });
    const run = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "-m",
            "1",
            "--block-size",
            "2097152",
            "--recovery-blocks",
            "1",
            "big.par2",
            "big.bin",
        },
        .cwd = tmp_path,
    });
    switch (run.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTerm,
    }
}

test "cli recover enforces memory cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const big = try arena.allocator().alloc(u8, 2 * 1024 * 1024);
    @memset(big, 'B');
    try tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = big });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "4",
            "big.par2",
            "big.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try tmp.dir.deleteFile("big.bin");
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-m", "1", "-o", "out", "big.par2" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTerm,
    }
}

test "c api create/verify with memory input" {
    const par2 = @import("par2");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const par2_path = try std.fs.path.join(allocator, &.{ tmp_path, "mem.par2" });

    var create_handle: ?*par2.Par2CreateHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_new(null, &create_handle));
    defer par2.par2_create_destroy(create_handle);
    const payload = "0123456789abcdef";
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_add_memory(create_handle, "mem.bin", payload, payload.len));
    const par2_path_z = try allocator.dupeZ(u8, par2_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_path(create_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_run(create_handle));

    var verify_handle: ?*par2.Par2VerifyHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_new(null, &verify_handle));
    defer par2.par2_verify_destroy(verify_handle);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_set_par2_path(verify_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_add_memory(verify_handle, "mem.bin", payload, payload.len));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_run(verify_handle));
}

test "c api create/verify with stream input" {
    const par2 = @import("par2");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const par2_path = try std.fs.path.join(allocator, &.{ tmp_path, "stream.par2" });

    var create_handle: ?*par2.Par2CreateHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_new(null, &create_handle));
    defer par2.par2_create_destroy(create_handle);
    const payload = "0123456789abcdef";
    var mem_ctx = StreamMemCtx{ .data = payload };
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_add_stream(create_handle, "stream.bin", payload.len, capiReadAt, &mem_ctx));
    const par2_path_z = try allocator.dupeZ(u8, par2_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_path(create_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_run(create_handle));

    var verify_handle: ?*par2.Par2VerifyHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_new(null, &verify_handle));
    defer par2.par2_verify_destroy(verify_handle);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_set_par2_path(verify_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_add_stream(verify_handle, "stream.bin", payload.len, capiReadAt, &mem_ctx));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_run(verify_handle));
}

test "ffi swift example (optional)" {
	if (!commandAvailable(std.testing.allocator, "swiftc")) return;
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const lib_path = try sharedLibPath(allocator);
	std.fs.cwd().access(lib_path, .{}) catch return error.FileNotFound;
	const lib_dir = std.fs.path.dirname(lib_path) orelse ".";

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
	const out_path = try std.fs.path.join(allocator, &.{ tmp_path, "swift.par2" });
	const swift_path = try std.fs.path.join(allocator, &.{ tmp_path, "main.swift" });
	const bin_path = try std.fs.path.join(allocator, &.{ tmp_path, "swift-ffi-test" });

	var src = std.ArrayList(u8).empty;
	defer src.deinit(allocator);
	try src.appendSlice(allocator, "import Foundation\n");
	try src.appendSlice(allocator, "typealias Par2CreateHandle = OpaquePointer\n");
	try src.appendSlice(allocator, "typealias Par2Error = Int32\n");
	try src.appendSlice(allocator, "@_silgen_name(\"par2_create_new\") func par2_create_new(_ opts: UnsafeRawPointer?, _ out: UnsafeMutablePointer<Par2CreateHandle?>) -> Par2Error\n");
	try src.appendSlice(allocator, "@_silgen_name(\"par2_create_add_memory\") func par2_create_add_memory(_ h: Par2CreateHandle?, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<UInt8>, _ len: Int) -> Par2Error\n");
	try src.appendSlice(allocator, "@_silgen_name(\"par2_create_set_output_path\") func par2_create_set_output_path(_ h: Par2CreateHandle?, _ path: UnsafePointer<CChar>) -> Par2Error\n");
	try src.appendSlice(allocator, "@_silgen_name(\"par2_create_run\") func par2_create_run(_ h: Par2CreateHandle?) -> Par2Error\n");
	try src.appendSlice(allocator, "@_silgen_name(\"par2_create_destroy\") func par2_create_destroy(_ h: Par2CreateHandle?)\n");
	try src.appendSlice(allocator, "func check(_ rc: Par2Error) {\n");
	try src.appendSlice(allocator, "    if rc != 0 { exit(1) }\n");
	try src.appendSlice(allocator, "}\n");
	try src.appendSlice(allocator, "let payload: [UInt8] = [0,1,2,3,4,5,6,7]\n");
	try src.appendSlice(allocator, "var handle: Par2CreateHandle?\n");
	try src.appendSlice(allocator, "check(par2_create_new(nil, &handle))\n");
	try src.appendSlice(allocator, "payload.withUnsafeBytes { buf in\n");
	try src.appendSlice(allocator, "    \"data.bin\".withCString { name in\n");
	try src.appendSlice(allocator, "        check(par2_create_add_memory(handle, name, buf.bindMemory(to: UInt8.self).baseAddress!, buf.count))\n");
	try src.appendSlice(allocator, "    }\n");
	try src.appendSlice(allocator, "}\n");
	const out_line = try std.fmt.allocPrint(allocator, "\"{s}\".withCString {{ path in check(par2_create_set_output_path(handle, path)) }}\n", .{out_path});
	defer allocator.free(out_line);
	try src.appendSlice(allocator, out_line);
	try src.appendSlice(allocator, "check(par2_create_run(handle))\n");
	try src.appendSlice(allocator, "par2_create_destroy(handle)\n");
	try src.appendSlice(allocator, "exit(0)\n");
	try tmp.dir.writeFile(.{ .sub_path = "main.swift", .data = src.items });

	var compile_env = std.process.EnvMap.init(allocator);
	defer compile_env.deinit();
	try compile_env.put("PATH", "/usr/bin:/bin");
	if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
		defer allocator.free(home);
		try compile_env.put("HOME", home);
	} else |_| {}
	if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |tmpdir| {
		defer allocator.free(tmpdir);
		try compile_env.put("TMPDIR", tmpdir);
	} else |_| {}
	if (commandAvailable(allocator, "xcrun")) {
		if (xcodeSelectPath(allocator)) |dev| {
			defer allocator.free(dev);
			try compile_env.put("DEVELOPER_DIR", dev);
		}
		try compile_env.put("TOOLCHAINS", "com.apple.dt.toolchain.XcodeDefault");
	}
	var sdk_path: ?[]const u8 = null;
	const sdk = swiftSdkRootFromXcrun(allocator) catch null;
	if (sdk) |path| {
		sdk_path = path;
		try compile_env.put("SDKROOT", path);
	}
	defer if (sdk_path) |path| allocator.free(path);
	const compile_argv = try swiftCompileArgv(allocator, swift_path, lib_dir, bin_path, sdk_path);
	defer allocator.free(compile_argv);
	const compile = try std.process.Child.run(.{
		.allocator = allocator,
		.argv = compile_argv,
		.env_map = &compile_env,
		.cwd = tmp_path,
	});
	defer allocator.free(compile.stdout);
	defer allocator.free(compile.stderr);
	switch (compile.term) {
		.Exited => |code| {
			if (code != 0) {
				if (compile.stdout.len > 0) std.debug.print("swiftc stdout:\n{s}\n", .{compile.stdout});
				if (compile.stderr.len > 0) std.debug.print("swiftc stderr:\n{s}\n", .{compile.stderr});
				return error.UnexpectedTerm;
			}
		},
		else => return error.UnexpectedTerm,
	}

	var env = std.process.EnvMap.init(allocator);
	defer env.deinit();
	try env.put(libPathEnvName(), lib_dir);
	try runCommandExpectOk(allocator, &.{ bin_path }, &env, tmp_path);

	_ = try std.fs.cwd().statFile(out_path);
}

test "ffi luajit example (optional)" {
	if (!commandAvailable(std.testing.allocator, "luajit")) return;
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const lib_path = try sharedLibPath(allocator);
	std.fs.cwd().access(lib_path, .{}) catch return error.FileNotFound;
	const lib_dir = std.fs.path.dirname(lib_path) orelse ".";

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
	const out_path = try std.fs.path.join(allocator, &.{ tmp_path, "lua.par2" });
	const script_path = try std.fs.path.join(allocator, &.{ tmp_path, "ffi.lua" });

	var src = std.ArrayList(u8).empty;
	defer src.deinit(allocator);
	try src.appendSlice(allocator, "local ffi = require(\"ffi\")\n");
	try src.appendSlice(allocator, "ffi.cdef[[\n");
	try src.appendSlice(allocator, "typedef struct Par2CreateHandle Par2CreateHandle;\n");
	try src.appendSlice(allocator, "typedef int Par2Error;\n");
	try src.appendSlice(allocator, "Par2Error par2_create_new(const void *opts, Par2CreateHandle **out_handle);\n");
	try src.appendSlice(allocator, "Par2Error par2_create_add_memory(Par2CreateHandle *h, const char *name, const uint8_t *data, size_t len);\n");
	try src.appendSlice(allocator, "Par2Error par2_create_set_output_path(Par2CreateHandle *h, const char *par2_path);\n");
	try src.appendSlice(allocator, "Par2Error par2_create_run(Par2CreateHandle *h);\n");
	try src.appendSlice(allocator, "void par2_create_destroy(Par2CreateHandle *h);\n");
	try src.appendSlice(allocator, "]]\n");
	const lib_line = try std.fmt.allocPrint(allocator, "local lib = ffi.load(\"{s}\")\n", .{lib_path});
	defer allocator.free(lib_line);
	try src.appendSlice(allocator, lib_line);
	try src.appendSlice(allocator, "local data = ffi.new(\"uint8_t[8]\", {0,1,2,3,4,5,6,7})\n");
	try src.appendSlice(allocator, "local handle = ffi.new(\"Par2CreateHandle*[1]\")\n");
	try src.appendSlice(allocator, "if lib.par2_create_new(nil, handle) ~= 0 then os.exit(1) end\n");
	try src.appendSlice(allocator, "if lib.par2_create_add_memory(handle[0], \"data.bin\", data, 8) ~= 0 then os.exit(1) end\n");
	const out_line = try std.fmt.allocPrint(allocator, "if lib.par2_create_set_output_path(handle[0], \"{s}\") ~= 0 then os.exit(1) end\n", .{out_path});
	defer allocator.free(out_line);
	try src.appendSlice(allocator, out_line);
	try src.appendSlice(allocator, "if lib.par2_create_run(handle[0]) ~= 0 then os.exit(1) end\n");
	try src.appendSlice(allocator, "lib.par2_create_destroy(handle[0])\n");
	try src.appendSlice(allocator, "os.exit(0)\n");
	try tmp.dir.writeFile(.{ .sub_path = "ffi.lua", .data = src.items });

	var env = std.process.EnvMap.init(allocator);
	defer env.deinit();
	try env.put(libPathEnvName(), lib_dir);
	try runCommandExpectOk(allocator, &.{ "luajit", script_path }, &env, tmp_path);

	_ = try std.fs.cwd().statFile(out_path);
}

const CapiBuffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
};

const CapiCapture = struct {
    allocator: std.mem.Allocator,
    main: ?*CapiBuffer = null,
    last_path: ?[]u8 = null,
};

fn capiWrite(ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) usize {
    if (ctx == null) return 0;
    const buf: *CapiBuffer = @ptrCast(@alignCast(ctx.?));
    buf.data.appendSlice(buf.allocator, data[0..len]) catch return 0;
    return len;
}

fn capiDiscard(ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) usize {
    _ = ctx;
    _ = data;
    return len;
}

fn capiClose(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn capiOpen(ctx: ?*anyopaque, path: [*:0]const u8, out: *lib.Par2Output) callconv(.c) lib.Par2Error {
    if (ctx == null) return .invalid_argument;
    const capture: *CapiCapture = @ptrCast(@alignCast(ctx.?));
    const path_slice = std.mem.span(path);
    if (capture.last_path) |old| capture.allocator.free(old);
    capture.last_path = capture.allocator.dupe(u8, path_slice) catch return .out_of_memory;
    if (std.mem.indexOf(u8, path_slice, ".vol") != null) {
        out.* = .{ .ctx = null, .write = capiDiscard, .close = capiClose };
        return .ok;
    }
    const buf = capture.allocator.create(CapiBuffer) catch return .out_of_memory;
    buf.* = .{ .allocator = capture.allocator, .data = std.ArrayList(u8).empty };
    if (std.mem.endsWith(u8, path_slice, ".par2") or capture.main == null) {
        capture.main = buf;
    }
    out.* = .{ .ctx = buf, .write = capiWrite, .close = capiClose };
    return .ok;
}

test "c api create uses output_open" {
    const par2 = @import("par2");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const par2_path = try std.fs.path.join(allocator, &.{ tmp_path, "cap.par2" });
    const rec_path = try std.fs.path.join(allocator, &.{ tmp_path, "cap.bin" });
    try tmp.dir.writeFile(.{ .sub_path = "cap.bin", .data = "ABCDEFGHABCDEFGH" });

    var capture = CapiCapture{ .allocator = allocator };
    defer if (capture.last_path) |p| allocator.free(p);

    var create_handle: ?*par2.Par2CreateHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_new(null, &create_handle));
    defer par2.par2_create_destroy(create_handle);
    const rec_path_z = try allocator.dupeZ(u8, rec_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_add_path(create_handle, rec_path_z));
    const par2_path_z = try allocator.dupeZ(u8, par2_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_path(create_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_open(create_handle, capiOpen, &capture));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_run(create_handle));

    try std.testing.expect(capture.main != null);
    const main_buf = capture.main.?;
    defer {
        main_buf.data.deinit(main_buf.allocator);
        allocator.destroy(main_buf);
    }
    try std.testing.expect(main_buf.data.items.len > 0);

    var verify_handle: ?*par2.Par2VerifyHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_new(null, &verify_handle));
    defer par2.par2_verify_destroy(verify_handle);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_set_par2_data(verify_handle, main_buf.data.items.ptr, main_buf.data.items.len));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_add_path(verify_handle, rec_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_verify_run(verify_handle));
}

test "c api recover uses output_open" {
    const par2 = @import("par2");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const par2_path = try std.fs.path.join(allocator, &.{ tmp_path, "rec.par2" });
    const par2_path_z = try allocator.dupeZ(u8, par2_path);

    try tmp.dir.writeFile(.{ .sub_path = "rec.bin", .data = "ABCDEFGHABCDEFGH" });

    var create_handle: ?*par2.Par2CreateHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_new(null, &create_handle));
    defer par2.par2_create_destroy(create_handle);
    const rec_path = try std.fs.path.join(allocator, &.{ tmp_path, "rec.bin" });
    const rec_path_z = try allocator.dupeZ(u8, rec_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_add_path(create_handle, rec_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_path(create_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_run(create_handle));

    try tmp.dir.writeFile(.{ .sub_path = "rec.bin", .data = "XBCDEFGHABCDEFGH" });

    var capture = CapiCapture{ .allocator = allocator };
    defer if (capture.last_path) |p| allocator.free(p);

    var recover_handle: ?*par2.Par2RecoverHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_new(null, &recover_handle));
    defer par2.par2_recover_destroy(recover_handle);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_set_par2_path(recover_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_add_path(recover_handle, rec_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_set_output_open(recover_handle, capiOpen, &capture));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_run(recover_handle));

    try std.testing.expect(capture.main != null);
    const buf = capture.main.?;
    defer {
        buf.data.deinit(buf.allocator);
        allocator.destroy(buf);
    }
    try std.testing.expectEqualStrings("ABCDEFGHABCDEFGH", buf.data.items);
}

test "c api recover writes to output dir" {
    const par2 = @import("par2");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const par2_path = try std.fs.path.join(allocator, &.{ tmp_path, "rec.par2" });
    const par2_path_z = try allocator.dupeZ(u8, par2_path);

    try tmp.dir.writeFile(.{ .sub_path = "rec.bin", .data = "ABCDEFGHABCDEFGH" });

    var create_handle: ?*par2.Par2CreateHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_new(null, &create_handle));
    defer par2.par2_create_destroy(create_handle);
    const rec_path = try std.fs.path.join(allocator, &.{ tmp_path, "rec.bin" });
    const rec_path_z = try allocator.dupeZ(u8, rec_path);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_add_path(create_handle, rec_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_set_output_path(create_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_create_run(create_handle));

    try tmp.dir.writeFile(.{ .sub_path = "rec.bin", .data = "XBCDEFGHABCDEFGH" });

    const out_dir = try std.fs.path.join(allocator, &.{ tmp_path, "out" });
    try std.fs.cwd().makePath(out_dir);

    var recover_handle: ?*par2.Par2RecoverHandle = null;
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_new(null, &recover_handle));
    defer par2.par2_recover_destroy(recover_handle);
    const out_dir_z = try allocator.dupeZ(u8, out_dir);
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_set_par2_path(recover_handle, par2_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_add_path(recover_handle, rec_path_z));
    try std.testing.expectEqual(par2.Par2Error.ok, par2.par2_recover_set_output_dir(recover_handle, out_dir_z));
    const recover_rc = par2.par2_recover_run(recover_handle);
    if (recover_rc != par2.Par2Error.ok) {
        if (par2.par2_recover_last_error(recover_handle)) |msg| {
            std.debug.print("c api recover error: {s}\n", .{std.mem.span(msg)});
        }
    }
    try std.testing.expectEqual(par2.Par2Error.ok, recover_rc);

    const recovered = try tmp.dir.readFileAlloc(allocator, "out/rec.bin", 1 << 20);
    try std.testing.expectEqualStrings("ABCDEFGHABCDEFGH", recovered);
}

test "cli recover rejects recovery slices that fail rfsc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const data = try arena.allocator().alloc(u8, 32768);
    @memset(data, 'A');
    try tmp.dir.writeFile(.{ .sub_path = "r.bin", .data = data });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "4096",
            "--recovery-blocks",
            "8",
            "r.par2",
            "r.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try corruptFirstRecvSlicInDir(arena.allocator(), tmp_path);
    try tmp.dir.deleteFile("r.bin");
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-o", "out", "r.par2" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTerm,
    }
}

test "cli create duplicates metadata in volume files by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "m.bin", .data = "abcdefghijklmno" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "1",
            "m.par2",
            "m.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const vol_path = try findFirstVolume(arena.allocator(), tmp_path);
    const bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), vol_path, 1 << 20);
    try std.testing.expect(fileHasPacketType(bytes, mainType()));
    try std.testing.expect(fileHasPacketType(bytes, filedescType()));
    try std.testing.expect(fileHasPacketType(bytes, ifscType()));
    try std.testing.expect(fileHasPacketType(bytes, creatorType()));
}

test "cli create can omit volume metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "n.bin", .data = "abcdefghijklmno" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "1",
            "--no-volume-meta",
            "n.par2",
            "n.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const vol_path = try findFirstVolume(arena.allocator(), tmp_path);
    const bytes = try std.fs.cwd().readFileAlloc(arena.allocator(), vol_path, 1 << 20);
    try std.testing.expect(!fileHasPacketType(bytes, mainType()));
    try std.testing.expect(!fileHasPacketType(bytes, filedescType()));
    try std.testing.expect(!fileHasPacketType(bytes, ifscType()));
    try std.testing.expect(!fileHasPacketType(bytes, creatorType()));
}

test "cli recover multi-file ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cli_path = try cliPath(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = "AAAAAAAABBBBBBBB" });
    try tmp.dir.writeFile(.{ .sub_path = "b.bin", .data = "CCCCCCCCDDDDDDDD" });
    const create = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{
            cli_path,
            "create",
            "--block-size",
            "8",
            "--recovery-blocks",
            "2",
            "m.par2",
            "a.bin",
            "b.bin",
        },
        .cwd = tmp_path,
    });
    switch (create.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    {
        var a_bytes = try tmp.dir.readFileAlloc(arena.allocator(), "a.bin", 1 << 20);
        a_bytes[0] ^= 0xFF;
        try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = a_bytes });
        var b_bytes = try tmp.dir.readFileAlloc(arena.allocator(), "b.bin", 1 << 20);
        b_bytes[8] ^= 0xFF;
        try tmp.dir.writeFile(.{ .sub_path = "b.bin", .data = b_bytes });
    }
    const recover = try std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ cli_path, "recover", "-o", "out", "m.par2", "a.bin", "b.bin" },
        .cwd = tmp_path,
    });
    switch (recover.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    const out_a = try tmp.dir.readFileAlloc(arena.allocator(), "out/a.bin", 1 << 20);
    const out_b = try tmp.dir.readFileAlloc(arena.allocator(), "out/b.bin", 1 << 20);
    try std.testing.expectEqualStrings("AAAAAAAABBBBBBBB", out_a);
    try std.testing.expectEqualStrings("CCCCCCCCDDDDDDDD", out_b);
}

fn dirHasRfsc(allocator: std.mem.Allocator, dir_path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return false) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
        if (std.mem.indexOf(u8, entry.name, ".vol") == null) continue;
        const full = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
        const bytes = std.fs.cwd().readFileAlloc(allocator, full, 1 << 20) catch continue;
        if (fileHasRfsc(bytes)) return true;
    }
    return false;
}

fn fileHasRfsc(bytes: []const u8) bool {
    var offset: usize = 0;
    const rfsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
    while (offset + 64 <= bytes.len) : (offset += 1) {
        const remaining = bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            offset += end - 1;
            continue;
        };
        if (std.mem.eql(u8, &hdr.packet_type, &rfsc_type)) return true;
        offset += end - 1;
    }
    return false;
}

fn fileHasPacketType(bytes: []const u8, packet_type: [16]u8) bool {
    var offset: usize = 0;
    while (offset + 64 <= bytes.len) : (offset += 1) {
        const remaining = bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            offset += end - 1;
            continue;
        };
        if (std.mem.eql(u8, &hdr.packet_type, &packet_type)) return true;
        offset += end - 1;
    }
    return false;
}

fn findFirstVolume(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
        if (std.mem.indexOf(u8, entry.name, ".vol") == null) continue;
        return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
    }
    return error.NotFound;
}

fn creatorType() [16]u8 {
    return .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'r', 'e', 'a', 't', 'o', 'r', 0 };
}

fn mainType() [16]u8 {
    return .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'M', 'a', 'i', 'n', 0, 0, 0, 0 };
}

fn filedescType() [16]u8 {
    return .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'D', 'e', 's', 'c' };
}

fn ifscType() [16]u8 {
    return .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'I', 'F', 'S', 'C', 0, 0, 0, 0 };
}

test "addPacket ignores duplicate main without dropping file desc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var file_id: [16]u8 = undefined;
    var file_hash: [16]u8 = undefined;
    var file_hash_16k: [16]u8 = undefined;
    try core.md5.md5Digest("file-id", &file_id);
    try core.md5.md5Digest("file-hash", &file_hash);
    try core.md5.md5Digest("file-hash-16k", &file_hash_16k);

    const main_body = try core.create_packets.buildMainBody(allocator, 8, &.{file_id});
    var recovery_set_id: [16]u8 = undefined;
    try core.md5.md5Digest(main_body, &recovery_set_id);
    const main_pkt = try core.create_packets.buildMainPacket(allocator, recovery_set_id, main_body);
    const filedesc_pkt = try core.create_packets.buildFileDescPacket(
        allocator,
        recovery_set_id,
        file_id,
        file_hash,
        file_hash_16k,
        26,
        "a.bin",
    );

    var ctx = core.api.initContext(allocator);
    try core.api.addPacket(allocator, &ctx, main_pkt);
    try core.api.addPacket(allocator, &ctx, filedesc_pkt);
    try std.testing.expect(ctx.recovery_set != null);
    try std.testing.expect(ctx.recovery_set.?.recovery_files.len == 1);
    try std.testing.expect(ctx.recovery_set.?.recovery_files[0].desc != null);

    try core.api.addPacket(allocator, &ctx, main_pkt);
    try std.testing.expect(ctx.recovery_set.?.recovery_files[0].desc != null);
}

fn recvslicType() [16]u8 {
    return .{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
}

fn stripPacketTypeInDir(allocator: std.mem.Allocator, dir_path: []const u8, packet_type: [16]u8) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        try stripPacketTypeInFile(allocator, full, packet_type);
    }
}

fn stripPacketTypeInFile(allocator: std.mem.Allocator, path: []const u8, packet_type: [16]u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var offset: usize = 0;
    while (offset + 64 <= bytes.len) : (offset += 1) {
        const remaining = bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        if (std.mem.eql(u8, &hdr.packet_type, &packet_type)) {
            offset += end - 1;
            continue;
        }
        try out.appendSlice(allocator, remaining[0..end]);
        offset += end - 1;
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

fn corruptFirstRecvSlicInDir(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".par2")) continue;
        if (std.mem.indexOf(u8, entry.name, ".vol") == null) continue;
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        const bytes = try std.fs.cwd().readFileAlloc(allocator, full, 1 << 20);
        if (!fileHasRfsc(bytes)) continue;
        if (try corruptFirstRecvSlicPacket(full)) return;
    }
}

fn corruptFirstRecvSlicPacket(path: []const u8) !bool {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const info = try file.stat();
    const len = info.size;
    var bytes = try std.heap.page_allocator.alloc(u8, @as(usize, @intCast(len)));
    defer std.heap.page_allocator.free(bytes);
    _ = try file.readAll(bytes);
    var offset: usize = 0;
    const recvslic = recvslicType();
    while (offset + 64 <= bytes.len) : (offset += 1) {
        const remaining = bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        if (!std.mem.eql(u8, &hdr.packet_type, &recvslic)) {
            offset += end - 1;
            continue;
        }
        if (end - 64 < 5) return false;
        bytes[offset + 68] ^= 0xFF;
        var digest: [16]u8 = undefined;
        try core.md5.md5Digest(bytes[offset + 32 .. offset + end], &digest);
        @memcpy(bytes[offset + 16 .. offset + 32], &digest);
        try file.seekTo(0);
        try file.writeAll(bytes);
        return true;
    }
    return false;
}
