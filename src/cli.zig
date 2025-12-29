const std = @import("std");
const ops = @import("ops");

fn infoFile() std.fs.File {
    return if (ops.stdoutToStderrEnabled()) std.fs.File.stderr() else std.fs.File.stdout();
}

const TarEntry = struct {
    name: []const u8,
    data: []const u8,
};

const TarBuffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
};

const TarCapture = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(TarBuffer),
};

fn tarCaptureInit(allocator: std.mem.Allocator) TarCapture {
    return .{ .allocator = allocator, .map = std.StringHashMap(TarBuffer).init(allocator) };
}

fn tarCaptureDeinit(cap: *TarCapture) void {
    var it = cap.map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.data.deinit(cap.allocator);
        cap.allocator.free(entry.key_ptr.*);
    }
    cap.map.deinit();
}

fn tarCaptureWrite(ctx: *anyopaque, data: []const u8) anyerror!usize {
    const buf: *TarBuffer = @ptrCast(@alignCast(ctx));
    try buf.data.appendSlice(buf.allocator, data);
    return data.len;
}

fn tarCaptureClose(_: *anyopaque) void {}

fn safeTarName(path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.basename(path);
    if (std.mem.indexOf(u8, path, "..")) |_| return std.fs.path.basename(path);
    return path;
}

fn tarOpen(ctx: *anyopaque, path: []const u8) anyerror!ops.OutputTarget {
    const cap: *TarCapture = @ptrCast(@alignCast(ctx));
    const name = safeTarName(path);
    if (cap.map.getPtr(name)) |existing| {
        existing.*.data.clearRetainingCapacity();
        return .{ .ctx = existing, .writeFn = tarCaptureWrite, .closeFn = tarCaptureClose };
    }
    const key = try cap.allocator.dupe(u8, name);
    const buf_val = TarBuffer{ .allocator = cap.allocator, .data = std.ArrayList(u8).empty };
    try cap.map.put(key, buf_val);
    const buf = cap.map.getPtr(key).?;
    return .{ .ctx = buf, .writeFn = tarCaptureWrite, .closeFn = tarCaptureClose };
}

fn writeTarHeader(writer: std.fs.File, name: []const u8, size: usize) !void {
    var header: [512]u8 = undefined;
    @memset(&header, 0);
    const name_len = @min(name.len, 100);
    @memcpy(header[0..name_len], name[0..name_len]);
    @memcpy(header[100..107], "0000644");
    header[107] = 0;
    @memcpy(header[108..115], "0000000");
    header[115] = 0;
    @memcpy(header[116..123], "0000000");
    header[123] = 0;
    var size_buf: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&size_buf, "{o:0>11}", .{size}) catch {};
    @memcpy(header[124..135], size_buf[0..11]);
    header[135] = 0;
    @memcpy(header[136..147], "00000000000");
    header[147] = 0;
    @memset(header[148..156], ' ');
    header[156] = '0';
    @memcpy(header[257..262], "ustar");
    header[262] = 0;
    @memcpy(header[263..265], "00");
    var checksum: u32 = 0;
    for (header) |b| checksum += b;
    var chk_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&chk_buf, "{o:0>6}", .{checksum}) catch {};
    @memcpy(header[148..154], chk_buf[0..6]);
    header[154] = 0;
    header[155] = ' ';
    try writer.writeAll(&header);
}

fn writeTarEntries(entries: []const TarEntry) !void {
    const stdout = std.fs.File.stdout();
    for (entries) |entry| {
        try writeTarHeader(stdout, entry.name, entry.data.len);
        try stdout.writeAll(entry.data);
        const pad = (512 - (entry.data.len % 512)) % 512;
        if (pad != 0) {
            var zeros: [512]u8 = .{0} ** 512;
            try stdout.writeAll(zeros[0..pad]);
        }
    }
    var trailer: [1024]u8 = .{0} ** 1024;
    try stdout.writeAll(&trailer);
}

