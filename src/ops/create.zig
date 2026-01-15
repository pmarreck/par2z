const std = @import("std");
const core = @import("core");
const common = @import("common.zig");
const path_util = @import("path.zig");

const OutputTarget = common.OutputTarget;
const OutputOpener = common.OutputOpener;
const StreamInput = common.StreamInput;

const FileMeta = struct {
    path: []const u8,
    name: []const u8,
    length: u64,
    file_id: [16]u8,
    file_hash_16k: [16]u8,
};

const CreateInput = struct {
    path: []const u8,
    name: []const u8,
    length: u64,
};

const FileInfoResult = struct {
    file_hash: [16]u8,
    ifsc_entries: []core.packet_types.IfscEntry,
};

pub fn create(allocator: std.mem.Allocator, opts: common.CreateOptions) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const inputs = try collectCreateInputs(arena_alloc, opts.data_paths, opts.recurse, opts.basepath);
    var total_size: u64 = 0;
    var max_file_len: u64 = 0;
    for (inputs) |input| {
        total_size += input.length;
        if (input.length > max_file_len) max_file_len = input.length;
    }
    const block_size = if (opts.block_size) |v|
        v
    else if (opts.block_count) |c|
        core.create_plan.blockSizeFromCount(total_size, c)
    else
        core.heuristics.blockSizeHeuristic(total_size);
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    if (cap_bytes) |cap| {
        if (cap == 0) return error.InvalidInput;
        if (block_size > cap) return error.InvalidInput;
    }
    const data_blocks = if (block_size == 0) 0 else (total_size + block_size - 1) / block_size;
    const recovery_blocks = if (opts.recovery_blocks) |v|
        v
    else
        core.create_plan.recoveryBlocksFromPercent(data_blocks, opts.redundancy_percent orelse 0) catch return error.InvalidInput;

    const mute_defaults = opts.mute_defaults or common.envMuteDefaults();
    if (!mute_defaults) {
        if (opts.block_size == null and opts.block_count == null) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "default block size: {d}\n", .{block_size});
            try std.fs.File.stderr().writeAll(msg);
        }
        if (opts.recovery_blocks == null and opts.redundancy_percent != null) {
            var buf2: [128]u8 = undefined;
            const msg2 = try std.fmt.bufPrint(&buf2, "default redundancy percent: {d}\n", .{opts.redundancy_percent.?});
            try std.fs.File.stderr().writeAll(msg2);
        }
        var plan_buf: [256]u8 = undefined;
        const plan = try std.fmt.bufPrint(
            &plan_buf,
            "derived plan: total_size={d} block_size={d} data_blocks={d} recovery_blocks={d}\n",
            .{ total_size, block_size, data_blocks, recovery_blocks },
        );
        try std.fs.File.stderr().writeAll(plan);
    }

    var files = try arena_alloc.alloc(FileMeta, inputs.len);
    var i: usize = 0;
    while (i < inputs.len) : (i += 1) {
        const input = inputs[i];
        const file_hash_16k = try common.md5First16k(input.path);
        const file_id = try core.file_id.fileIdFromHash16k(arena_alloc, file_hash_16k, input.length, input.name);
        files[i] = .{
            .path = input.path,
            .name = input.name,
            .length = input.length,
            .file_id = file_id,
            .file_hash_16k = file_hash_16k,
        };
    }

    std.sort.insertion(FileMeta, files, {}, fileMetaLessThan);

    var file_ids = try arena_alloc.alloc([16]u8, files.len);
    i = 0;
    while (i < files.len) : (i += 1) {
        file_ids[i] = files[i].file_id;
    }
    const main_body = try core.create_packets.buildMainBody(arena_alloc, block_size, file_ids);
    var recovery_set_id: [16]u8 = undefined;
    try core.md5.md5Digest(main_body, &recovery_set_id);

    const creator_text = "par2z 0.1.0";
    const creator_pkt = try core.create_packets.buildCreatorPacket(arena_alloc, recovery_set_id, creator_text);
    const main_pkt = try core.create_packets.buildMainPacket(arena_alloc, recovery_set_id, main_body);

    var main_packets = std.ArrayList([]const u8).empty;
    defer main_packets.deinit(arena_alloc);
    var volume_meta_packets = std.ArrayList([]const u8).empty;
    defer volume_meta_packets.deinit(arena_alloc);
    try main_packets.append(arena_alloc, main_pkt);
    if (opts.metadata) |meta| {
        if (files.len != 1) return error.InvalidInput;
        const meta_pkt = try core.create_packets.buildSourceMetadataPacket(arena_alloc, recovery_set_id, meta);
        try main_packets.append(arena_alloc, meta_pkt);
    }
    if (opts.validation_state) |state| {
        if (files.len != 1) return error.InvalidInput;
        var vs = state;
        vs.file_id = file_ids[0];
        const sfvs_pkt = try core.create_packets.buildValidationStatePacket(arena_alloc, recovery_set_id, vs);
        try main_packets.append(arena_alloc, sfvs_pkt);
    }
    if (opts.include_volume_meta) {
        try volume_meta_packets.append(arena_alloc, main_pkt);
    }
    if (opts.emit_packed) {
        const pkd_body = try core.create_packets.buildPackedMainBody(arena_alloc, block_size, block_size, file_ids, &.{});
        const pkd_pkt = try core.create_packets.buildPackedMainPacket(arena_alloc, recovery_set_id, pkd_body);
        try main_packets.append(arena_alloc, pkd_pkt);
    }
    if (opts.comment) |text| {
        if (common.isAscii(text)) {
            const comm = try core.create_packets.buildCommentAsciiPacket(arena_alloc, recovery_set_id, text);
            try main_packets.append(arena_alloc, comm);
        } else {
            const ascii = try common.transliterateAscii(arena_alloc, text);
            if (ascii) |ascii_text| {
                const comm = try core.create_packets.buildCommentAsciiPacket(arena_alloc, recovery_set_id, ascii_text);
                try main_packets.append(arena_alloc, comm);
                const commu = try core.create_packets.buildCommentUnicodePacketWithAscii(arena_alloc, recovery_set_id, text, ascii_text);
                try main_packets.append(arena_alloc, commu);
            } else {
                const commu = try core.create_packets.buildCommentUnicodePacket(arena_alloc, recovery_set_id, text);
                try main_packets.append(arena_alloc, commu);
            }
        }
    }
    try main_packets.append(arena_alloc, creator_pkt);

    const slice_size = std.math.cast(usize, block_size) orelse return error.InvalidInput;
    var file_infos = try arena_alloc.alloc(core.layout.FileInfo, files.len);
    i = 0;
    while (i < files.len) : (i += 1) {
        file_infos[i] = .{ .length = files[i].length };
    }

    var main_out = try common.openOutput(allocator, opts.par2_path, opts.output_open);
    defer main_out.close();
    for (main_packets.items) |pkt| {
        try main_out.writeAll(pkt);
    }

    i = 0;
    while (i < files.len) : (i += 1) {
        var file_arena = std.heap.ArenaAllocator.init(arena_alloc);
        defer file_arena.deinit();
        const temp_alloc = file_arena.allocator();
        const f = files[i];
        const info = try computeFileInfoAndMaybeWriteSlices(
            temp_alloc,
            f.path,
            f.file_id,
            recovery_set_id,
            slice_size,
            opts.include_input_slices,
            &main_out,
        );
        const filedesc_pkt = try core.create_packets.buildFileDescPacket(
            temp_alloc,
            recovery_set_id,
            f.file_id,
            info.file_hash,
            f.file_hash_16k,
            f.length,
            f.name,
        );
        try main_out.writeAll(filedesc_pkt);
        if (opts.include_volume_meta) {
            const copy = try arena_alloc.dupe(u8, filedesc_pkt);
            try volume_meta_packets.append(arena_alloc, copy);
        }
        const ifsc_pkt = try core.create_packets.buildIfscPacket(
            temp_alloc,
            recovery_set_id,
            f.file_id,
            info.ifsc_entries,
        );
        try main_out.writeAll(ifsc_pkt);
        if (opts.include_volume_meta) {
            const copy = try arena_alloc.dupe(u8, ifsc_pkt);
            try volume_meta_packets.append(arena_alloc, copy);
        }
        if (!common.isAscii(f.name)) {
            const uni_pkt = try core.create_packets.buildUnicodeFilenamePacket(temp_alloc, recovery_set_id, f.file_id, f.name);
            try main_out.writeAll(uni_pkt);
        }
    }
    if (opts.include_volume_meta) {
        try volume_meta_packets.append(arena_alloc, creator_pkt);
    }

    if (recovery_blocks > 0) {
        const offset = opts.first_recovery_block orelse 0;
        if (offset > std.math.maxInt(u32)) return error.InvalidInput;
        if (recovery_blocks > 0 and offset > std.math.maxInt(u32) - (recovery_blocks - 1)) return error.InvalidInput;
        var file_entries = try arena_alloc.alloc(core.storage.FileEntry, files.len);
        i = 0;
        while (i < files.len) : (i += 1) {
            file_entries[i] = .{ .path = files[i].path, .length = files[i].length, .present = true };
        }
        const store = core.storage.FileStore{ .files = file_entries };
        const plan = blk: {
            if (opts.recovery_file_count) |count| {
                if (count == 0 or count > recovery_blocks) return error.InvalidInput;
                if (opts.uniform_recovery) {
                    break :blk try core.create_plan.splitRecoveryBlocksUniform(arena_alloc, recovery_blocks, count);
                }
                break :blk try core.create_plan.splitRecoveryBlocksCounted(arena_alloc, recovery_blocks, count);
            }
            if (opts.uniform_recovery) {
                const count = core.create_plan.defaultVolumeCount(recovery_blocks);
                break :blk try core.create_plan.splitRecoveryBlocksUniform(arena_alloc, recovery_blocks, count);
            }
            if (opts.limit_recovery) {
                var max_blocks: u64 = 0;
                for (files) |f| {
                    const blocks = try core.slices.sliceCount(f.length, slice_size);
                    if (blocks > max_blocks) max_blocks = blocks;
                }
                break :blk try core.create_plan.splitRecoveryBlocksLimited(arena_alloc, recovery_blocks, max_blocks);
            }
            break :blk try core.create_plan.splitRecoveryBlocksDefault(arena_alloc, recovery_blocks);
        };
        if (plan.len == 0) return;
        const width = volumeIndexWidth(recovery_blocks, offset);

        var volume_shared = VolumeShared{
            .volume_meta_packets = volume_meta_packets.items,
            .store = store,
            .file_infos = file_infos,
            .slice_size = slice_size,
            .plan = plan,
            .width = width,
            .offset = offset,
            .par2_path = opts.par2_path,
            .output_open = opts.output_open,
            .recovery_set_id = recovery_set_id,
            .emit_rfsc = opts.emit_rfsc,
            .emit_packed = opts.emit_packed,
            .include_volume_meta = opts.include_volume_meta,
            .cap_bytes = cap_bytes,
            .next_index = std.atomic.Value(usize).init(0),
            .stop = std.atomic.Value(u8).init(0),
            .err = null,
            .err_mutex = .{},
        };

        const cpu = std.Thread.getCpuCount() catch 1;
        const requested = if (opts.thread_count) |v| if (v == 0) cpu else v else cpu;
        const capped = @min(requested, plan.len);
        const thread_count = if (opts.memory_mb != null) 1 else capped;
        if (thread_count <= 1) {
            volumeWorker(&volume_shared);
            if (volume_shared.err) |e| return e;
            return;
        }

        var threads = try arena_alloc.alloc(std.Thread, thread_count - 1);
        defer arena_alloc.free(threads);
        var t: usize = 0;
        while (t + 1 < thread_count) : (t += 1) {
            threads[t] = std.Thread.spawn(.{}, volumeWorker, .{&volume_shared}) catch {
                volume_shared.stop.store(1, .monotonic);
                break;
            };
        }
        volumeWorker(&volume_shared);
        t = 0;
        while (t + 1 < thread_count) : (t += 1) {
            threads[t].join();
        }
        if (volume_shared.err) |e| return e;
    }
}

