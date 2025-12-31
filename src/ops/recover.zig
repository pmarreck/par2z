const std = @import("std");
const core = @import("core");
const common = @import("common.zig");
const path_util = @import("path.zig");

const OutputTarget = common.OutputTarget;
const StreamInput = common.StreamInput;

pub fn recover(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    opts: common.RecoverOptions,
) !void {
    const debug_recover = common.envFlagSet("PAR2_DEBUG_RECOVER");
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    var limited: common.LimitedAllocator = undefined;
    var recover_alloc = allocator;
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(scratch, @intCast(cap));
        recover_alloc = limited.allocator();
    }

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
    try common.loadPar2File(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, opts.par2_path, &recovery_set_id);
    try common.loadVolumeFiles(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, opts.par2_path, &recovery_set_id);
    if (ctx.recovery_set == null) return error.InvalidInput;
    if (recovery_slices.items.len == 0 and packed_slices.items.len == 0) return error.InvalidInput;

    if (debug_recover) {
        var desc_count: usize = 0;
        var ifsc_count: usize = 0;
        if (ctx.recovery_set) |set| {
            for (set.recovery_files) |f| {
                if (f.desc != null) desc_count += 1;
                if (f.ifsc != null) ifsc_count += 1;
            }
        }
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "debug: desc={d} ifsc={d} file_slices={d} rec_slices={d}\n", .{ desc_count, ifsc_count, file_slices.items.len, recovery_slices.items.len });
        try std.fs.File.stderr().writeAll(msg);
    }
    const rs_set = ctx.recovery_set.?;
    const slice_size = std.math.cast(usize, rs_set.slice_size) orelse return error.InvalidInput;
    if (recovery_slices.items.len == 0 and packed_slices.items.len > 0) {
        const packed_main = ctx.packed_main orelse ctx.main;
        if (packed_main) |m| {
            if (m.subslice_size != null and m.subslice_size.? == m.slice_size) {
                try recovery_slices.appendSlice(allocator, packed_slices.items);
            } else {
                return error.InvalidInput;
            }
        } else {
            return error.InvalidInput;
        }
    }

    var files = try allocator.alloc(core.layout.FileInfo, rs_set.recovery_files.len);
    var file_entries = try allocator.alloc(core.storage.FileEntry, rs_set.recovery_files.len);
    var present = try allocator.alloc(bool, rs_set.recovery_files.len);
    defer allocator.free(files);
    defer allocator.free(file_entries);
    defer allocator.free(present);
    var i: usize = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        const entry = rs_set.recovery_files[i];
        if (entry.desc == null) return error.InvalidInput;
        const desc = entry.desc.?;
        files[i] = .{ .length = desc.file_length };
        file_entries[i] = .{ .path = "", .length = desc.file_length, .present = false };
        present[i] = false;
    }

    if (opts.data_paths.len == 0) {
        i = 0;
        while (i < rs_set.recovery_files.len) : (i += 1) {
            const entry = rs_set.recovery_files[i];
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
        i = 0;
        while (i < opts.data_paths.len) : (i += 1) {
            const path = opts.data_paths[i];
            const base = path_util.baseName(path);
            const rel = if (opts.basepath) |bp| try common.relativePathForInput(allocator, bp, path) else null;
            const idx = try common.findRecoveryIndexByName(rs_set, path, base, rel);
            if (present[idx]) return error.InvalidInput;
            const info = try std.fs.cwd().statFile(path);
            file_entries[idx] = .{ .path = path, .length = info.size, .present = true };
            present[idx] = true;
        }
    }

    const store = core.storage.FileStore{ .files = file_entries };
    var missing_flags = try allocator.alloc([]bool, rs_set.recovery_files.len);
    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        const entry = rs_set.recovery_files[i];
        if (entry.desc == null) return error.InvalidInput;
        const desc = entry.desc.?;
        const slice_count = try core.slices.sliceCount(desc.file_length, slice_size);
        var flags = try allocator.alloc(bool, slice_count);
        @memset(flags, false);
        if (!present[i]) {
            @memset(flags, true);
        } else {
            if (entry.ifsc == null) return error.InvalidInput;
            const expected = entry.ifsc.?.entries;
            if (expected.len != slice_count) return error.InvalidInput;
            var si: usize = 0;
            while (si < slice_count) : (si += 1) {
                const slice = store.readSlice(scratch, i, slice_size, si) catch {
                    flags[si] = true;
                    continue;
                };
                defer scratch.free(slice);
                const computed = try computeSliceEntry(slice);
                if (!std.mem.eql(u8, &computed.md5, &expected[si].md5) or computed.crc32 != expected[si].crc32) {
                    flags[si] = true;
                }
            }
        }
        missing_flags[i] = flags;
    }

    const order = try core.layout.buildSliceOrder(allocator, files, slice_size);
    var overrides = std.AutoHashMap(u128, []const u8).init(allocator);
    defer overrides.deinit();
    if (file_slices.items.len > 0) {
        var id_map = std.AutoHashMap([16]u8, usize).init(allocator);
        defer id_map.deinit();
        i = 0;
        while (i < rs_set.recovery_files.len) : (i += 1) {
            const entry = rs_set.recovery_files[i];
            if (entry.desc == null) continue;
            try id_map.put(entry.desc.?.file_id, i);
        }
        for (file_slices.items) |fs| {
            const idx = id_map.get(fs.file_id) orelse continue;
            const slice_idx = std.math.cast(usize, fs.slice_index) orelse continue;
            if (slice_idx >= missing_flags[idx].len) continue;
            const key = makeSliceKey(idx, slice_idx);
            try overrides.put(key, fs.data);
            missing_flags[idx][slice_idx] = false;
        }
    }
    const store2 = SliceOverrideStore{
        .base = store,
        .overrides = &overrides,
    };
    if (cap_bytes) |cap| {
        if (cap == 0) return error.InvalidInput;
        const count_u64: u64 = @intCast(order.len);
        const slice_u64: u64 = @intCast(slice_size);
        const mul = @mulWithOverflow(count_u64, slice_u64);
        if (mul[1] != 0) return error.InvalidInput;
        if (mul[0] > cap) return error.InvalidInput;
    }
    var missing_indices = std.ArrayList(usize).empty;
    defer missing_indices.deinit(allocator);
    var oi: usize = 0;
    while (oi < order.len) : (oi += 1) {
        const ref = order[oi];
        if (missing_flags[ref.file_index][ref.slice_index]) {
            try missing_indices.append(allocator, oi);
        }
    }

    var missing_files_count: usize = 0;
    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        if (!present[i] or anyMissing(missing_flags[i])) missing_files_count += 1;
    }
    if (missing_indices.items.len == 0 and missing_files_count == 0) {
        if (opts.verbosity >= 0) {
            try common.infoFile().writeAll("Nothing to recover\n");
        }
        return;
    }
    if (missing_indices.items.len > 0 and recovery_slices.items.len < missing_indices.items.len) return error.InvalidInput;

    const recovered = if (missing_indices.items.len == 0)
        try allocator.alloc([]u8, 0)
    else
        try core.api.recoverMissingSlicesMemory(
            recover_alloc,
            files,
            store2,
            missing_indices.items,
            recovery_slices.items[0..missing_indices.items.len],
            slice_size,
        );
    defer {
        if (cap_bytes != null) {
            var ri: usize = 0;
            while (ri < recovered.len) : (ri += 1) {
                recover_alloc.free(recovered[ri]);
            }
            recover_alloc.free(recovered);
        }
    }

    var recovered_for = try allocator.alloc(?usize, order.len);
    @memset(recovered_for, null);
    for (missing_indices.items, 0..) |global_idx, rec_idx| {
        recovered_for[global_idx] = rec_idx;
    }
    if (opts.stdout_only and missing_files_count != 1) return error.InvalidInput;
    if (opts.stdout_only and opts.output_open != null) return error.InvalidInput;

    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        if (present[i] and !anyMissing(missing_flags[i])) continue;
        const desc = rs_set.recovery_files[i].desc.?;
        var computed: [16]u8 = undefined;
        if (opts.stdout_only) {
            const stdout = std.fs.File.stdout();
            computed = try writeRecoveredFileSlicesWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, stdout);
        } else if (opts.output_open != null) {
            const target_dir = opts.out_dir orelse opts.basepath;
            const out_path = try pickOutputPath(allocator, target_dir, desc.file_name, opts.allow_unsafe_paths, present[i], file_entries[i].path);
            defer if (out_path.owned) allocator.free(out_path.path);
            var out = try common.openOutput(allocator, out_path.path, opts.output_open);
            defer out.close();
            computed = try writeRecoveredFileSlicesWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, &out);
        } else {
            const target_dir = opts.out_dir orelse opts.basepath;
            const out_path = try pickOutputPath(allocator, target_dir, desc.file_name, opts.allow_unsafe_paths, present[i], file_entries[i].path);
            defer if (out_path.owned) allocator.free(out_path.path);
            const in_place = present[i] and file_entries[i].path.len != 0 and std.mem.eql(u8, out_path.path, file_entries[i].path);
            if (in_place) {
                var tmp = try openTempOutputForPath(allocator, out_path.path);
                var keep_tmp = false;
                defer {
                    tmp.file.close();
                    if (!keep_tmp) std.fs.cwd().deleteFile(tmp.path) catch {};
                    allocator.free(tmp.path);
                }
                computed = try writeRecoveredFileSlicesWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, tmp.file);
                try std.fs.cwd().rename(tmp.path, out_path.path);
                keep_tmp = true;
            } else {
                computed = try writeRecoveredFilePathWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, out_path.path);
            }
        }
        if (!std.mem.eql(u8, &computed, &desc.file_hash)) return error.InvalidInput;
    }

    if (opts.verbosity >= 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "Recovered {d} slices\n", .{missing_indices.items.len});
        try common.infoFile().writeAll(msg);
    }
}