fn buildTarEntries(allocator: std.mem.Allocator, cap: *TarCapture) ![]TarEntry {
    var list = std.ArrayList(TarEntry).empty;
    defer list.deinit(allocator);
    var it = cap.map.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, .{ .name = entry.key_ptr.*, .data = entry.value_ptr.data.items });
    }
    std.mem.sort(TarEntry, list.items, {}, struct {
        fn lessThan(_: void, a: TarEntry, b: TarEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const scratch = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try usage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "verify")) {
        const parsed = parseVerifyArgs(args[2..]) catch {
            try usage();
            return;
        };
        try ops.verify(allocator, parsed);
        return;
    }
    if (std.mem.eql(u8, cmd, "recover")) {
        const parse = stripTarFlag(allocator, args[2..]) catch {
            try usage();
            return;
        };
        defer allocator.free(parse.args);
        const parsed = parseRecoverArgs(parse.args) catch {
            try usage();
            return;
        };
        if (parse.tar) {
            try recoverTar(allocator, scratch, parsed);
        } else {
            try ops.recover(allocator, scratch, parsed);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "create")) {
        const parse = stripTarFlag(allocator, args[2..]) catch {
            try usage();
            return;
        };
        defer allocator.free(parse.args);
        const parsed = parseCreateArgs(parse.args) catch {
            try usage();
            return;
        };
        if (parse.tar) {
            try createTar(allocator, parsed);
        } else {
            try ops.create(allocator, parsed);
        }
        return;
    }
    try usage();
}

fn usage() !void {
    try infoFile().writeAll(
        "Usage:\n  par2-cli verify [options] <par2 file> [data files...]\n  par2-cli recover [options] <par2 file> [data files...]\n  par2-cli create [options] <par2 file> <data files...>\n\nVerify/Recover options:\n  -B <path>        Base path used to resolve file names in FileDesc packets\n  -m <MB>          Memory cap (fail if estimated or actual usage exceeds)\n  -v/-q            Increase/decrease verbosity (-q -q is silent)\n  --stdout         Recover to stdout (requires exactly one missing file)\n  --tar            Emit recovered files as a tar stream on stdout\n  -o, --out-dir    Output directory for recovered files\n  --allow-unsafe-paths  Allow absolute/.. paths from FileDesc (unsafe)\n\nCreate options:\n  -s <bytes>       Block size (mutually exclusive with -b)\n  -b <count>       Block count (mutually exclusive with -s)\n  -r <percent>     Redundancy percent (mutually exclusive with -c)\n  -c <count>       Recovery block count (mutually exclusive with -r)\n  -f <index>       First recovery block number (offset volume indices)\n  -u               Uniform recovery file sizes\n  -l               Limit recovery file sizes (based on largest input file)\n  -n <count>       Number of recovery files (max 31; incompatible with -l)\n  -R               Recurse into subdirectories for input paths\n  --tar            Emit main+volumes as a tar stream on stdout\n  --block-size     Long form of -s\n  --block-count    Long form of -b\n  --redundancy-percent  Long form of -r\n  --recovery-blocks     Long form of -c\n  --comment <text> Add comment packet(s) (ASCII + Unicode if transliterable)\n  --mute-defaults  Suppress derived plan output (also PAR2_MUTE_DEFAULTS=1)\n  --include-input-slices  Emit FileSlic packets in main PAR2\n  --emit-packed    Emit PkdMain/PkdRecvS packets\n  --no-rfsc        Skip RFSC packets\n  --no-volume-meta Do not duplicate Main/FileDesc/IFSC/Creator in volumes\n\nNotes:\n  verify/recover match input files by exact path when possible, then by basename.\n  If basenames are ambiguous, verification/recovery fails unless exact paths are used.\n\npar2cmdline-turbo compatible options (subset):\n  -b<n> (block count)  -s<n> (block size)  -r<n> (redundancy %% )  -c<n> (recovery blocks)\n  -f<n> (first recovery block)  -u (uniform)  -l (limit)  -n<n> (recovery files)\n  -R (recurse)  -B<path> (basepath)  -m<n> (memory MB)  -v/-q (verbosity)\n",
    );
}

const CreateArgs = ops.CreateOptions;
const RecoverArgs = ops.RecoverOptions;
const VerifyArgs = ops.VerifyOptions;

const StripResult = struct {
    args: []const []const u8,
    tar: bool,
};