pub fn createStreams(
    allocator: std.mem.Allocator,
    opts: common.CreateOptions,
    inputs: []const StreamInput,
) !void {
    if (opts.data_paths.len != 0) return error.InvalidInput;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var total_size: u64 = 0;
    var max_file_len: u64 = 0;
    for (inputs) |input| {
        total_size += input.length;
        if (input.length > max_file_len) max_file_len = input.length;
    }
    const block_size = if (opts.block_size) |v|
        v
    else if (opts.block_count) |c|
        core.create_plan.blockSizeFromCount(total_size, c)
    else
        core.heuristics.blockSizeHeuristic(total_size);
    const cap_bytes = try common.memoryCapBytes(opts.memory_mb);
    if (cap_bytes) |cap| {
        if (cap == 0) return error.InvalidInput;
        if (block_size > cap) return error.InvalidInput;
    }
    const data_blocks = if (block_size == 0) 0 else (total_size + block_size - 1) / block_size;
    const recovery_blocks = if (opts.recovery_blocks) |v|
        v
    else
        core.create_plan.recoveryBlocksFromPercent(data_blocks, opts.redundancy_percent orelse 0) catch return error.InvalidInput;

    const mute_defaults = opts.mute_defaults or common.envMuteDefaults();
    if (!mute_defaults) {
        if (opts.block_size == null and opts.block_count == null) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "default block size: {d}\n", .{block_size});
            try std.fs.File.stderr().writeAll(msg);
        }
        if (opts.recovery_blocks == null and opts.redundancy_percent != null) {
            var buf2: [128]u8 = undefined;
            const msg2 = try std.fmt.bufPrint(&buf2, "default redundancy percent: {d}\n", .{opts.redundancy_percent.?});
            try std.fs.File.stderr().writeAll(msg2);
        }
        var plan_buf: [256]u8 = undefined;
        const plan = try std.fmt.bufPrint(
            &plan_buf,
            "derived plan: total_size={d} block_size={d} data_blocks={d} recovery_blocks={d}\n",
            .{ total_size, block_size, data_blocks, recovery_blocks },
        );
        try std.fs.File.stderr().writeAll(plan);
    }

    const StreamFileMeta = struct {
        name: []const u8,
        length: u64,
        file_id: [16]u8,
        file_hash_16k: [16]u8,
        read_at: core.storage.StreamReadAt,
        ctx: *anyopaque,
    };

    var files = try arena_alloc.alloc(StreamFileMeta, inputs.len);
    var i: usize = 0;
    while (i < inputs.len) : (i += 1) {
        const input = inputs[i];
        const file_hash_16k = try common.md5First16kStream(input);
        const file_id = try core.file_id.fileIdFromHash16k(arena_alloc, file_hash_16k, input.length, input.name);
        files[i] = .{
            .name = input.name,
            .length = input.length,
            .file_id = file_id,
            .file_hash_16k = file_hash_16k,
            .read_at = input.read_at,
            .ctx = input.ctx,
        };
    }

    const less = struct {
        fn lt(_: void, a: StreamFileMeta, b: StreamFileMeta) bool {
            return std.mem.lessThan(u8, &a.file_id, &b.file_id);
        }
    }.lt;
    std.sort.insertion(StreamFileMeta, files, {}, less);

    var file_ids = try arena_alloc.alloc([16]u8, files.len);
    i = 0;
    while (i < files.len) : (i += 1) {
        file_ids[i] = files[i].file_id;
    }
    const main_body = try core.create_packets.buildMainBody(arena_alloc, block_size, file_ids);
    var recovery_set_id: [16]u8 = undefined;
    try core.md5.md5Digest(main_body, &recovery_set_id);

    const creator_text = "par2z 0.1.0";
    const creator_pkt = try core.create_packets.buildCreatorPacket(arena_alloc, recovery_set_id, creator_text);
    const main_pkt = try core.create_packets.buildMainPacket(arena_alloc, recovery_set_id, main_body);

    var main_packets = std.ArrayList([]const u8).empty;
    defer main_packets.deinit(arena_alloc);
    var volume_meta_packets = std.ArrayList([]const u8).empty;
    defer volume_meta_packets.deinit(arena_alloc);
    try main_packets.append(arena_alloc, main_pkt);
    if (opts.metadata) |meta| {
        if (files.len != 1) return error.InvalidInput;
        const meta_pkt = try core.create_packets.buildSourceMetadataPacket(arena_alloc, recovery_set_id, meta);
        try main_packets.append(arena_alloc, meta_pkt);
    }
    if (opts.validation_state) |state| {
        if (files.len != 1) return error.InvalidInput;
        var vs = state;
        vs.file_id = file_ids[0];
        const sfvs_pkt = try core.create_packets.buildValidationStatePacket(arena_alloc, recovery_set_id, vs);
        try main_packets.append(arena_alloc, sfvs_pkt);
    }
    if (opts.include_volume_meta) {
        try volume_meta_packets.append(arena_alloc, main_pkt);
    }
    if (opts.emit_packed) {
        const pkd_body = try core.create_packets.buildPackedMainBody(arena_alloc, block_size, block_size, file_ids, &.{});
        const pkd_pkt = try core.create_packets.buildPackedMainPacket(arena_alloc, recovery_set_id, pkd_body);
        try main_packets.append(arena_alloc, pkd_pkt);
    }
    if (opts.comment) |text| {
        if (common.isAscii(text)) {
            const comm = try core.create_packets.buildCommentAsciiPacket(arena_alloc, recovery_set_id, text);
            try main_packets.append(arena_alloc, comm);
        } else {
            const ascii = try common.transliterateAscii(arena_alloc, text);
            if (ascii) |ascii_text| {
                const comm = try core.create_packets.buildCommentAsciiPacket(arena_alloc, recovery_set_id, ascii_text);
                try main_packets.append(arena_alloc, comm);
                const commu = try core.create_packets.buildCommentUnicodePacketWithAscii(arena_alloc, recovery_set_id, text, ascii_text);
                try main_packets.append(arena_alloc, commu);
            } else {
                const commu = try core.create_packets.buildCommentUnicodePacket(arena_alloc, recovery_set_id, text);
                try main_packets.append(arena_alloc, commu);
            }
        }
    }
    try main_packets.append(arena_alloc, creator_pkt);

    const slice_size = std.math.cast(usize, block_size) orelse return error.InvalidInput;
    var file_infos = try arena_alloc.alloc(core.layout.FileInfo, files.len);
    i = 0;
    while (i < files.len) : (i += 1) {
        file_infos[i] = .{ .length = files[i].length };
    }

    var main_out = try common.openOutput(allocator, opts.par2_path, opts.output_open);
    defer main_out.close();
    for (main_packets.items) |pkt| {
        try main_out.writeAll(pkt);
    }

    i = 0;
    while (i < files.len) : (i += 1) {
        var file_arena = std.heap.ArenaAllocator.init(arena_alloc);
        defer file_arena.deinit();
        const temp_alloc = file_arena.allocator();
        const f = files[i];
        const info = try computeFileInfoAndMaybeWriteSlicesStream(
            temp_alloc,
            .{ .name = f.name, .length = f.length, .read_at = f.read_at, .ctx = f.ctx },
            f.file_id,
            recovery_set_id,
            slice_size,
            opts.include_input_slices,
            &main_out,
        );
        const filedesc_pkt = try core.create_packets.buildFileDescPacket(
            temp_alloc,
            recovery_set_id,
            f.file_id,
            info.file_hash,
            f.file_hash_16k,
            f.length,
            f.name,
        );
        try main_out.writeAll(filedesc_pkt);
        if (opts.include_volume_meta) {
            const copy = try arena_alloc.dupe(u8, filedesc_pkt);
            try volume_meta_packets.append(arena_alloc, copy);
        }
        const ifsc_pkt = try core.create_packets.buildIfscPacket(
            temp_alloc,
            recovery_set_id,
            f.file_id,
            info.ifsc_entries,
        );
        try main_out.writeAll(ifsc_pkt);
        if (opts.include_volume_meta) {
            const copy = try arena_alloc.dupe(u8, ifsc_pkt);
            try volume_meta_packets.append(arena_alloc, copy);
        }
        if (!common.isAscii(f.name)) {
            const uni_pkt = try core.create_packets.buildUnicodeFilenamePacket(temp_alloc, recovery_set_id, f.file_id, f.name);
            try main_out.writeAll(uni_pkt);
        }
    }
    if (opts.include_volume_meta) {
        try volume_meta_packets.append(arena_alloc, creator_pkt);
    }

    if (recovery_blocks > 0) {
        const offset = opts.first_recovery_block orelse 0;
        if (offset > std.math.maxInt(u32)) return error.InvalidInput;
        if (recovery_blocks > 0 and offset > std.math.maxInt(u32) - (recovery_blocks - 1)) return error.InvalidInput;
        var file_entries = try arena_alloc.alloc(core.storage.StreamEntry, files.len);
        i = 0;
        while (i < files.len) : (i += 1) {
            file_entries[i] = .{ .length = files[i].length, .read_at = files[i].read_at, .ctx = files[i].ctx };
        }
        const store = core.storage.StreamStore{ .files = file_entries };
        const plan = blk: {
            if (opts.recovery_file_count) |count| {
                if (count == 0 or count > recovery_blocks) return error.InvalidInput;
                if (opts.uniform_recovery) {
                    break :blk try core.create_plan.splitRecoveryBlocksUniform(arena_alloc, recovery_blocks, count);
                }
                break :blk try core.create_plan.splitRecoveryBlocksCounted(arena_alloc, recovery_blocks, count);
            }
            if (opts.uniform_recovery) {
                const count = core.create_plan.defaultVolumeCount(recovery_blocks);
                break :blk try core.create_plan.splitRecoveryBlocksUniform(arena_alloc, recovery_blocks, count);
            }
            if (opts.limit_recovery) {
                var max_blocks: u64 = 0;
                for (files) |f| {
                    const blocks = try core.slices.sliceCount(f.length, slice_size);
                    if (blocks > max_blocks) max_blocks = blocks;
                }
                break :blk try core.create_plan.splitRecoveryBlocksLimited(arena_alloc, recovery_blocks, max_blocks);
            }
            break :blk try core.create_plan.splitRecoveryBlocksDefault(arena_alloc, recovery_blocks);
        };
        if (plan.len == 0) return;
        const width = volumeIndexWidth(recovery_blocks, offset);

        var volume_shared = StreamVolumeShared{
            .volume_meta_packets = volume_meta_packets.items,
            .store = store,
            .file_infos = file_infos,
            .slice_size = slice_size,
            .plan = plan,
            .width = width,
            .offset = offset,
            .par2_path = opts.par2_path,
            .output_open = opts.output_open,
            .recovery_set_id = recovery_set_id,
            .emit_rfsc = opts.emit_rfsc,
            .emit_packed = opts.emit_packed,
            .include_volume_meta = opts.include_volume_meta,
            .cap_bytes = cap_bytes,
            .next_index = std.atomic.Value(usize).init(0),
            .stop = std.atomic.Value(u8).init(0),
            .err = null,
            .err_mutex = .{},
        };

        const cpu = std.Thread.getCpuCount() catch 1;
        const requested = if (opts.thread_count) |v| if (v == 0) cpu else v else cpu;
        const capped = @min(requested, plan.len);
        const thread_count = if (opts.memory_mb != null) 1 else capped;
        if (thread_count <= 1) {
            streamVolumeWorker(&volume_shared);
            if (volume_shared.err) |e| return e;
            return;
        }

        var threads = try arena_alloc.alloc(std.Thread, thread_count - 1);
        defer arena_alloc.free(threads);
        var t: usize = 0;
        while (t + 1 < thread_count) : (t += 1) {
            threads[t] = std.Thread.spawn(.{}, streamVolumeWorker, .{&volume_shared}) catch {
                volume_shared.stop.store(1, .monotonic);
                break;
            };
        }
        streamVolumeWorker(&volume_shared);
        t = 0;
        while (t + 1 < thread_count) : (t += 1) {
            threads[t].join();
        }
        if (volume_shared.err) |e| return e;
    }
}