pub fn recoverStreams(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    main_bytes: []const u8,
    volumes: []const []const u8,
    opts: common.RecoverOptions,
    inputs: []const StreamInput,
) !void {
    if (opts.data_paths.len != 0) return error.InvalidInput;
    const debug_recover = common.envFlagSet("PAR2_DEBUG_RECOVER");
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    var limited: common.LimitedAllocator = undefined;
    var recover_alloc = allocator;
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(scratch, @intCast(cap));
        recover_alloc = limited.allocator();
    }

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
    try common.loadPar2Bytes(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, main_bytes, &recovery_set_id);
    for (volumes) |vol| {
        try common.loadPar2Bytes(allocator, &ctx, &recovery_slices, &packed_slices, &file_slices, &rfsc_packets, vol, &recovery_set_id);
    }
    if (ctx.recovery_set == null) return error.InvalidInput;
    if (recovery_slices.items.len == 0 and packed_slices.items.len == 0) return error.InvalidInput;

    if (debug_recover) {
        var desc_count: usize = 0;
        var ifsc_count: usize = 0;
        if (ctx.recovery_set) |set| {
            for (set.recovery_files) |f| {
                if (f.desc != null) desc_count += 1;
                if (f.ifsc != null) ifsc_count += 1;
            }
        }
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "debug: desc={d} ifsc={d} file_slices={d} rec_slices={d}\n", .{ desc_count, ifsc_count, file_slices.items.len, recovery_slices.items.len });
        try std.fs.File.stderr().writeAll(msg);
    }
    const rs_set = ctx.recovery_set.?;
    const slice_size = std.math.cast(usize, rs_set.slice_size) orelse return error.InvalidInput;
    if (recovery_slices.items.len == 0 and packed_slices.items.len > 0) {
        const packed_main = ctx.packed_main orelse ctx.main;
        if (packed_main) |m| {
            if (m.subslice_size != null and m.subslice_size.? == m.slice_size) {
                try recovery_slices.appendSlice(allocator, packed_slices.items);
            } else {
                return error.InvalidInput;
            }
        } else {
            return error.InvalidInput;
        }
    }

    var files = try allocator.alloc(core.layout.FileInfo, rs_set.recovery_files.len);
    var stream_entries = try allocator.alloc(core.storage.StreamEntry, rs_set.recovery_files.len);
    var present = try allocator.alloc(bool, rs_set.recovery_files.len);
    defer allocator.free(files);
    defer allocator.free(stream_entries);
    defer allocator.free(present);
    var i: usize = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        const entry = rs_set.recovery_files[i];
        if (entry.desc == null) return error.InvalidInput;
        const desc = entry.desc.?;
        files[i] = .{ .length = desc.file_length };
        stream_entries[i] = .{ .length = desc.file_length, .read_at = common.missingReadAt, .ctx = &common.missing_ctx };
        present[i] = false;
    }

    for (inputs) |input| {
        const base = path_util.baseName(input.name);
        const rel = if (opts.basepath) |bp| try common.relativePathForInput(allocator, bp, input.name) else null;
        const idx = try common.findRecoveryIndexByName(rs_set, input.name, base, rel);
        if (present[idx]) return error.InvalidInput;
        if (input.length != files[idx].length) return error.InvalidInput;
        stream_entries[idx] = .{ .length = input.length, .read_at = input.read_at, .ctx = input.ctx };
        present[idx] = true;
    }

    const base_store = core.storage.StreamStore{ .files = stream_entries };
    var missing_flags = try allocator.alloc([]bool, rs_set.recovery_files.len);
    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        const entry = rs_set.recovery_files[i];
        if (entry.desc == null) return error.InvalidInput;
        const desc = entry.desc.?;
        const slice_count = try core.slices.sliceCount(desc.file_length, slice_size);
        var flags = try allocator.alloc(bool, slice_count);
        @memset(flags, false);
        if (!present[i]) {
            @memset(flags, true);
        } else {
            if (entry.ifsc == null) return error.InvalidInput;
            const expected = entry.ifsc.?.entries;
            if (expected.len != slice_count) return error.InvalidInput;
            var si: usize = 0;
            while (si < slice_count) : (si += 1) {
                const slice = base_store.readSlice(scratch, i, slice_size, si) catch {
                    flags[si] = true;
                    continue;
                };
                defer scratch.free(slice);
                const computed = try computeSliceEntry(slice);
                if (!std.mem.eql(u8, &computed.md5, &expected[si].md5) or computed.crc32 != expected[si].crc32) {
                    flags[si] = true;
                }
            }
        }
        missing_flags[i] = flags;
    }

    const order = try core.layout.buildSliceOrder(allocator, files, slice_size);
    var overrides = std.AutoHashMap(u128, []const u8).init(allocator);
    defer overrides.deinit();
    if (file_slices.items.len > 0) {
        var id_map = std.AutoHashMap([16]u8, usize).init(allocator);
        defer id_map.deinit();
        i = 0;
        while (i < rs_set.recovery_files.len) : (i += 1) {
            const entry = rs_set.recovery_files[i];
            if (entry.desc == null) continue;
            try id_map.put(entry.desc.?.file_id, i);
        }
        for (file_slices.items) |fs| {
            const idx = id_map.get(fs.file_id) orelse continue;
            const slice_idx = std.math.cast(usize, fs.slice_index) orelse continue;
            if (slice_idx >= missing_flags[idx].len) continue;
            const key = makeSliceKey(idx, slice_idx);
            try overrides.put(key, fs.data);
            missing_flags[idx][slice_idx] = false;
        }
    }
    const store2 = SliceOverrideStoreStream{
        .base = base_store,
        .overrides = &overrides,
    };
    if (cap_bytes) |cap| {
        if (cap == 0) return error.InvalidInput;
        const count_u64: u64 = @intCast(order.len);
        const slice_u64: u64 = @intCast(slice_size);
        const mul = @mulWithOverflow(count_u64, slice_u64);
        if (mul[1] != 0) return error.InvalidInput;
        if (mul[0] > cap) return error.InvalidInput;
    }
    var missing_indices = std.ArrayList(usize).empty;
    defer missing_indices.deinit(allocator);
    var oi: usize = 0;
    while (oi < order.len) : (oi += 1) {
        const ref = order[oi];
        if (missing_flags[ref.file_index][ref.slice_index]) {
            try missing_indices.append(allocator, oi);
        }
    }

    var missing_files_count: usize = 0;
    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        if (!present[i] or anyMissing(missing_flags[i])) missing_files_count += 1;
    }
    if (missing_indices.items.len == 0 and missing_files_count == 0) {
        if (opts.verbosity >= 0) {
            try common.infoFile().writeAll("Nothing to recover\n");
        }
        return;
    }
    if (missing_indices.items.len > 0 and recovery_slices.items.len < missing_indices.items.len) return error.InvalidInput;

    const recovered = if (missing_indices.items.len == 0)
        try allocator.alloc([]u8, 0)
    else
        try core.api.recoverMissingSlicesMemory(
            recover_alloc,
            files,
            store2,
            missing_indices.items,
            recovery_slices.items[0..missing_indices.items.len],
            slice_size,
        );
    defer {
        if (cap_bytes != null) {
            var ri: usize = 0;
            while (ri < recovered.len) : (ri += 1) {
                recover_alloc.free(recovered[ri]);
            }
            recover_alloc.free(recovered);
        }
    }

    var recovered_for = try allocator.alloc(?usize, order.len);
    @memset(recovered_for, null);
    for (missing_indices.items, 0..) |global_idx, rec_idx| {
        recovered_for[global_idx] = rec_idx;
    }
    if (opts.stdout_only and missing_files_count != 1) return error.InvalidInput;
    if (opts.stdout_only and opts.output_open != null) return error.InvalidInput;

    i = 0;
    while (i < rs_set.recovery_files.len) : (i += 1) {
        if (present[i] and !anyMissing(missing_flags[i])) continue;
        const desc = rs_set.recovery_files[i].desc.?;
        var computed: [16]u8 = undefined;
        if (opts.stdout_only) {
            const stdout = std.fs.File.stdout();
            computed = try writeRecoveredFileSlicesWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, stdout);
        } else if (opts.output_open != null) {
            const target_dir = opts.out_dir orelse opts.basepath;
            const out_path = try outputPath(allocator, target_dir, desc.file_name, opts.allow_unsafe_paths);
            defer if (out_path.owned) allocator.free(out_path.path);
            var out = try common.openOutput(allocator, out_path.path, opts.output_open);
            defer out.close();
            computed = try writeRecoveredFileSlicesWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, &out);
        } else {
            const target_dir = opts.out_dir orelse opts.basepath;
            const out_path = try outputPath(allocator, target_dir, desc.file_name, opts.allow_unsafe_paths);
            defer if (out_path.owned) allocator.free(out_path.path);
            computed = try writeRecoveredFilePathWithHash(scratch, store2, order, recovered_for, recovered, i, slice_size, out_path.path);
        }
        if (!std.mem.eql(u8, &computed, &desc.file_hash)) return error.InvalidInput;
    }

    if (opts.verbosity >= 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "Recovered {d} slices\n", .{missing_indices.items.len});
        try common.infoFile().writeAll(msg);
    }
}