fn stripTarFlag(allocator: std.mem.Allocator, args: []const []const u8) !StripResult {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);
    var tar = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--tar")) {
            tar = true;
            continue;
        }
        try out.append(allocator, a);
    }
    return .{ .args = try out.toOwnedSlice(allocator), .tar = tar };
}

fn parseCreateArgs(args: []const []const u8) !CreateArgs {
    var block_size: ?u64 = null;
    var block_count: ?u64 = null;
    var redundancy_percent: ?u64 = null;
    var recovery_blocks: ?u64 = null;
    var first_recovery_block: ?u64 = null;
    var uniform_recovery = false;
    var limit_recovery = false;
    var recovery_file_count: ?u64 = null;
    var mute_defaults = false;
    var comment: ?[]const u8 = null;
    var include_input_slices = false;
    var emit_packed = false;
    var emit_rfsc = true;
    var include_volume_meta = true;
    var basepath: ?[]const u8 = null;
    var verbosity: i32 = 0;
    var memory_mb: ?u64 = null;
    var recurse = false;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-v")) {
            verbosity += 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-q")) {
            verbosity -= 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-R")) {
            recurse = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-m")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
            memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            basepath = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
            basepath = a[2..];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--mute-defaults")) {
            mute_defaults = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--comment")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            comment = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--include-input-slices")) {
            include_input_slices = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--emit-packed")) {
            emit_packed = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-rfsc")) {
            emit_rfsc = false;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-volume-meta")) {
            include_volume_meta = false;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--block-size")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            block_size = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "-s")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            block_size = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-s") and a.len > 2) {
            block_size = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--block-count")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            block_count = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "-b")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            block_count = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-b") and a.len > 2) {
            block_count = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--redundancy-percent")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            redundancy_percent = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "-r")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            redundancy_percent = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-r") and a.len > 2) {
            redundancy_percent = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--recovery-blocks")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            recovery_blocks = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "-c")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            recovery_blocks = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-c") and a.len > 2) {
            recovery_blocks = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-f")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            first_recovery_block = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-f") and a.len > 2) {
            first_recovery_block = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-u")) {
            uniform_recovery = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-l")) {
            limit_recovery = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-n")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            recovery_file_count = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-n") and a.len > 2) {
            recovery_file_count = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        break;
    }
    if (block_size != null and block_count != null) return error.InvalidInput;
    if (redundancy_percent != null and recovery_blocks != null) return error.InvalidInput;
    if (uniform_recovery and limit_recovery) return error.InvalidInput;
    if (limit_recovery and recovery_file_count != null) return error.InvalidInput;
    if (recovery_file_count) |count| {
        if (count == 0 or count > 31) return error.InvalidInput;
    }
    if (i >= args.len) return error.InvalidInput;
    const par2_path = args[i];
    const data_paths = args[i + 1 ..];
    if (data_paths.len == 0) return error.InvalidInput;
    if (redundancy_percent == null and recovery_blocks == null) {
        redundancy_percent = 5;
    }
    return .{
        .block_size = block_size,
        .block_count = block_count,
        .redundancy_percent = redundancy_percent,
        .recovery_blocks = recovery_blocks,
        .first_recovery_block = first_recovery_block,
        .uniform_recovery = uniform_recovery,
        .limit_recovery = limit_recovery,
        .recovery_file_count = recovery_file_count,
        .par2_path = par2_path,
        .data_paths = data_paths,
        .mute_defaults = mute_defaults,
        .comment = comment,
        .include_input_slices = include_input_slices,
        .emit_packed = emit_packed,
        .emit_rfsc = emit_rfsc,
        .include_volume_meta = include_volume_meta,
        .basepath = basepath,
        .verbosity = verbosity,
        .memory_mb = memory_mb,
        .recurse = recurse,
        .thread_count = null,
        .output_open = null,
    };
}

