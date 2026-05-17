const std = @import("std");
const core = @import("core");
const path_util = @import("path.zig");

pub const CreateOptions = struct {
    block_size: ?u64,
    block_count: ?u64,
    redundancy_percent: ?u64,
    recovery_blocks: ?u64,
    first_recovery_block: ?u64,
    uniform_recovery: bool,
    limit_recovery: bool,
    recovery_file_count: ?u64,
    par2_path: []const u8,
    data_paths: []const []const u8,
    mute_defaults: bool,
    comment: ?[]const u8,
    metadata: ?core.packet_types.SourceMetadataPacket,
    validation_state: ?core.packet_types.ValidationStatePacket,
    aapl_packet: ?core.packet_types.AaplPacket,
    include_input_slices: bool,
    emit_packed: bool,
    emit_rfsc: bool,
    include_volume_meta: bool,
    basepath: ?[]const u8,
    verbosity: i32,
    memory_mb: ?u64,
    recurse: bool,
    thread_count: ?u32,
    output_open: ?OutputOpener,
    /// Hash algorithm for IFSC/RFSC per-slice strong hashes. Default `.md5`
    /// produces strict-PAR2-spec archives. `.blake3_128` opts into Mecha
    /// mode: a MECHCFG packet is written declaring the algorithm; per-slice
    /// strong hashes become BLAKE3-128 (16 bytes, same on-wire size as MD5).
    /// All other hashes (file_id, recovery_set_id, packet self-hash, file
    /// full-content hash) stay MD5.
    hash_algo: core.hash_algo.HashAlgo = .md5,
};

pub const RecoverOptions = struct {
    stdout_only: bool,
    out_dir: ?[]const u8,
    par2_path: []const u8,
    data_paths: []const []const u8,
    allow_unsafe_paths: bool,
    basepath: ?[]const u8,
    verbosity: i32,
    memory_mb: ?u64,
    thread_count: ?u32 = null,
    output_open: ?OutputOpener,
};

pub const VerifyOptions = struct {
    par2_path: []const u8,
    data_paths: []const []const u8,
    basepath: ?[]const u8,
    verbosity: i32,
    memory_mb: ?u64,
};

pub const OutputTarget = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!usize,
    closeFn: *const fn (ctx: *anyopaque) void,

    pub fn writeAll(self: *OutputTarget, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const written = try self.writeFn(self.ctx, data[offset..]);
            if (written == 0) return error.IoError;
            offset += written;
        }
    }

    pub fn close(self: *OutputTarget) void {
        self.closeFn(self.ctx);
    }
};

pub const OutputOpener = struct {
    ctx: *anyopaque,
    openFn: *const fn (ctx: *anyopaque, path: []const u8) anyerror!OutputTarget,
};

pub const StreamInput = struct {
    name: []const u8,
    length: u64,
    read_at: core.storage.StreamReadAt,
    ctx: *anyopaque,
};

pub fn stdoutToStderrEnabled() bool {
    return envFlagSet("STDOUT_TO_STDERR");
}

pub fn infoFile() std.Io.File {
    // NOTE: Kept for future use. Originally added to work around Zig test runner
    // hangs when tests write to stdout. If removing, update infoFile() uses below
    // and src/cli.zig (usage output) plus README mention of STDOUT_TO_STDERR.
    return if (stdoutToStderrEnabled()) std.Io.File.stderr() else std.Io.File.stdout();
}

const FileOutput = struct {
    file: std.Io.File,
    allocator: std.mem.Allocator,
};

fn fileWrite(ctx: *anyopaque, data: []const u8) anyerror!usize {
    const out: *FileOutput = @ptrCast(@alignCast(ctx));
    // 0.16: there is no direct `write(slice) -> usize`; writeStreaming takes a slice-of-slices and splat.
    return out.file.writeStreaming(core.io_singleton.getOrInit(), &.{}, &.{data}, 1);
}

