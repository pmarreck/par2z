const std = @import("std");
const crc32 = @import("crc32.zig");
const md5 = @import("md5.zig");
const types = @import("packet_types.zig");

pub const SliceError = error{
	OutOfMemory,
	CryptoUnavailable,
	InvalidSliceSize,
	Mismatch,
};

pub fn sliceCount(file_length: u64, slice_size: usize) SliceError!usize {
	if (slice_size == 0) return error.InvalidSliceSize;
	const len = std.math.cast(usize, file_length) orelse return error.InvalidSliceSize;
	const add = @addWithOverflow(len, slice_size - 1);
	if (add[1] != 0) return error.InvalidSliceSize;
	return add[0] / slice_size;
}

pub fn computeIfscEntries(allocator: std.mem.Allocator, data: []const u8, slice_size: usize) SliceError![]types.IfscEntry {
	if (slice_size == 0) return error.InvalidSliceSize;
	const slice_count = (data.len + slice_size - 1) / slice_size;
	var entries = try allocator.alloc(types.IfscEntry, slice_count);
	var i: usize = 0;
	while (i < slice_count) : (i += 1) {
		const start = i * slice_size;
		const end = @min(start + slice_size, data.len);
		const chunk = data[start..end];
		if (chunk.len == slice_size) {
			computeIfscEntry(chunk, &entries[i]) catch return error.CryptoUnavailable;
		} else {
			var tmp = try allocator.alloc(u8, slice_size);
			defer allocator.free(tmp);
			@memset(tmp, 0);
			@memcpy(tmp[0..chunk.len], chunk);
			computeIfscEntry(tmp, &entries[i]) catch return error.CryptoUnavailable;
		}
	}
	return entries;
}

pub fn computeIfscEntry(slice: []const u8, out: *types.IfscEntry) SliceError!void {
	md5.md5Digest(slice, &out.md5) catch return error.CryptoUnavailable;
	out.crc32 = crc32.crc32(slice);
}

pub fn verifyIfsc(computed: []const types.IfscEntry, expected: []const types.IfscEntry) SliceError!void {
	if (computed.len != expected.len) return error.Mismatch;
	var i: usize = 0;
	while (i < computed.len) : (i += 1) {
		if (!std.mem.eql(u8, &computed[i].md5, &expected[i].md5)) return error.Mismatch;
		if (computed[i].crc32 != expected[i].crc32) return error.Mismatch;
	}
}

pub fn findMismatchedSlices(allocator: std.mem.Allocator, computed: []const types.IfscEntry, expected: []const types.IfscEntry) SliceError![]usize {
	if (computed.len != expected.len) return error.Mismatch;
	var out = try allocator.alloc(usize, computed.len);
	var count: usize = 0;
	var i: usize = 0;
	while (i < computed.len) : (i += 1) {
		if (!std.mem.eql(u8, &computed[i].md5, &expected[i].md5) or computed[i].crc32 != expected[i].crc32) {
			out[count] = i;
			count += 1;
		}
	}
	return out[0..count];
}