fn fileMetaLessThan(_: void, a: FileMeta, b: FileMeta) bool {
    return std.mem.lessThan(u8, &a.file_id, &b.file_id);
}

fn collectCreateInputs(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    recurse: bool,
    basepath: ?[]const u8,
) ![]CreateInput {
    var list = std.ArrayList(CreateInput).empty;
    defer list.deinit(allocator);

    var base_abs: ?[]u8 = null;
    if (basepath) |bp| {
        const abs = try std.fs.cwd().realpathAlloc(allocator, bp);
        base_abs = abs;
    }
    if (base_abs) |abs| {
        base_abs = try allocator.dupe(u8, common.trimTrailingSeparators(abs));
    }

    for (inputs) |path| {
        const info = std.fs.cwd().statFile(path) catch continue;
        if (info.kind == .file) {
            const entry = try buildCreateInput(allocator, path, info.size, base_abs);
            if (entry) |value| try list.append(allocator, value);
            continue;
        }
        if (info.kind != .directory or !recurse) continue;
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |item| {
            if (item.kind != .file) continue;
            const full_path = try path_util.join(allocator, path, item.path);
            const file_info = std.fs.cwd().statFile(full_path) catch {
                allocator.free(full_path);
                continue;
            };
            const entry = try buildCreateInput(allocator, full_path, file_info.size, base_abs);
            if (entry) |value| {
                try list.append(allocator, value);
            } else {
                allocator.free(full_path);
            }
        }
    }

    if (list.items.len == 0) return error.InvalidInput;
    return list.toOwnedSlice(allocator);
}