fn fileClose(ctx: *anyopaque) void {
    const out: *FileOutput = @ptrCast(@alignCast(ctx));
    out.file.close(core.io_singleton.getOrInit());
    out.allocator.destroy(out);
}

pub fn openFileOutput(allocator: std.mem.Allocator, path: []const u8) !OutputTarget {
    const file = try std.Io.Dir.cwd().createFile(core.io_singleton.getOrInit(), path, .{ .truncate = true });
    const out = try allocator.create(FileOutput);
    out.* = .{ .file = file, .allocator = allocator };
    return .{ .ctx = out, .writeFn = fileWrite, .closeFn = fileClose };
}

/// Wrap a (caller-owned) std.Io.File as an OutputTarget — used by recover paths
/// to give File and OutputTarget callers a single `writer.writeAll(...)` shape.
pub const FileOutputTarget = struct {
    file: std.Io.File,

    pub fn writeAll(self: *FileOutputTarget, data: []const u8) !void {
        return self.file.writeStreamingAll(core.io_singleton.getOrInit(), data);
    }
};

pub fn wrapFileWriter(file: std.Io.File) FileOutputTarget {
    return .{ .file = file };
}

pub fn openOutput(allocator: std.mem.Allocator, path: []const u8, opener: ?OutputOpener) !OutputTarget {
    if (opener) |o| {
        return o.openFn(o.ctx, path);
    }
    return openFileOutput(allocator, path);
}

pub fn envMuteDefaults() bool {
    const val = core.io_singleton.getEnvVarOwned(std.heap.page_allocator, "PAR2_MUTE_DEFAULTS") catch return false;
    defer std.heap.page_allocator.free(val);
    if (val.len == 0) return false;
    if (std.mem.eql(u8, val, "0")) return false;
    if (std.mem.eql(u8, val, "false")) return false;
    return true;
}

pub fn envFlagSet(name: []const u8) bool {
    const val = core.io_singleton.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(val);
    if (val.len == 0) return false;
    if (std.mem.eql(u8, val, "0")) return false;
    if (std.mem.eql(u8, val, "false")) return false;
    return true;
}

pub fn memoryCapBytes(memory_mb: ?u64) !?u64 {
    if (memory_mb == null) return null;
    const mb = memory_mb.?;
    const mul = @mulWithOverflow(mb, @as(u64, 1024 * 1024));
    if (mul[1] != 0) return error.InvalidInput;
    return mul[0];
}

pub const LimitedAllocator = struct {
    child: std.mem.Allocator,
    cap: usize,
    used: usize,

    pub fn init(child: std.mem.Allocator, cap: usize) LimitedAllocator {
        return .{ .child = child, .cap = cap, .used = 0 };
    }

    pub fn allocator(self: *LimitedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        const new_used = self.used + len;
        if (new_used > self.cap) return null;
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.used = new_used;
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= buf.len) {
            const ok = self.child.rawResize(buf, alignment, new_len, ret_addr);
            if (!ok) return false;
            self.used -= buf.len - new_len;
            return true;
        }
        const add = new_len - buf.len;
        if (self.used + add > self.cap) return false;
        const ok = self.child.rawResize(buf, alignment, new_len, ret_addr);
        if (!ok) return false;
        self.used += add;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= buf.len) {
            if (self.child.rawResize(buf, alignment, new_len, ret_addr)) {
                self.used -= buf.len - new_len;
                return buf.ptr;
            }
            const ptr = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
            self.used -= buf.len - new_len;
            return ptr;
        }
        const add = new_len - buf.len;
        if (self.used + add > self.cap) return null;
        const ptr = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.used += add;
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ret_addr);
        if (self.used >= buf.len) {
            self.used -= buf.len;
        } else {
            self.used = 0;
        }
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

pub fn trimTrailingSeparators(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1) : (end -= 1) {
        const c = path[end - 1];
        if (c != '/' and c != '\\') break;
    }
    return path[0..end];
}