fn parseRecoverArgs(args: []const []const u8) !RecoverArgs {
    var stdout_only = false;
    var out_dir: ?[]const u8 = null;
    var allow_unsafe_paths = false;
    var basepath: ?[]const u8 = null;
    var verbosity: i32 = 0;
    var memory_mb: ?u64 = null;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "--stdout")) {
            stdout_only = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--allow-unsafe-paths")) {
            allow_unsafe_paths = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out-dir")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            out_dir = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "-v")) {
            verbosity += 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-q")) {
            verbosity -= 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-R")) return error.InvalidInput;
        if (std.mem.eql(u8, a, "-m")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
            memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            basepath = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
            basepath = a[2..];
            i += 1;
            continue;
        }
        break;
    }
    if (stdout_only and out_dir != null) return error.InvalidInput;
    if (i >= args.len) return error.InvalidInput;
    const par2_path = args[i];
    const data_paths = args[i + 1 ..];
    return .{
        .stdout_only = stdout_only,
        .out_dir = out_dir,
        .par2_path = par2_path,
        .data_paths = data_paths,
        .allow_unsafe_paths = allow_unsafe_paths,
        .basepath = basepath,
        .verbosity = verbosity,
        .memory_mb = memory_mb,
        .output_open = null,
    };
}

fn createTar(allocator: std.mem.Allocator, opts: CreateArgs) !void {
    var cap = tarCaptureInit(allocator);
    defer tarCaptureDeinit(&cap);
    var local = opts;
    local.output_open = .{ .ctx = &cap, .openFn = tarOpen };
    local.thread_count = 1;
    local.verbosity = -1;
    try ops.create(allocator, local);
    const entries = try buildTarEntries(allocator, &cap);
    defer allocator.free(entries);
    try writeTarEntries(entries);
}

fn recoverTar(allocator: std.mem.Allocator, scratch: std.mem.Allocator, opts: RecoverArgs) !void {
    var cap = tarCaptureInit(allocator);
    defer tarCaptureDeinit(&cap);
    var local = opts;
    local.output_open = .{ .ctx = &cap, .openFn = tarOpen };
    local.verbosity = -1;
    try ops.recover(allocator, scratch, local);
    const entries = try buildTarEntries(allocator, &cap);
    defer allocator.free(entries);
    try writeTarEntries(entries);
}

fn parseVerifyArgs(args: []const []const u8) !VerifyArgs {
    var basepath: ?[]const u8 = null;
    var verbosity: i32 = 0;
    var memory_mb: ?u64 = null;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-v")) {
            verbosity += 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-q")) {
            verbosity -= 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-R")) return error.InvalidInput;
        if (std.mem.eql(u8, a, "-m")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            memory_mb = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-m") and a.len > 2) {
            memory_mb = try std.fmt.parseInt(u64, a[2..], 10);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "--basepath")) {
            if (i + 1 >= args.len) return error.InvalidInput;
            basepath = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-B") and a.len > 2) {
            basepath = a[2..];
            i += 1;
            continue;
        }
        break;
    }
    if (i >= args.len) return error.InvalidInput;
    const par2_path = args[i];
    const data_paths = args[i + 1 ..];
    return .{
        .par2_path = par2_path,
        .data_paths = data_paths,
        .basepath = basepath,
        .verbosity = verbosity,
        .memory_mb = memory_mb,
    };
}

// Tests (parsing only; core logic lives in ops.zig)

test "parseCreateArgs rejects both block size and block count" {
    try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{
        "--block-size",
        "4096",
        "--block-count",
        "10",
        "out.par2",
        "file.bin",
    }));
}

test "parseCreateArgs rejects both redundancy percent and recovery blocks" {
    try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{
        "--redundancy-percent",
        "10",
        "--recovery-blocks",
        "5",
        "out.par2",
        "file.bin",
    }));
}

test "parseCreateArgs requires data files" {
    try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{"out.par2"}));
}

test "parseCreateArgs parses flags and paths" {
    const parsed = try parseCreateArgs(&.{
        "--block-size",
        "4096",
        "--redundancy-percent",
        "10",
        "out.par2",
        "file.bin",
        "file2.bin",
    });
    try std.testing.expectEqual(@as(u64, 4096), parsed.block_size.?);
    try std.testing.expectEqual(@as(u64, 10), parsed.redundancy_percent.?);
    try std.testing.expectEqualStrings("out.par2", parsed.par2_path);
    try std.testing.expectEqual(@as(usize, 2), parsed.data_paths.len);
    try std.testing.expect(parsed.include_volume_meta);
}

