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