pub fn isPathPrefix(base: []const u8, full: []const u8) bool {
    if (!std.mem.startsWith(u8, full, base)) return false;
    if (full.len == base.len) return true;
    const next = full[base.len];
    return next == '/' or next == '\\';
}

pub fn relativePathForInput(allocator: std.mem.Allocator, basepath: []const u8, path: []const u8) !?[]const u8 {
    const base_abs = try std.Io.Dir.cwd().realPathFileAlloc(core.io_singleton.getOrInit(), basepath, allocator);
    defer allocator.free(base_abs);
    const base_norm = trimTrailingSeparators(base_abs);
    const path_abs = try std.Io.Dir.cwd().realPathFileAlloc(core.io_singleton.getOrInit(), path, allocator);
    defer allocator.free(path_abs);
    return relativePathUnderBase(allocator, base_norm, path_abs);
}

pub fn relativePathUnderBase(allocator: std.mem.Allocator, base_abs: []const u8, file_abs: []const u8) !?[]const u8 {
    if (!isPathPrefix(base_abs, file_abs)) return null;
    var start = base_abs.len;
    if (file_abs.len > base_abs.len) {
        const c = file_abs[start];
        if (c == '/' or c == '\\') start += 1;
    }
    if (start >= file_abs.len) return null;
    const rel = file_abs[start..];
    if (hasTraversalSegment(rel)) return null;
    if (hasWindowsDrivePrefix(rel)) return null;
    if (std.fs.path.isAbsolute(rel)) return null;
    const out = try allocator.dupe(u8, rel);
    return out;
}

pub fn safeFileName(path: []const u8) ![]const u8 {
    if (hasTraversalSegment(path)) return error.InvalidInput;
    if (std.fs.path.isAbsolute(path)) {
        return path_util.baseName(path);
    }
    // Reject relative paths with drive prefix (e.g. "C:foo") — these are
    // Windows-specific relative paths that could escape the current directory.
    if (hasWindowsDrivePrefix(path)) return error.InvalidInput;
    return path;
}

pub const NormalizedPath = struct {
    path: []const u8,
    owned: bool,
};

pub fn normalizeRelativePath(allocator: std.mem.Allocator, path: []const u8) !NormalizedPath {
    if (std.fs.path.isAbsolute(path)) return error.InvalidInput;
    if (hasWindowsDrivePrefix(path)) return error.InvalidInput;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var changed = false;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/' or path[i] == '\\') {
            const seg = path[seg_start..i];
            if (seg.len == 0 or (seg.len == 1 and seg[0] == '.')) {
                if (seg.len != 0 or (i < path.len and (path[i] == '/' or path[i] == '\\'))) {
                    changed = true;
                }
            } else if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') {
                return error.InvalidInput;
            } else {
                if (out.items.len != 0) {
                    try out.append(allocator, '/');
                }
                try out.appendSlice(allocator, seg);
                if (i < path.len and path[i] == '\\') changed = true;
            }
            seg_start = i + 1;
        }
    }
    if (out.items.len == 0) return error.InvalidInput;
    if (!changed) return .{ .path = path, .owned = false };
    return .{ .path = try out.toOwnedSlice(allocator), .owned = true };
}

pub fn hasTraversalSegment(path: []const u8) bool {
    if (path.len == 0) return false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/' or path[i] == '\\') {
            const seg = path[start..i];
            if (seg.len == 2 and seg[0] == '.' and seg[1] == '.') return true;
            start = i + 1;
        }
    }
    return false;
}

pub fn ensureDirForPath(path: []const u8) !void {
    const dir = path_util.dirNameOrDot(path);
    if (dir.len > 0) {
        try std.Io.Dir.cwd().createDirPath(core.io_singleton.getOrInit(), dir);
    }
}

pub fn hasWindowsDrivePrefix(path: []const u8) bool {
    if (path.len < 2) return false;
    const c = path[0];
    if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) return false;
    if (path[1] != ':') return false;
    return true;
}

