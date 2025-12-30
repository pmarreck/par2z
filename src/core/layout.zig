const std = @import("std");
const slices = @import("slices.zig");

pub const LayoutError = error{
	OutOfMemory,
	InvalidInput,
	Overflow,
};

pub const FileInfo = struct {
	length: u64,
};

pub const SliceRef = struct {
	file_index: usize,
	slice_index: usize,
	offset: u64,
	length: usize,
};

pub fn buildSliceOrder(allocator: std.mem.Allocator, files: []const FileInfo, slice_size: usize) LayoutError![]SliceRef {
	if (slice_size == 0) return error.InvalidInput;
	var total: usize = 0;
	for (files) |f| {
		const count = slices.sliceCount(f.length, slice_size) catch return error.InvalidInput;
		const add = @addWithOverflow(total, count);
		if (add[1] != 0) return error.Overflow;
		total = add[0];
	}
	var refs = try allocator.alloc(SliceRef, total);
	var out_i: usize = 0;
	var file_i: usize = 0;
	while (file_i < files.len) : (file_i += 1) {
		const f = files[file_i];
		const count = slices.sliceCount(f.length, slice_size) catch return error.InvalidInput;
		var slice_i: usize = 0;
		while (slice_i < count) : (slice_i += 1) {
			const offset = @as(u64, @intCast(slice_i)) * @as(u64, @intCast(slice_size));
			var len: usize = slice_size;
			if (offset + @as(u64, @intCast(slice_size)) > f.length) {
				len = @as(usize, @intCast(f.length - offset));
			}
			refs[out_i] = .{ .file_index = file_i, .slice_index = slice_i, .offset = offset, .length = len };
			out_i += 1;
		}
	}
	return refs;
}
