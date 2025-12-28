const std = @import("std");
const gf = @import("gf16.zig");
const layout = @import("layout.zig");
const storage = @import("storage.zig");
const rs = @import("rs.zig");

pub const BlockError = error{
	OutOfMemory,
	InvalidSliceSize,
	StoreError,
	RsError,
	Overflow,
	TooManySlices,
};

pub fn computeRecoverySliceMemory(
	allocator: std.mem.Allocator,
	store: storage.MemoryStore,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponent: u32,
) BlockError![]u8 {
	const slices = try loadSlices(allocator, store, files, slice_size);
	defer freeSlices(allocator, slices);
	const out = try allocator.alloc(u8, slice_size);
	rs.encodeRecoverySlice(out, slices, exponent) catch return error.RsError;
	return out;
}

pub fn computeRecoverySlicesMemoryBatch(
	allocator: std.mem.Allocator,
	store: storage.MemoryStore,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	return computeRecoverySlicesBatchGeneric(allocator, store, files, slice_size, exponents);
}

pub fn computeRecoverySlicesMemoryBatchParallel(
	allocator: std.mem.Allocator,
	store: storage.MemoryStore,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	return computeRecoverySlicesBatchParallelGeneric(allocator, store, files, slice_size, exponents);
}

pub fn computeRecoverySlicesFileStoreBatch(
	allocator: std.mem.Allocator,
	store: storage.FileStore,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	return computeRecoverySlicesBatchStreamGeneric(allocator, store, files, slice_size, exponents);
}

pub fn computeRecoverySlicesFileStoreBatchParallel(
	allocator: std.mem.Allocator,
	store: storage.FileStore,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	return computeRecoverySlicesBatchStreamGeneric(allocator, store, files, slice_size, exponents);
}

const Shared = struct {
	allocator: std.mem.Allocator,
	slices: []const []const u8,
	exponents: []const u32,
	slice_size: usize,
	outputs: []?[]u8,
	next_index: std.atomic.Value(usize),
	stop: std.atomic.Value(u8),
	err: ?BlockError,
	err_mutex: std.Thread.Mutex,
};

fn worker(shared: *Shared) void {
	while (shared.stop.load(.monotonic) == 0) {
		const idx = shared.next_index.fetchAdd(1, .monotonic);
		if (idx >= shared.exponents.len) return;
		const out = shared.allocator.alloc(u8, shared.slice_size) catch {
			setError(shared, error.OutOfMemory);
			return;
		};
		const exponent = shared.exponents[idx];
		rs.encodeRecoverySliceSerial(out, shared.slices, exponent) catch {
			shared.allocator.free(out);
			setError(shared, error.RsError);
			return;
		};
		shared.outputs[idx] = out;
	}
}

fn setError(shared: *Shared, err: BlockError) void {
	shared.err_mutex.lock();
	defer shared.err_mutex.unlock();
	if (shared.err == null) shared.err = err;
	shared.stop.store(1, .monotonic);
}

fn computeRecoverySlicesBatchGeneric(
	allocator: std.mem.Allocator,
	store: anytype,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	const slices = try loadSlices(allocator, store, files, slice_size);
	defer freeSlices(allocator, slices);
	if (exponents.len == 0) return allocator.alloc([]u8, 0);
	var outputs = try allocator.alloc([]u8, exponents.len);
	var i: usize = 0;
	while (i < exponents.len) : (i += 1) {
		outputs[i] = try allocator.alloc(u8, slice_size);
		rs.encodeRecoverySliceSerial(outputs[i], slices, exponents[i]) catch return error.RsError;
	}
	return outputs;
}