pub fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

pub fn transliterateAscii(allocator: std.mem.Allocator, utf8: []const u8) !?[]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    var changed = false;
    while (i < utf8.len) {
        const b = utf8[i];
        if (b < 0x80) {
            try out.append(allocator, b);
            i += 1;
            continue;
        }
        const r = try mapLatin1(allocator, utf8[i..]);
        if (r == null) return null;
        try out.appendSlice(allocator, r.?.bytes);
        allocator.free(r.?.bytes);
        i += r.?.len;
        changed = true;
    }
    if (!changed) return null;
    return try out.toOwnedSlice(allocator);
}

const MapResult = struct {
    bytes: []const u8,
    len: usize,
};

fn mapLatin1(allocator: std.mem.Allocator, s: []const u8) !?MapResult {
    if (s.len < 2) return null;
    const first = s[0];
    const second = s[1];
    if (first == 0xC3) {
        switch (second) {
            0xA1, 0xA0, 0xA4, 0xA2, 0xA3, 0xA5 => return asciiMap(allocator, "a?"),
            0x81, 0x80, 0x84, 0x82, 0x83, 0x85 => return asciiMap(allocator, "A?"),
            0xA9, 0xA8, 0xAB, 0xAA => return asciiMap(allocator, "e?"),
            0x89, 0x88, 0x8B, 0x8A => return asciiMap(allocator, "E?"),
            0xAD, 0xAC, 0xAF, 0xAE => return asciiMap(allocator, "i?"),
            0x8D, 0x8C, 0x8F, 0x8E => return asciiMap(allocator, "I?"),
            0xB3, 0xB2, 0xB6, 0xB4, 0xB5 => return asciiMap(allocator, "o?"),
            0x93, 0x92, 0x96, 0x94, 0x95 => return asciiMap(allocator, "O?"),
            0xBA, 0xB9, 0xBC, 0xBB => return asciiMap(allocator, "u?"),
            0x9A, 0x99, 0x9C, 0x9B => return asciiMap(allocator, "U?"),
            0xB1 => return asciiMap(allocator, "n?"),
            0x91 => return asciiMap(allocator, "N?"),
            0xA7 => return asciiMap(allocator, "c?"),
            0x87 => return asciiMap(allocator, "C?"),
            0x9F => return asciiMap(allocator, "ss?"),
            0xA6 => return asciiMap(allocator, "ae?"),
            0x86 => return asciiMap(allocator, "AE?"),
            0xB8 => return asciiMap(allocator, "o?"),
            0x98 => return asciiMap(allocator, "O?"),
            else => return null,
        }
    }
    return null;
}

fn asciiMap(allocator: std.mem.Allocator, text: []const u8) !?MapResult {
    const bytes = try allocator.dupe(u8, text);
    return .{ .bytes = bytes, .len = 2 };
}

pub fn md5First16k(path: []const u8) ![16]u8 {
    const io = core.io_singleton.getOrInit();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [16384]u8 = undefined;
    // 0.16: positional read of up to 16k bytes; may return short read at EOF.
    const n = try file.readPositionalAll(io, &buf, 0);
    var out: [16]u8 = undefined;
    try core.md5.md5Digest(buf[0..n], &out);
    return out;
}

pub fn md5File(path: []const u8) ![16]u8 {
    const io = core.io_singleton.getOrInit();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var ctx = core.md5.Md5Ctx.init(.{});
    // 0.16: read via positional reads to avoid Reader/Writer interface threading.
    var buf: [32768]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        ctx.update(buf[0..n]);
        offset += n;
        if (n < buf.len) break;
    }
    var out: [16]u8 = undefined;
    ctx.final(&out);
    return out;
}

