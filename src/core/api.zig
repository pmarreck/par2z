const std = @import("std");
const types = @import("packet_types.zig");
const packet = @import("packet.zig");
const set = @import("recovery_set.zig");
const slices = @import("slices.zig");
const storage = @import("storage.zig");
const layout = @import("layout.zig");
const rs = @import("rs.zig");

pub const ApiError = error{
	InvalidInput,
	OutOfMemory,
	PacketError,
	SliceError,
	StoreError,
	NotFound,
	RsError,
};

pub const Par2Context = struct {
	main: ?types.MainPacket,
	packed_main: ?types.MainPacket,
	recovery_set: ?set.RecoverySet,
	file_descs: std.ArrayList(types.FileDescPacket),
	ifscs: std.ArrayList(types.IfscPacket),
};

pub fn initContext(allocator: std.mem.Allocator) Par2Context {
	_ = allocator;
	return .{
		.main = null,
		.packed_main = null,
		.recovery_set = null,
		.file_descs = std.ArrayList(types.FileDescPacket).empty,
		.ifscs = std.ArrayList(types.IfscPacket).empty,
	};
}

pub fn addPacket(allocator: std.mem.Allocator, ctx: *Par2Context, buf: []const u8) ApiError!void {
	const hdr = packet.parseHeader(buf) catch return error.PacketError;
	const t = hdr.packet_type;
	const main_type = [_]u8{ 'P','A','R',' ','2','.','0',0,'M','a','i','n',0,0,0,0 };
	const pkdmain_type = [_]u8{ 'P','A','R',' ','2','.','0',0,'P','k','d','M','a','i','n',0 };
	const filedesc_type = [_]u8{ 'P','A','R',' ','2','.','0',0,'F','i','l','e','D','e','s','c' };
	const ifsc_type = [_]u8{ 'P','A','R',' ','2','.','0',0,'I','F','S','C',0,0,0,0 };
	if (std.mem.eql(u8, &t, &main_type)) {
		if (ctx.main != null) return;
		const m = types.parseMain(buf, allocator) catch return error.PacketError;
		ctx.main = m;
		ctx.recovery_set = set.buildRecoverySet(allocator, m) catch return error.OutOfMemory;
		attachBufferedPackets(ctx);
		return;
	}
	if (std.mem.eql(u8, &t, &pkdmain_type)) {
		const m = types.parsePackedMain(buf, allocator) catch return error.PacketError;
		ctx.packed_main = m;
		if (ctx.main == null) {
			ctx.main = m;
			ctx.recovery_set = set.buildRecoverySet(allocator, m) catch return error.OutOfMemory;
			attachBufferedPackets(ctx);
		}
		return;
	}
	if (std.mem.eql(u8, &t, &filedesc_type)) {
		const d = types.parseFileDesc(buf, allocator) catch return error.PacketError;
		if (ctx.recovery_set) |*rs_set| {
			_ = set.attachFileDesc(rs_set, d) catch {};
			return;
		}
		try ctx.file_descs.append(allocator, d);
		return;
	}
	if (std.mem.eql(u8, &t, &ifsc_type)) {
		const i = types.parseIfsc(buf, allocator) catch return error.PacketError;
		if (ctx.recovery_set) |*rs_set| {
			_ = set.attachIfsc(rs_set, i) catch {};
			return;
		}
		try ctx.ifscs.append(allocator, i);
		return;
	}
}

fn attachBufferedPackets(ctx: *Par2Context) void {
	if (ctx.recovery_set == null) return;
	const rs_set = &ctx.recovery_set.?;
	for (ctx.file_descs.items) |d| {
		_ = set.attachFileDesc(rs_set, d) catch {};
	}
	for (ctx.ifscs.items) |i| {
		_ = set.attachIfsc(rs_set, i) catch {};
	}
	ctx.file_descs.items.len = 0;
	ctx.ifscs.items.len = 0;
}