fn computeSliceEntry(slice: []const u8) !core.packet_types.IfscEntry {
    var entry: core.packet_types.IfscEntry = undefined;
    try core.md5.md5Digest(slice, &entry.md5);
    entry.crc32 = core.crc32.crc32(slice);
    return entry;
}

fn writeRecoveredFileSlices(
    scratch: std.mem.Allocator,
    store: anytype,
    order: []const core.layout.SliceRef,
    recovered_for: []const ?usize,
    recovered: [][]u8,
    file_index: usize,
    slice_size: usize,
    writer: anytype,
) !void {
    var oi: usize = 0;
    while (oi < order.len) : (oi += 1) {
        const ref = order[oi];
        if (ref.file_index != file_index) continue;
        const len = ref.length;
        if (recovered_for[oi]) |rec_idx| {
            try writer.writeAll(recovered[rec_idx][0..len]);
            continue;
        }
        const slice = try store.readSlice(scratch, file_index, slice_size, ref.slice_index);
        defer scratch.free(slice);
        try writer.writeAll(slice[0..len]);
    }
}

fn writeRecoveredFileSlicesWithHash(
    scratch: std.mem.Allocator,
    store: anytype,
    order: []const core.layout.SliceRef,
    recovered_for: []const ?usize,
    recovered: [][]u8,
    file_index: usize,
    slice_size: usize,
    writer: anytype,
) ![16]u8 {
    var ctx = core.md5.Md5Ctx.init(.{});
    var oi: usize = 0;
    while (oi < order.len) : (oi += 1) {
        const ref = order[oi];
        if (ref.file_index != file_index) continue;
        const len = ref.length;
        if (recovered_for[oi]) |rec_idx| {
            const data = recovered[rec_idx][0..len];
            ctx.update(data);
            try writer.writeAll(data);
            continue;
        }
        const slice = try store.readSlice(scratch, file_index, slice_size, ref.slice_index);
        defer scratch.free(slice);
        const data = slice[0..len];
        ctx.update(data);
        try writer.writeAll(data);
    }
    var out: [16]u8 = undefined;
    ctx.final(&out);
    return out;
}