fn buildCreateInput(
    allocator: std.mem.Allocator,
    path: []const u8,
    length: u64,
    base_abs: ?[]const u8,
) !?CreateInput {
    if (base_abs) |base| {
        const abs = try std.fs.cwd().realpathAlloc(allocator, path);
        const rel = try common.relativePathUnderBase(allocator, base, abs);
        if (rel == null) {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Ignoring out of basepath source file: {s}\n", .{abs});
            try common.infoFile().writeAll(msg);
            allocator.free(abs);
            return null;
        }
        allocator.free(abs);
        return .{
            .path = try allocator.dupe(u8, path),
            .name = rel.?,
            .length = length,
        };
    }
    const name = try common.safeFileName(path);
    return .{
        .path = try allocator.dupe(u8, path),
        .name = name,
        .length = length,
    };
}

fn computeFileInfoAndMaybeWriteSlices(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_id: [16]u8,
    recovery_set_id: [16]u8,
    slice_size: usize,
    include_input_slices: bool,
    writer: *OutputTarget,
) !FileInfoResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const info = try file.stat();
    const file_len = info.size;
    const slice_count = try core.slices.sliceCount(file_len, slice_size);
    var entries = try allocator.alloc(core.packet_types.IfscEntry, slice_count);
    var md5_ctx = core.md5.Md5Ctx.init(.{});

    var slice_buf = try allocator.alloc(u8, slice_size);
    defer allocator.free(slice_buf);
    var slice_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer slice_arena.deinit();

    var remaining = file_len;
    var slice_index: usize = 0;
    while (slice_index < slice_count) : (slice_index += 1) {
        const chunk_len = @min(remaining, slice_size);
        if (chunk_len > 0) {
            const n = try file.readAll(slice_buf[0..@as(usize, @intCast(chunk_len))]);
            if (n != chunk_len) return error.InvalidInput;
            md5_ctx.update(slice_buf[0..@as(usize, @intCast(chunk_len))]);
            remaining -= chunk_len;
        }
        if (chunk_len < slice_size) {
            @memset(slice_buf[@as(usize, @intCast(chunk_len))..], 0);
        }
        try core.md5.md5Digest(slice_buf, &entries[slice_index].md5);
        entries[slice_index].crc32 = core.crc32.crc32(slice_buf);
        if (include_input_slices) {
            const pkt = try core.create_packets.buildFileSlicPacket(
                slice_arena.allocator(),
                recovery_set_id,
                file_id,
                @as(u64, @intCast(slice_index)),
                slice_buf,
            );
            try writer.writeAll(pkt);
            _ = slice_arena.reset(.retain_capacity);
        }
    }
    var file_hash: [16]u8 = undefined;
    md5_ctx.final(&file_hash);
    return .{ .file_hash = file_hash, .ifsc_entries = entries };
}