fn computeRecoverySlicesBatchParallelGeneric(
	allocator: std.mem.Allocator,
	store: anytype,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	const slices = try loadSlices(allocator, store, files, slice_size);
	defer freeSlices(allocator, slices);
	if (exponents.len == 0) return allocator.alloc([]u8, 0);
	const cpu = std.Thread.getCpuCount() catch 1;
	const thread_count = @min(cpu, exponents.len);
	if (thread_count <= 1) {
		var outputs = try allocator.alloc([]u8, exponents.len);
		var i: usize = 0;
		while (i < exponents.len) : (i += 1) {
			outputs[i] = try allocator.alloc(u8, slice_size);
			rs.encodeRecoverySliceSerial(outputs[i], slices, exponents[i]) catch return error.RsError;
		}
		return outputs;
	}

	const outputs_opt = try allocator.alloc(?[]u8, exponents.len);
	defer {
		var j: usize = 0;
		while (j < outputs_opt.len) : (j += 1) {
			if (outputs_opt[j]) |buf| allocator.free(buf);
		}
	}
	@memset(outputs_opt, null);

	var shared = Shared{
		.allocator = allocator,
		.slices = slices,
		.exponents = exponents,
		.slice_size = slice_size,
		.outputs = outputs_opt,
		.next_index = std.atomic.Value(usize).init(0),
		.stop = std.atomic.Value(u8).init(0),
		.err = null,
		.err_mutex = .{},
	};
	var threads = try allocator.alloc(std.Thread, thread_count - 1);
	defer allocator.free(threads);

	var t: usize = 0;
	while (t + 1 < thread_count) : (t += 1) {
		threads[t] = std.Thread.spawn(.{}, worker, .{&shared}) catch {
			shared.stop.store(1, .monotonic);
			break;
		};
	}
	worker(&shared);
	t = 0;
	while (t + 1 < thread_count) : (t += 1) {
		threads[t].join();
	}
	if (shared.err) |e| return e;

	var outputs = try allocator.alloc([]u8, exponents.len);
	var i: usize = 0;
	while (i < outputs.len) : (i += 1) {
		outputs[i] = outputs_opt[i] orelse return error.OutOfMemory;
	}
	@memset(outputs_opt, null);
	return outputs;
}

fn computeRecoverySlicesBatchStreamGeneric(
	allocator: std.mem.Allocator,
	store: anytype,
	files: []const layout.FileInfo,
	slice_size: usize,
	exponents: []const u32,
) BlockError![][]u8 {
	if (exponents.len == 0) return allocator.alloc([]u8, 0);
	const order = try layout.buildSliceOrder(allocator, files, slice_size);
	defer allocator.free(order);
	if (order.len > gf.maxValidIndexCount()) return error.TooManySlices;
	var outputs = try allocator.alloc([]u8, exponents.len);
	errdefer {
		var j: usize = 0;
		while (j < outputs.len) : (j += 1) {
			if (outputs[j].len > 0) allocator.free(outputs[j]);
		}
		allocator.free(outputs);
	}
	var i: usize = 0;
	while (i < outputs.len) : (i += 1) {
		outputs[i] = try allocator.alloc(u8, slice_size);
		@memset(outputs[i], 0);
	}
	var s: usize = 0;
	while (s < order.len) : (s += 1) {
		const ref = order[s];
		const slice = store.readSlice(allocator, ref.file_index, slice_size, ref.slice_index) catch return error.StoreError;
		defer allocator.free(slice);
		const constant = gf.constantForIndex(@as(u32, @intCast(s)));
		var e: usize = 0;
		while (e < exponents.len) : (e += 1) {
			const factor = gf.pow(constant, exponents[e]);
			rs.accumulateRecoverySlice(outputs[e], slice, factor) catch return error.RsError;
		}
	}
	return outputs;
}

fn loadSlices(
	allocator: std.mem.Allocator,
	store: anytype,
	files: []const layout.FileInfo,
	slice_size: usize,
) BlockError![]const []const u8 {
	const order = try layout.buildSliceOrder(allocator, files, slice_size);
	defer allocator.free(order);
	var slices = try allocator.alloc([]const u8, order.len);
	var i: usize = 0;
	while (i < order.len) : (i += 1) {
		const ref = order[i];
		const slice = store.readSlice(allocator, ref.file_index, slice_size, ref.slice_index) catch return error.StoreError;
		slices[i] = slice;
	}
	return slices;
}

fn freeSlices(allocator: std.mem.Allocator, slices: []const []const u8) void {
	var si: usize = 0;
	while (si < slices.len) : (si += 1) {
		allocator.free(slices[si]);
	}
	allocator.free(slices);
}