test "parseCreateArgs defaults redundancy percent" {
    const parsed = try parseCreateArgs(&.{ "out.par2", "file.bin" });
    try std.testing.expectEqual(@as(u64, 5), parsed.redundancy_percent.?);
}

test "parseCreateArgs accepts mute defaults" {
    const parsed = try parseCreateArgs(&.{ "--mute-defaults", "out.par2", "file.bin" });
    try std.testing.expect(parsed.mute_defaults);
}

test "parseCreateArgs accepts comment" {
    const parsed = try parseCreateArgs(&.{ "--comment", "hello", "out.par2", "file.bin" });
    try std.testing.expectEqualStrings("hello", parsed.comment.?);
}

test "parseCreateArgs accepts include input slices" {
    const parsed = try parseCreateArgs(&.{ "--include-input-slices", "out.par2", "file.bin" });
    try std.testing.expect(parsed.include_input_slices);
}

test "parseCreateArgs accepts emit packed" {
    const parsed = try parseCreateArgs(&.{ "--emit-packed", "out.par2", "file.bin" });
    try std.testing.expect(parsed.emit_packed);
}

test "parseCreateArgs accepts no rfsc" {
    const parsed = try parseCreateArgs(&.{ "--no-rfsc", "out.par2", "file.bin" });
    try std.testing.expect(!parsed.emit_rfsc);
}

test "parseCreateArgs accepts no volume meta" {
    const parsed = try parseCreateArgs(&.{ "--no-volume-meta", "out.par2", "file.bin" });
    try std.testing.expect(!parsed.include_volume_meta);
}

test "parseCreateArgs accepts par2-style short flags" {
    const parsed = try parseCreateArgs(&.{ "-s4096", "-r10", "out.par2", "file.bin" });
    try std.testing.expectEqual(@as(u64, 4096), parsed.block_size.?);
    try std.testing.expectEqual(@as(u64, 10), parsed.redundancy_percent.?);
}

test "parseCreateArgs parses basepath, memory, and verbosity" {
    const parsed = try parseCreateArgs(&.{ "-v", "-q", "-m", "64", "-B", "base", "out.par2", "file.bin" });
    try std.testing.expectEqual(@as(i32, 0), parsed.verbosity);
    try std.testing.expectEqual(@as(u64, 64), parsed.memory_mb.?);
    try std.testing.expectEqualStrings("base", parsed.basepath.?);
}

test "parseCreateArgs accepts recovery split flags" {
    const parsed = try parseCreateArgs(&.{ "-u", "-n3", "-f5", "out.par2", "file.bin" });
    try std.testing.expect(parsed.uniform_recovery);
    try std.testing.expectEqual(@as(u64, 3), parsed.recovery_file_count.?);
    try std.testing.expectEqual(@as(u64, 5), parsed.first_recovery_block.?);
}

test "parseCreateArgs accepts limit recovery" {
    const parsed = try parseCreateArgs(&.{ "-l", "out.par2", "file.bin" });
    try std.testing.expect(parsed.limit_recovery);
}

test "parseCreateArgs rejects uniform and limit" {
    try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{ "-u", "-l", "out.par2", "file.bin" }));
}

test "parseCreateArgs rejects limit and recovery file count" {
    try std.testing.expectError(error.InvalidInput, parseCreateArgs(&.{ "-l", "-n3", "out.par2", "file.bin" }));
}

test "parseRecoverArgs accepts basepath, memory, and verbosity" {
    const parsed = try parseRecoverArgs(&.{ "-v", "-q", "-m", "32", "-B", "base", "file.par2" });
    try std.testing.expectEqual(@as(i32, 0), parsed.verbosity);
    try std.testing.expectEqual(@as(u64, 32), parsed.memory_mb.?);
    try std.testing.expectEqualStrings("base", parsed.basepath.?);
}

test "parseRecoverArgs rejects -R" {
    try std.testing.expectError(error.InvalidInput, parseRecoverArgs(&.{ "-R", "file.par2" }));
}

test "parseVerifyArgs parses basepath and memory" {
    const parsed = try parseVerifyArgs(&.{ "-m", "64", "-B", "base", "file.par2" });
    try std.testing.expectEqual(@as(u64, 64), parsed.memory_mb.?);
    try std.testing.expectEqualStrings("base", parsed.basepath.?);
}
