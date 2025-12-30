const std = @import("std");

pub const StoreError = error{
	InvalidInput,
	OutOfBounds,
	OutOfMemory,
	Overflow,
	IoError,
};

pub const StreamReadAt = *const fn (ctx: *anyopaque, offset: u64, out: []u8) usize;

pub const StreamEntry = struct {
	length: u64,
	read_at: StreamReadAt,
	ctx: *anyopaque,
};

pub const StreamStore = struct {
	files: []const StreamEntry,

	pub fn readSlice(self: StreamStore, allocator: std.mem.Allocator, file_index: usize, slice_size: usize, slice_index: usize) StoreError![]u8 {
		if (slice_size == 0) return error.InvalidInput;
		if (file_index >= self.files.len) return error.InvalidInput;
		const entry = self.files[file_index];
		const file_len = std.math.cast(usize, entry.length) orelse return error.Overflow;
		const mul = @mulWithOverflow(slice_index, slice_size);
		if (mul[1] != 0) return error.Overflow;
		const offset = mul[0];
		if (offset >= file_len) return error.OutOfBounds;
		const end = @min(offset + slice_size, file_len);
		var out = try allocator.alloc(u8, slice_size);
		@memset(out, 0);
		var have: usize = 0;
		while (have < end - offset) {
			const n = entry.read_at(entry.ctx, @as(u64, @intCast(offset + have)), out[have .. end - offset]);
			if (n == 0) return error.OutOfBounds;
			have += n;
			if (have > end - offset) return error.IoError;
		}
		return out;
	}
};

pub const MemoryStore = struct {
	files: []const []const u8,

	pub fn readSlice(self: MemoryStore, allocator: std.mem.Allocator, file_index: usize, slice_size: usize, slice_index: usize) StoreError![]u8 {
		if (slice_size == 0) return error.InvalidInput;
		if (file_index >= self.files.len) return error.InvalidInput;
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
		if (slice_size == 0) return error.InvalidInput;
		if (file_index >= self.files.len) return error.InvalidInput;
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
