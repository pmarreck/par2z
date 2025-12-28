const std = @import("std");

pub const StoreError = error{
	InvalidIndex,
	InvalidSliceSize,
	OutOfBounds,
	OutOfMemory,
	Overflow,
	IoError,
};

pub const MemoryStore = struct {
	files: []const []const u8,

	pub fn readSlice(self: MemoryStore, allocator: std.mem.Allocator, file_index: usize, slice_size: usize, slice_index: usize) StoreError![]u8 {
		if (slice_size == 0) return error.InvalidSliceSize;
		if (file_index >= self.files.len) return error.InvalidIndex;
		const file = self.files[file_index];
		const mul = @mulWithOverflow(slice_index, slice_size);
		if (mul[1] != 0) return error.Overflow;
		const offset = mul[0];
		if (offset >= file.len) return error.OutOfBounds;
		const end = @min(offset + slice_size, file.len);
		var out = try allocator.alloc(u8, slice_size);
		@memset(out, 0);
		@memcpy(out[0 .. end - offset], file[offset..end]);
		return out;
	}
};

pub const FileEntry = struct {
	path: []const u8,
	length: u64,
	present: bool,
};

pub const FileStore = struct {
	files: []const FileEntry,

	pub fn readSlice(self: FileStore, allocator: std.mem.Allocator, file_index: usize, slice_size: usize, slice_index: usize) StoreError![]u8 {
		if (slice_size == 0) return error.InvalidSliceSize;
		if (file_index >= self.files.len) return error.InvalidIndex;
		const entry = self.files[file_index];
		if (!entry.present) return error.OutOfBounds;
		const file_len = std.math.cast(usize, entry.length) orelse return error.Overflow;
		const mul = @mulWithOverflow(slice_index, slice_size);
		if (mul[1] != 0) return error.Overflow;
		const offset = mul[0];
		if (offset >= file_len) return error.OutOfBounds;
		const end = @min(offset + slice_size, file_len);
		var out = try allocator.alloc(u8, slice_size);
		@memset(out, 0);
		var file = std.fs.cwd().openFile(entry.path, .{}) catch return error.IoError;
		defer file.close();
		file.seekTo(offset) catch return error.IoError;
		const n = file.readAll(out[0 .. end - offset]) catch return error.IoError;
		if (n != end - offset) return error.OutOfBounds;
		return out;
	}
};
