const std = @import("std");
const core = @import("core");
const common = @import("common.zig");
const path_util = @import("path.zig");

const StreamInput = common.StreamInput;

pub fn verify(
    allocator: std.mem.Allocator,
    opts: common.VerifyOptions,
) !void {
    const par2_bytes = try std.fs.cwd().readFileAlloc(allocator, opts.par2_path, 1 << 24);
    var ctx = core.api.initContext(allocator);
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        try core.api.addPacket(allocator, &ctx, pkt);
        offset += end - 1;
    }
    if (ctx.recovery_set == null) return error.ParityCorrupt;
    const rs_set = ctx.recovery_set.?;
    var file_entries = try allocator.alloc(core.storage.FileEntry, rs_set.recovery_files.len);
    var present = try allocator.alloc(bool, rs_set.recovery_files.len);
    @memset(present, false);
    for (file_entries) |*entry| {
        entry.* = .{ .path = "", .length = 0, .present = false };
    }

    var limited: common.LimitedAllocator = undefined;
    var verify_alloc = allocator;
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(allocator, @intCast(cap));
        verify_alloc = limited.allocator();
    }

    if (opts.data_paths.len == 0) {
        for (rs_set.recovery_files, 0..) |entry, i| {
            if (entry.desc == null) continue;
            const name = entry.desc.?.file_name;
            const candidate = try path_util.joinOptional(allocator, opts.basepath, name);
            const info = std.fs.cwd().statFile(candidate) catch {
                continue;
            };
            file_entries[i] = .{ .path = candidate, .length = info.size, .present = true };
            present[i] = true;
        }
    } else {
        for (opts.data_paths) |path| {
            const base = path_util.baseName(path);
            const rel = if (opts.basepath) |bp| try common.relativePathForInput(allocator, bp, path) else null;
            const idx = common.findRecoveryIndexByName(rs_set, path, base, rel) catch |e| switch (e) {
                error.NotFound => return error.ParityMissingFile,
                else => return e,
            };
            if (present[idx]) return error.InvalidInput;
            const info = std.fs.cwd().statFile(path) catch return error.NotFound;
            file_entries[idx] = .{ .path = path, .length = info.size, .present = true };
            present[idx] = true;
        }
    }
    for (present) |p| {
        if (!p) return error.NotFound;
    }
    for (rs_set.recovery_files, 0..) |entry, i| {
        if (entry.desc == null) return error.ParityCorrupt;
        if (entry.desc.?.file_length != file_entries[i].length) return error.DataCorrupt;
        if (entry.ifsc != null) continue;
        const computed = try common.md5File(file_entries[i].path);
        if (!std.mem.eql(u8, &computed, &entry.desc.?.file_hash)) return error.DataCorrupt;
    }
    const store = core.storage.FileStore{ .files = file_entries };
    try core.api.verifyStoreFile(verify_alloc, &ctx, store);
}

pub fn verifyStreams(
    allocator: std.mem.Allocator,
    par2_files: []const []const u8,
    opts: common.VerifyOptions,
    inputs: []const StreamInput,
) !void {
    if (opts.data_paths.len != 0) return error.InvalidInput;
    if (par2_files.len == 0) return error.InvalidInput;
    var ctx = core.api.initContext(allocator);
    var recovery_slices = std.ArrayList(core.rs.RecoverySlice).empty;
    defer recovery_slices.deinit(allocator);
    var packed_slices = std.ArrayList(core.rs.RecoverySlice).empty;
    defer packed_slices.deinit(allocator);
    var file_slices = std.ArrayList(core.packet_types.FileSlicPacket).empty;
    defer file_slices.deinit(allocator);
    var rfsc_packets = std.ArrayList(core.packet_types.RfscPacket).empty;
    defer rfsc_packets.deinit(allocator);
    var recovery_set_id: ?[16]u8 = null;
    for (par2_files) |par2_bytes| {
        try common.loadPar2Bytes(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, par2_bytes, &recovery_set_id);
    }
    if (ctx.recovery_set == null) return error.ParityCorrupt;
    const rs_set = ctx.recovery_set.?;

    var stream_entries = try allocator.alloc(core.storage.StreamEntry, rs_set.recovery_files.len);
    var present = try allocator.alloc(bool, rs_set.recovery_files.len);
    defer allocator.free(stream_entries);
    defer allocator.free(present);
    @memset(present, false);
    for (stream_entries) |*entry| {
        entry.* = .{ .length = 0, .read_at = common.missingReadAt, .ctx = &common.missing_ctx };
    }
    for (inputs) |input| {
        const base = path_util.baseName(input.name);
        const rel = if (opts.basepath) |bp| try common.relativePathForInput(allocator, bp, input.name) else null;
        const idx = common.findRecoveryIndexByName(rs_set, input.name, base, rel) catch |e| switch (e) {
            error.NotFound => return error.ParityMissingFile,
            else => return e,
        };
        if (present[idx]) return error.InvalidInput;
        const desc = rs_set.recovery_files[idx].desc orelse return error.ParityCorrupt;
        if (desc.file_length != input.length) return error.DataCorrupt;
        stream_entries[idx] = .{ .length = input.length, .read_at = input.read_at, .ctx = input.ctx };
        present[idx] = true;
    }
    for (present) |p| {
        if (!p) return error.InvalidInput;
    }

    var limited: common.LimitedAllocator = undefined;
    var verify_alloc = allocator;
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(allocator, @intCast(cap));
        verify_alloc = limited.allocator();
    }

    for (rs_set.recovery_files, 0..) |entry, i| {
        if (entry.desc == null) return error.ParityCorrupt;
        if (entry.ifsc != null) continue;
        const computed = try common.md5Stream(.{
            .name = entry.desc.?.file_name,
            .length = stream_entries[i].length,
            .read_at = stream_entries[i].read_at,
            .ctx = stream_entries[i].ctx,
        });
        if (!std.mem.eql(u8, &computed, &entry.desc.?.file_hash)) return error.DataCorrupt;
    }
    const store = core.storage.StreamStore{ .files = stream_entries };
    try core.api.verifyStoreStream(verify_alloc, &ctx, store);
}