fn computeFileInfoAndMaybeWriteSlicesStream(
    allocator: std.mem.Allocator,
    input: StreamInput,
    file_id: [16]u8,
    recovery_set_id: [16]u8,
    slice_size: usize,
    include_input_slices: bool,
    writer: *OutputTarget,
) !FileInfoResult {
    const slice_count = try core.slices.sliceCount(input.length, slice_size);
    var entries = try allocator.alloc(core.packet_types.IfscEntry, slice_count);
    var md5_ctx = core.md5.Md5Ctx.init(.{});

    var slice_buf = try allocator.alloc(u8, slice_size);
    defer allocator.free(slice_buf);
    var slice_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer slice_arena.deinit();

    var remaining = input.length;
    var slice_index: usize = 0;
    while (slice_index < slice_count) : (slice_index += 1) {
        const mul = @mulWithOverflow(slice_index, slice_size);
        if (mul[1] != 0) return error.InvalidInput;
        const offset = mul[0];
        const chunk_len = @min(remaining, @as(u64, @intCast(slice_size)));
        if (chunk_len > 0) {
            try common.readAtExact(input.read_at, input.ctx, @as(u64, @intCast(offset)), slice_buf[0..@as(usize, @intCast(chunk_len))]);
            md5_ctx.update(slice_buf[0..@as(usize, @intCast(chunk_len))]);
            remaining -= chunk_len;
        }
        if (chunk_len < slice_size) {
            @memset(slice_buf[@as(usize, @intCast(chunk_len))..], 0);
        }
        try core.md5.md5Digest(slice_buf, &entries[slice_index].md5);
        entries[slice_index].crc32 = core.crc32.crc32(slice_buf);
        if (include_input_slices) {
            const pkt = try core.create_packets.buildFileSlicPacket(
                slice_arena.allocator(),
                recovery_set_id,
                file_id,
                @as(u64, @intCast(slice_index)),
                slice_buf,
            );
            try writer.writeAll(pkt);
            _ = slice_arena.reset(.retain_capacity);
        }
    }
    var file_hash: [16]u8 = undefined;
    md5_ctx.final(&file_hash);
    return .{ .file_hash = file_hash, .ifsc_entries = entries };
}

