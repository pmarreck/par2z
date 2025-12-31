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
    return .{
        .slice_size = main.slice_size,
        .recovery_files = recovery,
        .non_recovery_files = non_recovery,
    };
}

pub fn attachFileDesc(set: *RecoverySet, desc: types.FileDescPacket) RecoverySetError!void {
    if (try attachFileDescList(set.recovery_files, desc)) return;
    if (try attachFileDescList(set.non_recovery_files, desc)) return;
    return error.NotFound;
}

fn attachFileDescList(list: []FileEntry, desc: types.FileDescPacket) RecoverySetError!bool {
    for (list) |*entry| {
        if (std.mem.eql(u8, &entry.id, &desc.file_id)) {
            entry.desc = desc;
            return true;
        }
    }
    return false;
}

pub fn attachIfsc(set: *RecoverySet, ifsc: types.IfscPacket) RecoverySetError!void {
    if (try attachIfscList(set.recovery_files, ifsc)) return;
    if (try attachIfscList(set.non_recovery_files, ifsc)) return;
    return error.NotFound;
}

fn attachIfscList(list: []FileEntry, ifsc: types.IfscPacket) RecoverySetError!bool {
    for (list) |*entry| {
        if (std.mem.eql(u8, &entry.id, &ifsc.file_id)) {
            entry.ifsc = ifsc;
            return true;
        }
    }
    return false;
}