fn writeRecoveredFilePath(
    scratch: std.mem.Allocator,
    store: anytype,
    order: []const core.layout.SliceRef,
    recovered_for: []const ?usize,
    recovered: [][]u8,
    file_index: usize,
    slice_size: usize,
    path: []const u8,
) !void {
    try common.ensureDirForPath(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try writeRecoveredFileSlices(scratch, store, order, recovered_for, recovered, file_index, slice_size, file);
}

fn writeRecoveredFilePathWithHash(
    scratch: std.mem.Allocator,
    store: anytype,
    order: []const core.layout.SliceRef,
    recovered_for: []const ?usize,
    recovered: [][]u8,
    file_index: usize,
    slice_size: usize,
    path: []const u8,
) ![16]u8 {
    try common.ensureDirForPath(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    return writeRecoveredFileSlicesWithHash(scratch, store, order, recovered_for, recovered, file_index, slice_size, file);
}

fn outputPath(allocator: std.mem.Allocator, out_dir: ?[]const u8, file_name: []const u8, allow_unsafe_paths: bool) !common.NormalizedPath {
    if (allow_unsafe_paths) {
        if (out_dir == null) return .{ .path = file_name, .owned = false };
        return .{ .path = try path_util.join(allocator, out_dir.?, file_name), .owned = true };
    }
    const norm = try common.normalizeRelativePath(allocator, file_name);
    if (out_dir == null) return norm;
    const joined = try path_util.join(allocator, out_dir.?, norm.path);
    if (norm.owned) allocator.free(norm.path);
    return .{ .path = joined, .owned = true };
}

fn pickOutputPath(
    allocator: std.mem.Allocator,
    out_dir: ?[]const u8,
    file_name: []const u8,
    allow_unsafe_paths: bool,
    present: bool,
    file_path: []const u8,
) !common.NormalizedPath {
    if (out_dir != null) {
        return outputPath(allocator, out_dir, file_name, allow_unsafe_paths);
    }
    if (present and file_path.len != 0) {
        return .{ .path = file_path, .owned = false };
    }
    return outputPath(allocator, null, file_name, allow_unsafe_paths);
}

const TempOutput = struct {
    path: []const u8,
    file: std.fs.File,
};

fn openTempOutputForPath(allocator: std.mem.Allocator, target_path: []const u8) !TempOutput {
    const dir = path_util.dirNameOrDot(target_path);
    const base = path_util.baseName(target_path);
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const stamp = std.time.nanoTimestamp();
        const name = try std.fmt.allocPrint(allocator, ".{s}.par2z.{d}.{d}.tmp", .{ base, stamp, attempt });
        defer allocator.free(name);
        const full = try path_util.join(allocator, dir, name);
        errdefer allocator.free(full);
        const file = std.fs.cwd().createFile(full, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                allocator.free(full);
                continue;
            }
            return err;
        };
        return .{ .path = full, .file = file };
    }
    return error.PathAlreadyExists;
}