fn volumePath(allocator: std.mem.Allocator, par2_path: []const u8, start: u64, count: u64, width: usize) ![]const u8 {
    var base = par2_path;
    if (std.mem.endsWith(u8, par2_path, ".par2")) {
        base = par2_path[0 .. par2_path.len - 5];
    }
    const start_s = try indexPadded(allocator, start, width);
    var count_buf: [32]u8 = undefined;
    const count_s = try std.fmt.bufPrint(&count_buf, "{d}", .{count});
    const suffix = try std.mem.concat(allocator, u8, &.{ ".vol", start_s, "+", count_s, ".par2" });
    return try std.mem.concat(allocator, u8, &.{ base, suffix });
}

fn volumeIndexWidth(total: u64, first: u64) usize {
    if (total == 0) return 1;
    var max_index = first;
    if (total > 0) {
        const add = total - 1;
        const sum = @addWithOverflow(first, add);
        if (sum[1] == 0) max_index = sum[0];
    }
    var digits_total: usize = 0;
    var t = total;
    while (t > 0) : (t /= 10) {
        digits_total += 1;
    }
    var digits_max: usize = 0;
    t = max_index;
    while (t > 0) : (t /= 10) {
        digits_max += 1;
    }
    if (digits_total == 0) digits_total = 1;
    if (digits_max == 0) digits_max = 1;
    return if (digits_total > digits_max) digits_total else digits_max;
}

fn indexPadded(allocator: std.mem.Allocator, value: u64, width: usize) ![]const u8 {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    if (s.len >= width) return allocator.dupe(u8, s);
    const out = try allocator.alloc(u8, width);
    const pad_len = width - s.len;
    @memset(out[0..pad_len], '0');
    @memcpy(out[pad_len..], s);
    return out;
}

test "volumeIndexWidth uses max of total and last index digits" {
    try std.testing.expectEqual(@as(usize, 1), volumeIndexWidth(0, 0));
    try std.testing.expectEqual(@as(usize, 1), volumeIndexWidth(1, 0));
    try std.testing.expectEqual(@as(usize, 2), volumeIndexWidth(10, 5));
    try std.testing.expectEqual(@as(usize, 4), volumeIndexWidth(1000, 0));
    try std.testing.expectEqual(@as(usize, 2), volumeIndexWidth(1, 12));
}

test "volumePath formats base and padded start index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try volumePath(arena.allocator(), "set.par2", 7, 3, 4);
    try std.testing.expectEqualStrings("set.vol0007+3.par2", out);
    const out2 = try volumePath(arena.allocator(), "set", 7, 3, 2);
    try std.testing.expectEqualStrings("set.vol07+3.par2", out2);
}

const VolumeShared = struct {
    volume_meta_packets: []const []const u8,
    store: core.storage.FileStore,
    file_infos: []const core.layout.FileInfo,
    slice_size: usize,
    plan: []const core.create_plan.VolumePlan,
    width: usize,
    offset: u64,
    par2_path: []const u8,
    output_open: ?OutputOpener,
    recovery_set_id: [16]u8,
    emit_rfsc: bool,
    emit_packed: bool,
    include_volume_meta: bool,
    cap_bytes: ?u64,
    next_index: std.atomic.Value(usize),
    stop: std.atomic.Value(u8),
    err: ?anyerror,
    err_mutex: std.Thread.Mutex,
};

fn volumeWorker(shared: *VolumeShared) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (shared.stop.load(.monotonic) == 0) {
        const idx = shared.next_index.fetchAdd(1, .monotonic);
        if (idx >= shared.plan.len) return;
        const vol = shared.plan[idx];
        buildVolume(
            arena.allocator(),
            shared.volume_meta_packets,
            shared.store,
            shared.file_infos,
            shared.slice_size,
            vol,
            shared.width,
            shared.offset,
            shared.par2_path,
            shared.output_open,
            shared.recovery_set_id,
            shared.emit_rfsc,
            shared.emit_packed,
            shared.include_volume_meta,
            shared.cap_bytes,
            false,
        ) catch |e| {
            setVolumeError(shared, e);
            return;
        };
    }
}

const StreamVolumeShared = struct {
    volume_meta_packets: []const []const u8,
    store: core.storage.StreamStore,
    file_infos: []const core.layout.FileInfo,
    slice_size: usize,
    plan: []const core.create_plan.VolumePlan,
    width: usize,
    offset: u64,
    par2_path: []const u8,
    output_open: ?OutputOpener,
    recovery_set_id: [16]u8,
    emit_rfsc: bool,
    emit_packed: bool,
    include_volume_meta: bool,
    cap_bytes: ?u64,
    next_index: std.atomic.Value(usize),
    stop: std.atomic.Value(u8),
    err: ?anyerror,
    err_mutex: std.Thread.Mutex,
};

fn streamVolumeWorker(shared: *StreamVolumeShared) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (shared.stop.load(.monotonic) == 0) {
        const idx = shared.next_index.fetchAdd(1, .monotonic);
        if (idx >= shared.plan.len) return;
        const vol = shared.plan[idx];
        buildVolumeStream(
            arena.allocator(),
            shared.volume_meta_packets,
            shared.store,
            shared.file_infos,
            shared.slice_size,
            vol,
            shared.width,
            shared.offset,
            shared.par2_path,
            shared.output_open,
            shared.recovery_set_id,
            shared.emit_rfsc,
            shared.emit_packed,
            shared.include_volume_meta,
            shared.cap_bytes,
            false,
        ) catch |err| {
            shared.err_mutex.lock();
            defer shared.err_mutex.unlock();
            if (shared.err == null) shared.err = err;
            shared.stop.store(1, .monotonic);
            return;
        };
    }
}

fn setVolumeError(shared: *VolumeShared, err: anyerror) void {
    shared.err_mutex.lock();
    defer shared.err_mutex.unlock();
    if (shared.err == null) shared.err = err;
    shared.stop.store(1, .monotonic);
}

