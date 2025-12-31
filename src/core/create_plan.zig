const std = @import("std");

pub fn blockSizeFromCount(total_size: u64, block_count: u64) u64 {
    if (block_count == 0) return 4;
    var size = total_size / block_count;
    if ((total_size % block_count) != 0) size += 1;
    if (size < 4) size = 4;
    if ((size % 4) != 0) size = (size + 3) / 4 * 4;
    return size;
}

pub const RecoveryPlanError = error{
    Overflow,
};

pub fn recoveryBlocksFromPercent(data_blocks: u64, percent: u64) RecoveryPlanError!u64 {
    if (percent == 0 or data_blocks == 0) return 0;
    const prod = @mulWithOverflow(data_blocks, percent);
    if (prod[1] != 0) return error.Overflow;
    var blocks = prod[0] / 100;
    if ((prod[0] % 100) != 0) blocks += 1;
    if (blocks == 0) blocks = 1;
    return blocks;
}

pub const VolumePlan = struct {
    start: u64,
    count: u64,
};

pub fn defaultVolumeCount(total: u64) usize {
    if (total == 0) return 0;
    var remaining = total;
    var group: u64 = 1;
    var count: usize = 0;
    while (remaining > 0) {
        if (group > remaining) group = remaining;
        count += 1;
        remaining -= group;
        group *= 2;
    }
    return count;
}

pub fn splitRecoveryBlocksDefault(allocator: std.mem.Allocator, total: u64) ![]VolumePlan {
    if (total == 0) return allocator.alloc(VolumePlan, 0);
    var list = std.ArrayList(VolumePlan).empty;
    defer list.deinit(allocator);
    var remaining = total;
    var start: u64 = 0;
    var group: u64 = 1;
    while (remaining > 0) {
        if (group > remaining) group = remaining;
        try list.append(allocator, .{ .start = start, .count = group });
        start += group;
        remaining -= group;
        group *= 2;
    }
    return list.toOwnedSlice(allocator);
}

pub fn splitRecoveryBlocksUniform(allocator: std.mem.Allocator, total: u64, file_count: u64) ![]VolumePlan {
    if (total == 0) return allocator.alloc(VolumePlan, 0);
    if (file_count == 0 or file_count > total) return error.InvalidInput;
    var list = std.ArrayList(VolumePlan).empty;
    defer list.deinit(allocator);
    const base = total / file_count;
    const extra = total % file_count;
    var start: u64 = 0;
    var i: u64 = 0;
    while (i < file_count) : (i += 1) {
        var count = base;
        if (i < extra) count += 1;
        if (count == 0) continue;
        try list.append(allocator, .{ .start = start, .count = count });
        start += count;
    }
    return list.toOwnedSlice(allocator);
}

pub fn splitRecoveryBlocksLimited(allocator: std.mem.Allocator, total: u64, limit: u64) ![]VolumePlan {
    if (total == 0) return allocator.alloc(VolumePlan, 0);
    if (limit == 0 or limit >= total) return splitRecoveryBlocksDefault(allocator, total);
    const buckets = total / limit;
    if (buckets <= 1) return splitRecoveryBlocksDefault(allocator, total);
    const limit_count = buckets - 1;
    const remaining = total - (limit_count * limit);
    var list = std.ArrayList(VolumePlan).empty;
    defer list.deinit(allocator);
    const head = try splitRecoveryBlocksDefault(allocator, remaining);
    defer allocator.free(head);
    var start: u64 = 0;
    for (head) |vol| {
        try list.append(allocator, .{ .start = start, .count = vol.count });
        start += vol.count;
    }
    var i: u64 = 0;
    while (i < limit_count) : (i += 1) {
        try list.append(allocator, .{ .start = start, .count = limit });
        start += limit;
    }
    return list.toOwnedSlice(allocator);
}

pub fn splitRecoveryBlocksCounted(allocator: std.mem.Allocator, total: u64, file_count: u64) ![]VolumePlan {
    if (total == 0) return allocator.alloc(VolumePlan, 0);
    if (file_count == 0) return error.InvalidInput;
    if (file_count > @as(u64, @intCast(defaultVolumeCount(total)))) return error.InvalidInput;
    if (file_count == 1) {
        var list = std.ArrayList(VolumePlan).empty;
        defer list.deinit(allocator);
        try list.append(allocator, .{ .start = 0, .count = total });
        return list.toOwnedSlice(allocator);
    }
    const shift = file_count - 1;
    if (shift >= 63) return error.InvalidInput;
    const denom = (@as(u64, 1) << @intCast(shift)) - 1;
    if (denom == 0) return error.InvalidInput;
    const max_start = total / denom;
    if (max_start == 0) return error.InvalidInput;
    var g: u64 = 1;
    while ((g << 1) <= max_start) : (g <<= 1) {}
    var list = std.ArrayList(VolumePlan).empty;
    defer list.deinit(allocator);
    var start: u64 = 0;
    var i: u64 = 0;
    while (i + 1 < file_count) : (i += 1) {
        const count = g << @intCast(i);
        try list.append(allocator, .{ .start = start, .count = count });
        start += count;
    }
    const remaining = total - (g * denom);
    try list.append(allocator, .{ .start = start, .count = remaining });
    return list.toOwnedSlice(allocator);
}
