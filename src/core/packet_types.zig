const std = @import("std");
const bytes = @import("bytes.zig");
const packet = @import("packet.zig");

pub const PacketTypeError = error{
	OutOfBounds,
	InvalidType,
	InvalidLength,
	OutOfMemory,
};

pub const CreatorPacket = struct {
	text: []const u8,
};

pub const MainPacket = struct {
	slice_size: u64,
	subslice_size: ?u64,
	recovery_file_ids: []const [16]u8,
	non_recovery_file_ids: []const [16]u8,
	is_packed: bool,
};

pub const FileDescPacket = struct {
	file_id: [16]u8,
	file_hash: [16]u8,
	file_hash_16k: [16]u8,
	file_length: u64,
	file_name: []const u8,
};

pub const IfscEntry = struct {
	md5: [16]u8,
	crc32: u32,
};

pub const IfscPacket = struct {
	file_id: [16]u8,
	entries: []const IfscEntry,
};

pub const RecvSlicPacket = struct {
	exponent: u32,
	data: []const u8,
};

pub const FileSlicPacket = struct {
	file_id: [16]u8,
	slice_index: u64,
	data: []const u8,
};

pub const RfscEntry = struct {
	md5: [16]u8,
	crc32: u32,
	exponent: u32,
};

pub const RfscPacket = struct {
	file_id: [16]u8,
	entries: []const RfscEntry,
};

pub const PackedRecvSlicPacket = struct {
	exponent: u32,
	data: []const u8,
};

const creator_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'r', 'e', 'a', 't', 'o', 'r', 0 };
const main_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'M', 'a', 'i', 'n', 0, 0, 0, 0 };
const filedesc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'D', 'e', 's', 'c' };
const ifsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'I', 'F', 'S', 'C', 0, 0, 0, 0 };
const recvslic_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
const fileslic_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'S', 'l', 'i', 'c' };
const rfsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
const pkdmain_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'P', 'k', 'd', 'M', 'a', 'i', 'n', 0 };
const pkdrecvs_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'P', 'k', 'd', 'R', 'e', 'c', 'v', 'S' };

pub fn parseCreator(buf: []const u8) PacketTypeError!CreatorPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &creator_type)) return error.InvalidType;
	if (hdr.length < 64) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	var body = buf[64..end];
	while (body.len > 0 and body[body.len - 1] == 0) {
		body = body[0 .. body.len - 1];
	}
	return .{ .text = body };
}

pub fn parseMain(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!MainPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &main_type)) return error.InvalidType;
	if (hdr.length < 64 + 12) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	const slice_size = bytes.readU64Le(body, 0) catch return error.OutOfBounds;
	const file_count = bytes.readU32Le(body, 8) catch return error.OutOfBounds;
	const ids_offset: usize = 12;
	const ids_bytes = body.len - ids_offset;
	if ((ids_bytes % 16) != 0) return error.InvalidLength;
	const total_ids = ids_bytes / 16;
	const recovery_count = @as(usize, file_count);
	if (total_ids < recovery_count) return error.InvalidLength;
	var recovery_ids = try allocator.alloc([16]u8, recovery_count);
	var non_recovery_ids = try allocator.alloc([16]u8, total_ids - recovery_count);
	var i: usize = 0;
	while (i < recovery_count) : (i += 1) {
		const start = ids_offset + i * 16;
		@memcpy(&recovery_ids[i], body[start .. start + 16]);
	}
	var j: usize = 0;
	while (j < non_recovery_ids.len) : (j += 1) {
		const start = ids_offset + (recovery_count + j) * 16;
		@memcpy(&non_recovery_ids[j], body[start .. start + 16]);
	}
	return .{
		.slice_size = slice_size,
		.subslice_size = null,
		.recovery_file_ids = recovery_ids,
		.non_recovery_file_ids = non_recovery_ids,
		.is_packed = false,
	};
}