pub fn readAtExact(read_at: core.storage.StreamReadAt, ctx: *anyopaque, offset: u64, out: []u8) !void {
    var have: usize = 0;
    while (have < out.len) {
        const n = read_at(ctx, offset + @as(u64, @intCast(have)), out[have..]);
        if (n == 0) return error.InvalidInput;
        have += n;
        if (have > out.len) return error.InvalidInput;
    }
}

pub fn md5First16kStream(input: StreamInput) ![16]u8 {
    var buf: [16384]u8 = undefined;
    const want = @min(@as(u64, 16384), input.length);
    if (want > 0) {
        try readAtExact(input.read_at, input.ctx, 0, buf[0..@as(usize, @intCast(want))]);
    }
    var out: [16]u8 = undefined;
    try core.md5.md5Digest(buf[0..@as(usize, @intCast(want))], &out);
    return out;
}

pub fn md5Stream(input: StreamInput) ![16]u8 {
    var ctx = core.md5.Md5Ctx.init(.{});
    var buf: [32768]u8 = undefined;
    var offset: u64 = 0;
    while (offset < input.length) {
        const remaining = input.length - offset;
        const chunk_len = @min(remaining, @as(u64, buf.len));
        try readAtExact(input.read_at, input.ctx, offset, buf[0..@as(usize, @intCast(chunk_len))]);
        ctx.update(buf[0..@as(usize, @intCast(chunk_len))]);
        offset += chunk_len;
    }
    var out: [16]u8 = undefined;
    ctx.final(&out);
    return out;
}

pub var missing_ctx: u8 = 0;

pub fn missingReadAt(_: *anyopaque, _: u64, _: []u8) usize {
    return 0;
}

fn isRecvSlicType(t: [16]u8) bool {
    const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
    return std.mem.eql(u8, &t, &recvslic);
}

fn isPackedRecvSlicType(t: [16]u8) bool {
    const recvslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'P', 'k', 'd', 'R', 'e', 'c', 'v', 'S' };
    return std.mem.eql(u8, &t, &recvslic);
}

fn isFileSlicType(t: [16]u8) bool {
    const fileslic = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'S', 'l', 'i', 'c' };
    return std.mem.eql(u8, &t, &fileslic);
}

fn isRfscType(t: [16]u8) bool {
    const rfsc = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
    return std.mem.eql(u8, &t, &rfsc);
}