fn buildVolume(
    allocator: std.mem.Allocator,
    volume_meta_packets: []const []const u8,
    store: core.storage.FileStore,
    file_infos: []const core.layout.FileInfo,
    slice_size: usize,
    vol: core.create_plan.VolumePlan,
    width: usize,
    offset: u64,
    par2_path: []const u8,
    output_open: ?OutputOpener,
    recovery_set_id: [16]u8,
    emit_rfsc: bool,
    emit_packed: bool,
    include_volume_meta: bool,
    cap_bytes: ?u64,
    parallel_slices: bool,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var limited: common.LimitedAllocator = undefined;
    var tmp_alloc = gpa.allocator();
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(tmp_alloc, @intCast(cap));
        tmp_alloc = limited.allocator();
    }

    const add = @addWithOverflow(vol.start, offset);
    if (add[1] != 0) return error.InvalidInput;
    const vol_start = add[0];
    const vol_path = try volumePath(allocator, par2_path, vol_start, vol.count, width);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var vol_out: ?OutputTarget = null;
    if (output_open == null) {
        vol_out = try common.openFileOutput(allocator, vol_path);
    }
    var byte_offset: usize = 0;
    const count_usize = std.math.cast(usize, vol.count) orelse return error.InvalidInput;
    var exponents = try tmp_alloc.alloc(u32, count_usize);
    defer tmp_alloc.free(exponents);
    var r: usize = 0;
    while (r < count_usize) : (r += 1) {
        const exp_idx = vol_start + r;
        exponents[r] = core.gf16.exponentForIndex(@as(u32, @intCast(exp_idx)));
    }
    const rec_slices = if (parallel_slices)
        try core.block_api.computeRecoverySlicesFileStoreBatchParallel(tmp_alloc, store, file_infos, slice_size, exponents)
    else
        try core.block_api.computeRecoverySlicesFileStoreBatch(tmp_alloc, store, file_infos, slice_size, exponents);
    defer {
        var i: usize = 0;
        while (i < rec_slices.len) : (i += 1) {
            tmp_alloc.free(rec_slices[i]);
        }
        tmp_alloc.free(rec_slices);
    }
    var rfsc_entries = std.ArrayList(core.packet_types.RfscEntry).empty;
    defer rfsc_entries.deinit(allocator);
    r = 0;
    while (r < count_usize) : (r += 1) {
        const exp = exponents[r];
        const rec_slice = rec_slices[r];
        const pkt = try core.create_packets.buildRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
        if (output_open != null) {
            try buffer.appendSlice(allocator, pkt);
        } else {
            try vol_out.?.writeAll(pkt);
        }
        byte_offset += pkt.len;
        if (emit_rfsc) {
            var entry: core.packet_types.RfscEntry = undefined;
            try core.md5.md5Digest(rec_slice, &entry.md5);
            entry.crc32 = core.crc32.crc32(rec_slice);
            entry.exponent = exp;
            try rfsc_entries.append(allocator, entry);
        }
        if (emit_packed) {
            const pkd_pkt = try core.create_packets.buildPackedRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
            if (output_open != null) {
                try buffer.appendSlice(allocator, pkd_pkt);
            } else {
                try vol_out.?.writeAll(pkd_pkt);
            }
            byte_offset += pkd_pkt.len;
        }
    }
    var rfsc_offset: ?usize = null;
    if (emit_rfsc) {
        if (byte_offset >= 16384) {
            const file_id: [16]u8 = .{0} ** 16;
            const rfsc_pkt = try core.create_packets.buildRfscPacket(allocator, recovery_set_id, file_id, rfsc_entries.items);
            rfsc_offset = byte_offset;
            if (output_open != null) {
                try buffer.appendSlice(allocator, rfsc_pkt);
            } else {
                try vol_out.?.writeAll(rfsc_pkt);
            }
            byte_offset += rfsc_pkt.len;
        }
    }
    if (include_volume_meta) {
        for (volume_meta_packets) |pkt| {
            if (output_open != null) {
                try buffer.appendSlice(allocator, pkt);
            } else {
                try vol_out.?.writeAll(pkt);
            }
            byte_offset += pkt.len;
        }
    }
    if (emit_rfsc and rfsc_offset != null) {
        if (output_open != null) {
            try patchRfscFileIdBytes(allocator, buffer.items, rfsc_offset.?, path_util.baseName(vol_path));
        } else {
            try patchRfscFileId(vol_path, rfsc_offset.?);
        }
    }
    if (output_open != null) {
        const out = try common.openOutput(allocator, vol_path, output_open);
        var out_copy = out;
        defer out_copy.close();
        try out_copy.writeAll(buffer.items);
    } else if (vol_out) |*out| {
        out.close();
    }
}

