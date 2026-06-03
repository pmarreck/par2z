const std = @import("std");
const types = @import("packet_types.zig");

pub const RecoverySetError = error{
    OutOfMemory,
    NotFound,
};

pub const FileEntry = struct {
    id: [16]u8,
    desc: ?types.FileDescPacket,
    ifsc: ?types.IfscPacket,
};

pub const RecoverySet = struct {
    slice_size: u64,
    recovery_files: []FileEntry,
    non_recovery_files: []FileEntry,
    /// file_id -> entry lookup so attaching FileDesc/IFSC packets during
    /// archive parse is O(1) instead of O(files) per packet (O(files^2) total).
    /// Entries point into the stable `recovery_files`/`non_recovery_files`
    /// allocations, which are never resized after construction.
    id_to_entry: std.AutoHashMap([16]u8, *FileEntry),
};

pub fn buildRecoverySet(allocator: std.mem.Allocator, main: types.MainPacket) RecoverySetError!RecoverySet {
    var recovery = try allocator.alloc(FileEntry, main.recovery_file_ids.len);
    var i: usize = 0;
    while (i < main.recovery_file_ids.len) : (i += 1) {
        recovery[i] = .{ .id = main.recovery_file_ids[i], .desc = null, .ifsc = null };
    }
    var non_recovery = try allocator.alloc(FileEntry, main.non_recovery_file_ids.len);
    var j: usize = 0;
    while (j < main.non_recovery_file_ids.len) : (j += 1) {
        non_recovery[j] = .{ .id = main.non_recovery_file_ids[j], .desc = null, .ifsc = null };
    }

    var id_to_entry = std.AutoHashMap([16]u8, *FileEntry).init(allocator);
    try id_to_entry.ensureTotalCapacity(@as(u32, @intCast(recovery.len + non_recovery.len)));
    for (recovery) |*entry| id_to_entry.putAssumeCapacity(entry.id, entry);
    for (non_recovery) |*entry| id_to_entry.putAssumeCapacity(entry.id, entry);

    return .{
        .slice_size = main.slice_size,
        .recovery_files = recovery,
        .non_recovery_files = non_recovery,
        .id_to_entry = id_to_entry,
    };
}

pub fn attachFileDesc(set: *RecoverySet, desc: types.FileDescPacket) RecoverySetError!void {
    const entry = set.id_to_entry.get(desc.file_id) orelse return error.NotFound;
    entry.desc = desc;
}

pub fn attachIfsc(set: *RecoverySet, ifsc: types.IfscPacket) RecoverySetError!void {
    const entry = set.id_to_entry.get(ifsc.file_id) orelse return error.NotFound;
    entry.ifsc = ifsc;
}