pub fn loadPar2File(
    allocator: std.mem.Allocator,
    ctx: *core.api.Par2Context,
    recs: *std.ArrayList(core.rs.RecoverySlice),
    packed_recs: *std.ArrayList(core.rs.RecoverySlice),
    file_slices: *std.ArrayList(core.packet_types.FileSlicPacket),
    rfsc_packets: *std.ArrayList(core.packet_types.RfscPacket),
    path: []const u8,
    expected_id: *?[16]u8,
) !void {
    var local_recs = std.ArrayList(core.rs.RecoverySlice).empty;
    defer local_recs.deinit(allocator);
    var local_packed = std.ArrayList(core.rs.RecoverySlice).empty;
    defer local_packed.deinit(allocator);
    var local_rfsc = std.ArrayList(core.packet_types.RfscEntry).empty;
    defer local_rfsc.deinit(allocator);
    const par2_bytes = try std.Io.Dir.cwd().readFileAlloc(core.io_singleton.getOrInit(), path, allocator, .unlimited);
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            continue;
        };
        if (expected_id.*) |value| {
            if (!std.mem.eql(u8, &value, &hdr.recovery_set_id)) {
                offset += end - 1;
                continue;
            }
        } else {
            expected_id.* = hdr.recovery_set_id;
        }
        try core.api.addPacket(allocator, ctx, pkt);
        if (isRecvSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseRecvSlic(pkt);
            try local_recs.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
            offset += end - 1;
            continue;
        }
        if (isPackedRecvSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parsePackedRecvSlic(pkt);
            try local_packed.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
            offset += end - 1;
            continue;
        }
        if (isFileSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseFileSlic(pkt);
            try file_slices.append(allocator, parsed);
            offset += end - 1;
            continue;
        }
        if (isRfscType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseRfsc(pkt, allocator);
            try rfsc_packets.append(allocator, parsed);
            for (parsed.entries) |entry| {
                try local_rfsc.append(allocator, entry);
            }
            offset += end - 1;
            continue;
        }
        offset += end - 1;
    }
    if (local_rfsc.items.len == 0) {
        try recs.appendSlice(allocator, local_recs.items);
        try packed_recs.appendSlice(allocator, local_packed.items);
        return;
    }
    var rec_index = std.AutoHashMap(u32, usize).init(allocator);
    defer rec_index.deinit();
    for (local_rfsc.items, 0..) |entry, idx| {
        try rec_index.put(entry.exponent, idx);
    }
    for (local_recs.items) |rec| {
        const idx = rec_index.get(rec.exponent) orelse continue;
        var digest: [16]u8 = undefined;
        core.hash_algo.hashDigest(ctx.hash_algo, rec.data, &digest);
        if (std.mem.eql(u8, &digest, &local_rfsc.items[idx].md5) and local_rfsc.items[idx].crc32 == core.crc32.crc32(rec.data)) {
            try recs.append(allocator, rec);
        }
    }
    for (local_packed.items) |rec| {
        const idx = rec_index.get(rec.exponent) orelse continue;
        var digest: [16]u8 = undefined;
        core.hash_algo.hashDigest(ctx.hash_algo, rec.data, &digest);
        if (std.mem.eql(u8, &digest, &local_rfsc.items[idx].md5) and local_rfsc.items[idx].crc32 == core.crc32.crc32(rec.data)) {
            try packed_recs.append(allocator, rec);
        }
    }
}

pub fn loadPar2Bytes(
    allocator: std.mem.Allocator,
    ctx: *core.api.Par2Context,
    recs: *std.ArrayList(core.rs.RecoverySlice),
    packed_recs: *std.ArrayList(core.rs.RecoverySlice),
    file_slices: *std.ArrayList(core.packet_types.FileSlicPacket),
    rfsc_packets: *std.ArrayList(core.packet_types.RfscPacket),
    par2_bytes: []const u8,
    expected_id: *?[16]u8,
) !void {
    var local_recs = std.ArrayList(core.rs.RecoverySlice).empty;
    defer local_recs.deinit(allocator);
    var local_packed = std.ArrayList(core.rs.RecoverySlice).empty;
    defer local_packed.deinit(allocator);
    var local_rfsc = std.ArrayList(core.packet_types.RfscEntry).empty;
    defer local_rfsc.deinit(allocator);
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            continue;
        };
        if (expected_id.*) |value| {
            if (!std.mem.eql(u8, &value, &hdr.recovery_set_id)) {
                offset += end - 1;
                continue;
            }
        } else {
            expected_id.* = hdr.recovery_set_id;
        }
        try core.api.addPacket(allocator, ctx, pkt);
        if (isRecvSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseRecvSlic(pkt);
            try local_recs.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
            offset += end - 1;
            continue;
        }
        if (isPackedRecvSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parsePackedRecvSlic(pkt);
            try local_packed.append(allocator, .{ .exponent = parsed.exponent, .data = parsed.data });
            offset += end - 1;
            continue;
        }
        if (isFileSlicType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseFileSlic(pkt);
            try file_slices.append(allocator, parsed);
            offset += end - 1;
            continue;
        }
        if (isRfscType(hdr.packet_type)) {
            const parsed = try core.packet_types.parseRfsc(pkt, allocator);
            try rfsc_packets.append(allocator, parsed);
            for (parsed.entries) |entry| {
                try local_rfsc.append(allocator, entry);
            }
            offset += end - 1;
            continue;
        }
        offset += end - 1;
    }
    if (local_rfsc.items.len == 0) {
        try recs.appendSlice(allocator, local_recs.items);
        try packed_recs.appendSlice(allocator, local_packed.items);
        return;
    }
    var rec_index = std.AutoHashMap(u32, usize).init(allocator);
    defer rec_index.deinit();
    for (local_rfsc.items, 0..) |entry, idx| {
        try rec_index.put(entry.exponent, idx);
    }
    for (local_recs.items) |rec| {
        const idx = rec_index.get(rec.exponent) orelse continue;
        var digest: [16]u8 = undefined;
        core.hash_algo.hashDigest(ctx.hash_algo, rec.data, &digest);
        if (std.mem.eql(u8, &digest, &local_rfsc.items[idx].md5) and local_rfsc.items[idx].crc32 == core.crc32.crc32(rec.data)) {
            try recs.append(allocator, rec);
        }
    }
    for (local_packed.items) |rec| {
        const idx = rec_index.get(rec.exponent) orelse continue;
        var digest: [16]u8 = undefined;
        core.hash_algo.hashDigest(ctx.hash_algo, rec.data, &digest);
        if (std.mem.eql(u8, &digest, &local_rfsc.items[idx].md5) and local_rfsc.items[idx].crc32 == core.crc32.crc32(rec.data)) {
            try packed_recs.append(allocator, rec);
        }
    }
}