fn buildVolumeStream(
    allocator: std.mem.Allocator,
    volume_meta_packets: []const []const u8,
    store: core.storage.StreamStore,
    file_infos: []const core.layout.FileInfo,
    slice_size: usize,
    vol: core.create_plan.VolumePlan,
    width: usize,
    offset: u64,
    par2_path: []const u8,
    output_open: ?OutputOpener,
    recovery_set_id: [16]u8,
    emit_rfsc: bool,
    emit_packed: bool,
    include_volume_meta: bool,
    cap_bytes: ?u64,
    parallel_slices: bool,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var limited: common.LimitedAllocator = undefined;
    var tmp_alloc = gpa.allocator();
    if (cap_bytes) |cap| {
        limited = common.LimitedAllocator.init(tmp_alloc, @intCast(cap));
        tmp_alloc = limited.allocator();
    }

    const add = @addWithOverflow(vol.start, offset);
    if (add[1] != 0) return error.InvalidInput;
    const vol_start = add[0];
    const vol_path = try volumePath(allocator, par2_path, vol_start, vol.count, width);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var vol_out: ?OutputTarget = null;
    if (output_open == null) {
        vol_out = try common.openFileOutput(allocator, vol_path);
    }
    var byte_offset: usize = 0;
    const count_usize = std.math.cast(usize, vol.count) orelse return error.InvalidInput;
    var exponents = try tmp_alloc.alloc(u32, count_usize);
    defer tmp_alloc.free(exponents);
    var r: usize = 0;
    while (r < count_usize) : (r += 1) {
        const exp_idx = vol_start + r;
        exponents[r] = core.gf16.exponentForIndex(@as(u32, @intCast(exp_idx)));
    }
    const rec_slices = if (parallel_slices)
        try core.block_api.computeRecoverySlicesStreamStoreBatchParallel(tmp_alloc, store, file_infos, slice_size, exponents)
    else
        try core.block_api.computeRecoverySlicesStreamStoreBatch(tmp_alloc, store, file_infos, slice_size, exponents);
    defer {
        var i: usize = 0;
        while (i < rec_slices.len) : (i += 1) {
            tmp_alloc.free(rec_slices[i]);
        }
        tmp_alloc.free(rec_slices);
    }
    var rfsc_entries = std.ArrayList(core.packet_types.RfscEntry).empty;
    defer rfsc_entries.deinit(allocator);
    r = 0;
    while (r < count_usize) : (r += 1) {
        const exp = exponents[r];
        const rec_slice = rec_slices[r];
        const pkt = try core.create_packets.buildRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
        if (output_open != null) {
            try buffer.appendSlice(allocator, pkt);
        } else {
            try vol_out.?.writeAll(pkt);
        }
        byte_offset += pkt.len;
        if (emit_rfsc) {
            var entry: core.packet_types.RfscEntry = undefined;
            try core.md5.md5Digest(rec_slice, &entry.md5);
            entry.crc32 = core.crc32.crc32(rec_slice);
            entry.exponent = exp;
            try rfsc_entries.append(allocator, entry);
        }
        if (emit_packed) {
            const pkd_pkt = try core.create_packets.buildPackedRecvSlicPacket(allocator, recovery_set_id, exp, rec_slice);
            if (output_open != null) {
                try buffer.appendSlice(allocator, pkd_pkt);
            } else {
                try vol_out.?.writeAll(pkd_pkt);
            }
            byte_offset += pkd_pkt.len;
        }
    }
    var rfsc_offset: ?usize = null;
    if (emit_rfsc) {
        if (byte_offset >= 16384) {
            const file_id: [16]u8 = .{0} ** 16;
            const rfsc_pkt = try core.create_packets.buildRfscPacket(allocator, recovery_set_id, file_id, rfsc_entries.items);
            rfsc_offset = byte_offset;
            if (output_open != null) {
                try buffer.appendSlice(allocator, rfsc_pkt);
            } else {
                try vol_out.?.writeAll(rfsc_pkt);
            }
            byte_offset += rfsc_pkt.len;
        }
    }
    if (include_volume_meta) {
        for (volume_meta_packets) |pkt| {
            if (output_open != null) {
                try buffer.appendSlice(allocator, pkt);
            } else {
                try vol_out.?.writeAll(pkt);
            }
            byte_offset += pkt.len;
        }
    }
    if (emit_rfsc and rfsc_offset != null) {
        if (output_open != null) {
            try patchRfscFileIdBytes(allocator, buffer.items, rfsc_offset.?, path_util.baseName(vol_path));
        } else {
            try patchRfscFileId(vol_path, rfsc_offset.?);
        }
    }
    if (output_open != null) {
        const out = try common.openOutput(allocator, vol_path, output_open);
        var out_copy = out;
        defer out_copy.close();
        try out_copy.writeAll(buffer.items);
    } else if (vol_out) |*out| {
        out.close();
    }
}

fn patchRfscFileId(path: []const u8, rfsc_offset: usize) !void {
    if (rfsc_offset < 16384) return;
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const info = try file.stat();
    const length = info.size;
    var buf: [16384]u8 = undefined;
    const read_len = @min(@as(u64, buf.len), length);
    _ = try file.readAll(buf[0..@as(usize, @intCast(read_len))]);
    var md5_16k: [16]u8 = undefined;
    try core.md5.md5Digest(buf[0..@as(usize, @intCast(read_len))], &md5_16k);
    const name = path_util.baseName(path);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const file_id = try core.file_id.fileIdFromHash16k(arena.allocator(), md5_16k, length, name);
    try file.seekTo(@as(u64, @intCast(rfsc_offset)));
    var header: [64]u8 = undefined;
    _ = try file.readAll(&header);
    const pkt_len = core.bytes.readU64Le(&header, 8) catch return error.InvalidInput;
    if (pkt_len < 64) return error.InvalidInput;
    var packet = try arena.allocator().alloc(u8, @as(usize, @intCast(pkt_len)));
    @memcpy(packet[0..64], &header);
    if (pkt_len > 64) {
        _ = try file.readAll(packet[64..]);
    }
    @memcpy(packet[64..80], &file_id);
    var digest: [16]u8 = undefined;
    try core.md5.md5Digest(packet[32..], &digest);
    @memcpy(packet[16..32], &digest);
    try file.seekTo(@as(u64, @intCast(rfsc_offset)));
    try file.writeAll(packet);
}

fn patchRfscFileIdBytes(allocator: std.mem.Allocator, data: []u8, rfsc_offset: usize, name: []const u8) !void {
    if (rfsc_offset < 16384) return;
    if (rfsc_offset + 64 > data.len) return error.InvalidInput;
    var md5_16k: [16]u8 = undefined;
    const read_len = @min(@as(usize, 16384), data.len);
    try core.md5.md5Digest(data[0..read_len], &md5_16k);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const file_id = try core.file_id.fileIdFromHash16k(arena.allocator(), md5_16k, data.len, name);

    const header = data[rfsc_offset .. rfsc_offset + 64];
    const pkt_len = core.bytes.readU64Le(header, 8) catch return error.InvalidInput;
    if (pkt_len < 64) return error.InvalidInput;
    const end = rfsc_offset + @as(usize, @intCast(pkt_len));
    if (end > data.len) return error.InvalidInput;
    var packet = data[rfsc_offset..end];
    @memcpy(packet[64..80], &file_id);
    var digest: [16]u8 = undefined;
    try core.md5.md5Digest(packet[32..], &digest);
    @memcpy(packet[16..32], &digest);
}