pub fn verifyStore(allocator: std.mem.Allocator, ctx: *Par2Context, store: storage.MemoryStore) ApiError!void {
	if (ctx.main == null or ctx.recovery_set == null) return error.InvalidInput;
	const rs_set = ctx.recovery_set.?;
	const slice_size = @as(usize, @intCast(rs_set.slice_size));
	var file_i: usize = 0;
	while (file_i < rs_set.recovery_files.len) : (file_i += 1) {
		const entry = rs_set.recovery_files[file_i];
		if (entry.ifsc) |ifsc| {
			const file = store.files[file_i];
			const computed = slices.computeIfscEntries(allocator, file, slice_size) catch return error.SliceError;
			slices.verifyIfsc(computed, ifsc.entries) catch return error.SliceError;
		}
	}
}

pub fn verifyStoreFile(allocator: std.mem.Allocator, ctx: *Par2Context, store: storage.FileStore) ApiError!void {
	if (ctx.main == null or ctx.recovery_set == null) return error.InvalidInput;
	const rs_set = ctx.recovery_set.?;
	const slice_size = @as(usize, @intCast(rs_set.slice_size));
	var file_i: usize = 0;
	while (file_i < rs_set.recovery_files.len) : (file_i += 1) {
		const entry = rs_set.recovery_files[file_i];
		if (entry.ifsc) |ifsc| {
			const expected = ifsc.entries;
			if (expected.len == 0) continue;
			var slice_i: usize = 0;
			while (slice_i < expected.len) : (slice_i += 1) {
				const slice = store.readSlice(allocator, file_i, slice_size, slice_i) catch return error.SliceError;
				defer allocator.free(slice);
				var computed: types.IfscEntry = undefined;
				slices.computeIfscEntry(slice, &computed) catch return error.SliceError;
				if (!std.mem.eql(u8, &computed.md5, &expected[slice_i].md5)) return error.SliceError;
				if (computed.crc32 != expected[slice_i].crc32) return error.SliceError;
			}
		}
	}
}

pub fn verifyStoreStream(allocator: std.mem.Allocator, ctx: *Par2Context, store: storage.StreamStore) ApiError!void {
	if (ctx.main == null or ctx.recovery_set == null) return error.InvalidInput;
	const rs_set = ctx.recovery_set.?;
	const slice_size = @as(usize, @intCast(rs_set.slice_size));
	var file_i: usize = 0;
	while (file_i < rs_set.recovery_files.len) : (file_i += 1) {
		const entry = rs_set.recovery_files[file_i];
		if (entry.ifsc) |ifsc| {
			const expected = ifsc.entries;
			if (expected.len == 0) continue;
			var slice_i: usize = 0;
			while (slice_i < expected.len) : (slice_i += 1) {
				const slice = store.readSlice(allocator, file_i, slice_size, slice_i) catch return error.SliceError;
				defer allocator.free(slice);
				var computed: types.IfscEntry = undefined;
				slices.computeIfscEntry(slice, &computed) catch return error.SliceError;
				if (!std.mem.eql(u8, &computed.md5, &expected[slice_i].md5)) return error.SliceError;
				if (computed.crc32 != expected[slice_i].crc32) return error.SliceError;
			}
		}
	}
}

pub fn recoverMissingSlicesMemory(
	allocator: std.mem.Allocator,
	files: []const layout.FileInfo,
	store: anytype,
	missing_indices: []const usize,
	recovery_slices: []const rs.RecoverySlice,
	slice_size: usize,
) ApiError![][]u8 {
	const order = layout.buildSliceOrder(allocator, files, slice_size) catch return error.SliceError;
	defer allocator.free(order);
	var slices_list = try allocator.alloc(?[]const u8, order.len);
	defer allocator.free(slices_list);
	var is_missing = try allocator.alloc(bool, order.len);
	defer allocator.free(is_missing);
	@memset(is_missing, false);
	for (missing_indices) |mi| {
		if (mi < is_missing.len) is_missing[mi] = true;
	}
	var i: usize = 0;
	while (i < order.len) : (i += 1) {
		if (is_missing[i]) {
			slices_list[i] = null;
			continue;
		}
		slices_list[i] = store.readSlice(allocator, order[i].file_index, slice_size, order[i].slice_index) catch return error.StoreError;
	}
	defer {
		var si: usize = 0;
		while (si < slices_list.len) : (si += 1) {
			if (slices_list[si]) |slice| {
				allocator.free(slice);
			}
		}
	}
	const recovered = rs.decodeMissingSlices(allocator, slices_list, missing_indices, recovery_slices, slice_size) catch return error.RsError;
	return recovered;
}