pub fn loadVolumeFiles(
    allocator: std.mem.Allocator,
    ctx: *core.api.Par2Context,
    recs: *std.ArrayList(core.rs.RecoverySlice),
    packed_recs: *std.ArrayList(core.rs.RecoverySlice),
    file_slices: *std.ArrayList(core.packet_types.FileSlicPacket),
    rfsc_packets: *std.ArrayList(core.packet_types.RfscPacket),
    path: []const u8,
    expected_id: *?[16]u8,
) !void {
    // Detect extension from the input path (works with .par2, .foe, or any extension)
    var base = path;
    var ext: []const u8 = ".par2"; // fallback
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        ext = path[dot..];
        base = path[0..dot];
    }
    if (std.mem.indexOf(u8, base, ".vol")) |idx| {
        base = base[0..idx];
    }
    const base_name = path_util.baseName(base);
    var dir = try std.Io.Dir.cwd().openDir(core.io_singleton.getOrInit(), path_util.dirNameOrDot(path), .{ .iterate = true });
    defer dir.close(core.io_singleton.getOrInit());
    var it = dir.iterate();
    while (try it.next(core.io_singleton.getOrInit())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        if (std.mem.indexOf(u8, entry.name, ".vol") == null) continue;
        const full = try path_util.join(allocator, path_util.dirNameOrDot(path), entry.name);
        if (std.mem.eql(u8, full, path)) {
            allocator.free(full);
            continue;
        }
        if (!std.mem.startsWith(u8, entry.name, base_name)) {
            allocator.free(full);
            continue;
        }
        try loadPar2File(allocator, ctx, recs, packed_recs, file_slices, rfsc_packets, full, expected_id);
        allocator.free(full);
    }
}

pub fn findRecoveryIndexByName(set: core.recovery_set.RecoverySet, path: []const u8, base: []const u8, rel: ?[]const u8) !usize {
    var exact_match: ?usize = null;
    var i: usize = 0;
    while (i < set.recovery_files.len) : (i += 1) {
        const entry = set.recovery_files[i];
        if (entry.desc == null) continue;
        const name = entry.desc.?.file_name;
        if (std.mem.eql(u8, name, path) or (rel != null and std.mem.eql(u8, name, rel.?))) {
            if (exact_match != null and exact_match.? != i) return error.InvalidInput;
            exact_match = i;
        }
    }
    if (exact_match != null) return exact_match.?;

    var base_match: ?usize = null;
    i = 0;
    while (i < set.recovery_files.len) : (i += 1) {
        const entry = set.recovery_files[i];
        if (entry.desc == null) continue;
        const name = entry.desc.?.file_name;
        if (std.mem.eql(u8, name, base)) {
            if (base_match != null and base_match.? != i) return error.InvalidInput;
            base_match = i;
            continue;
        }
        const entry_base = path_util.baseName(name);
        if (std.mem.eql(u8, entry_base, base)) {
            if (base_match != null and base_match.? != i) return error.InvalidInput;
            base_match = i;
        }
    }
    if (base_match == null) return error.NotFound;
    return base_match.?;
}