const SliceOverrideStore = struct {
    base: core.storage.FileStore,
    overrides: *std.AutoHashMap(u128, []const u8),

    pub fn readSlice(
        self: SliceOverrideStore,
        allocator: std.mem.Allocator,
        file_index: usize,
        slice_size: usize,
        slice_index: usize,
    ) ![]u8 {
        const key = makeSliceKey(file_index, slice_index);
        if (self.overrides.get(key)) |data| {
            var out = try allocator.alloc(u8, slice_size);
            @memset(out, 0);
            const n = @min(slice_size, data.len);
            @memcpy(out[0..n], data[0..n]);
            return out;
        }
        return self.base.readSlice(allocator, file_index, slice_size, slice_index);
    }
};

const SliceOverrideStoreStream = struct {
    base: core.storage.StreamStore,
    overrides: *std.AutoHashMap(u128, []const u8),

    pub fn readSlice(
        self: SliceOverrideStoreStream,
        allocator: std.mem.Allocator,
        file_index: usize,
        slice_size: usize,
        slice_index: usize,
    ) ![]u8 {
        const key = makeSliceKey(file_index, slice_index);
        if (self.overrides.get(key)) |data| {
            var out = try allocator.alloc(u8, slice_size);
            @memset(out, 0);
            const n = @min(slice_size, data.len);
            @memcpy(out[0..n], data[0..n]);
            return out;
        }
        return self.base.readSlice(allocator, file_index, slice_size, slice_index);
    }
};