pub fn parsePackedMain(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!MainPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &pkdmain_type)) return error.InvalidType;
	if (hdr.length < 64 + 20) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	const subslice_size = bytes.readU64Le(body, 0) catch return error.OutOfBounds;
	const slice_size = bytes.readU64Le(body, 8) catch return error.OutOfBounds;
	const file_count = bytes.readU32Le(body, 16) catch return error.OutOfBounds;
	const ids_offset: usize = 20;
	const ids_bytes = body.len - ids_offset;
	if ((ids_bytes % 16) != 0) return error.InvalidLength;
	const total_ids = ids_bytes / 16;
	const recovery_count = @as(usize, file_count);
	if (total_ids < recovery_count) return error.InvalidLength;
	var recovery_ids = try allocator.alloc([16]u8, recovery_count);
	var non_recovery_ids = try allocator.alloc([16]u8, total_ids - recovery_count);
	var i: usize = 0;
	while (i < recovery_count) : (i += 1) {
		const start = ids_offset + i * 16;
		@memcpy(&recovery_ids[i], body[start .. start + 16]);
	}
	var j: usize = 0;
	while (j < non_recovery_ids.len) : (j += 1) {
		const start = ids_offset + (recovery_count + j) * 16;
		@memcpy(&non_recovery_ids[j], body[start .. start + 16]);
	}
	return .{
		.slice_size = slice_size,
		.subslice_size = subslice_size,
		.recovery_file_ids = recovery_ids,
		.non_recovery_file_ids = non_recovery_ids,
		.is_packed = true,
	};
}

pub fn parseFileDesc(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!FileDescPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &filedesc_type)) return error.InvalidType;
	if (hdr.length < 64 + 56) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	var out: FileDescPacket = undefined;
	@memcpy(&out.file_id, body[0..16]);
	@memcpy(&out.file_hash, body[16..32]);
	@memcpy(&out.file_hash_16k, body[32..48]);
	out.file_length = bytes.readU64Le(body, 48) catch return error.OutOfBounds;
	var name = body[56..];
	while (name.len > 0 and name[name.len - 1] == 0) {
		name = name[0 .. name.len - 1];
	}
	const name_copy = try allocator.alloc(u8, name.len);
	@memcpy(name_copy, name);
	out.file_name = name_copy;
	return out;
}

pub fn parseIfsc(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!IfscPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &ifsc_type)) return error.InvalidType;
	if (hdr.length < 64 + 16) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	var out: IfscPacket = undefined;
	@memcpy(&out.file_id, body[0..16]);
	const data = body[16..];
	if (data.len % 20 != 0) return error.InvalidLength;
	const count = data.len / 20;
	var entries = try allocator.alloc(IfscEntry, count);
	var i: usize = 0;
	while (i < count) : (i += 1) {
		const off = i * 20;
		@memcpy(&entries[i].md5, data[off .. off + 16]);
		entries[i].crc32 = bytes.readU32Le(data, off + 16) catch return error.OutOfBounds;
	}
	out.entries = entries;
	return out;
}

pub fn parseRecvSlic(buf: []const u8) PacketTypeError!RecvSlicPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &recvslic_type)) return error.InvalidType;
	if (hdr.length < 64 + 4) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	const exponent = bytes.readU32Le(body, 0) catch return error.OutOfBounds;
	return .{ .exponent = exponent, .data = body[4..] };
}

pub fn parsePackedRecvSlic(buf: []const u8) PacketTypeError!PackedRecvSlicPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &pkdrecvs_type)) return error.InvalidType;
	if (hdr.length < 64 + 4) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	const exponent = bytes.readU32Le(body, 0) catch return error.OutOfBounds;
	return .{ .exponent = exponent, .data = body[4..] };
}

pub fn parseFileSlic(buf: []const u8) PacketTypeError!FileSlicPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &fileslic_type)) return error.InvalidType;
	if (hdr.length < 64 + 24) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	var out: FileSlicPacket = undefined;
	@memcpy(&out.file_id, body[0..16]);
	out.slice_index = bytes.readU64Le(body, 16) catch return error.OutOfBounds;
	out.data = body[24..];
	return out;
}

pub fn parseRfsc(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!RfscPacket {
	const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
	if (!std.mem.eql(u8, &hdr.packet_type, &rfsc_type)) return error.InvalidType;
	if (hdr.length < 64 + 16) return error.InvalidLength;
	const end: usize = @intCast(hdr.length);
	const body = buf[64..end];
	var out: RfscPacket = undefined;
	@memcpy(&out.file_id, body[0..16]);
	const data = body[16..];
	if ((data.len % 24) != 0) return error.InvalidLength;
	const count = data.len / 24;
	var entries = try allocator.alloc(RfscEntry, count);
	var i: usize = 0;
	while (i < count) : (i += 1) {
		const off = i * 24;
		@memcpy(&entries[i].md5, data[off .. off + 16]);
		entries[i].crc32 = bytes.readU32Le(data, off + 16) catch return error.OutOfBounds;
		entries[i].exponent = bytes.readU32Le(data, off + 20) catch return error.OutOfBounds;
	}
	out.entries = entries;
	return out;
}