test "transliterateAscii maps latin1 accents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try transliterateAscii(arena.allocator(), "hé");
    try std.testing.expectEqualStrings("he?", out.?);
}

test "transliterateAscii returns null on unmapped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try transliterateAscii(arena.allocator(), "€");
    try std.testing.expect(out == null);
}

test "transliterateAscii covers all latin1 mappings" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "á", .out = "a?" },  .{ .in = "à", .out = "a?" }, .{ .in = "ä", .out = "a?" },  .{ .in = "â", .out = "a?" },
        .{ .in = "ã", .out = "a?" },  .{ .in = "å", .out = "a?" }, .{ .in = "Á", .out = "A?" },  .{ .in = "À", .out = "A?" },
        .{ .in = "Ä", .out = "A?" },  .{ .in = "Â", .out = "A?" }, .{ .in = "Ã", .out = "A?" },  .{ .in = "Å", .out = "A?" },
        .{ .in = "é", .out = "e?" },  .{ .in = "è", .out = "e?" }, .{ .in = "ë", .out = "e?" },  .{ .in = "ê", .out = "e?" },
        .{ .in = "É", .out = "E?" },  .{ .in = "È", .out = "E?" }, .{ .in = "Ë", .out = "E?" },  .{ .in = "Ê", .out = "E?" },
        .{ .in = "í", .out = "i?" },  .{ .in = "ì", .out = "i?" }, .{ .in = "ï", .out = "i?" },  .{ .in = "î", .out = "i?" },
        .{ .in = "Í", .out = "I?" },  .{ .in = "Ì", .out = "I?" }, .{ .in = "Ï", .out = "I?" },  .{ .in = "Î", .out = "I?" },
        .{ .in = "ó", .out = "o?" },  .{ .in = "ò", .out = "o?" }, .{ .in = "ö", .out = "o?" },  .{ .in = "ô", .out = "o?" },
        .{ .in = "õ", .out = "o?" },  .{ .in = "Ó", .out = "O?" }, .{ .in = "Ò", .out = "O?" },  .{ .in = "Ö", .out = "O?" },
        .{ .in = "Ô", .out = "O?" },  .{ .in = "Õ", .out = "O?" }, .{ .in = "ú", .out = "u?" },  .{ .in = "ù", .out = "u?" },
        .{ .in = "ü", .out = "u?" },  .{ .in = "û", .out = "u?" }, .{ .in = "Ú", .out = "U?" },  .{ .in = "Ù", .out = "U?" },
        .{ .in = "Ü", .out = "U?" },  .{ .in = "Û", .out = "U?" }, .{ .in = "ñ", .out = "n?" },  .{ .in = "Ñ", .out = "N?" },
        .{ .in = "ç", .out = "c?" },  .{ .in = "Ç", .out = "C?" }, .{ .in = "ß", .out = "ss?" }, .{ .in = "æ", .out = "ae?" },
        .{ .in = "Æ", .out = "AE?" }, .{ .in = "ø", .out = "o?" }, .{ .in = "Ø", .out = "O?" },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |c| {
        const out = try transliterateAscii(arena.allocator(), c.in);
        try std.testing.expect(out != null);
        try std.testing.expectEqualStrings(c.out, out.?);
    }
}

test "transliterateAscii preserves ascii and maps accents in mixed string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try transliterateAscii(arena.allocator(), "File_éß.txt");
    try std.testing.expectEqualStrings("File_e?ss?.txt", out.?);
}