fn makeSliceKey(file_index: usize, slice_index: usize) u128 {
    return (@as(u128, file_index) << 64) | @as(u128, slice_index);
}

fn anyMissing(flags: []const bool) bool {
    for (flags) |v| {
        if (v) return true;
    }
    return false;
}

test "outputPath rejects absolute file names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "/var/tmp/file.bin", false));
}

test "outputPath rejects traversal segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "../file.bin", false));
    try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "a/../file.bin", false));
}

test "outputPath rejects windows drive prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidInput, outputPath(arena.allocator(), "/tmp/out", "C:\\tmp\\file.bin", false));
}

test "outputPath allows unsafe when flag set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try outputPath(arena.allocator(), "/tmp/out", "/var/tmp/file.bin", true);
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("/tmp/out/var/tmp/file.bin", out.path);
}

test "outputPath accepts unicode names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try outputPath(arena.allocator(), "/tmp/out", "café.txt", false);
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("/tmp/out/café.txt", out.path);
}

test "outputPath normalizes relative paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try outputPath(arena.allocator(), "/tmp/out", "./a//b\\c.txt", false);
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("/tmp/out/a/b/c.txt", out.path);
}

test "outputPath normalizes dotted segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try outputPath(arena.allocator(), null, "a/./b/./c.txt", false);
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("a/b/c.txt", out.path);
}

test "pickOutputPath prefers explicit data path when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try pickOutputPath(arena.allocator(), null, "file.txt", false, true, "/tmp/data/file.txt");
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("/tmp/data/file.txt", out.path);
}

test "pickOutputPath uses out_dir even if file path present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try pickOutputPath(arena.allocator(), "/out", "file.txt", false, true, "/tmp/data/file.txt");
    defer if (out.owned) arena.allocator().free(out.path);
    try std.testing.expectEqualStrings("/out/file.txt", out.path);
}
