const bytes = @import("bytes.zig");
const md5 = @import("md5.zig");
const std = @import("std");

pub const PacketError = error{
	OutOfBounds,
	InvalidMagic,
	InvalidLength,
	InvalidHash,
	CryptoUnavailable,
};

pub const PacketHeader = struct {
	length: u64,
	hash: [16]u8,
	recovery_set_id: [16]u8,
	packet_type: [16]u8,
};

const magic = [_]u8{ 'P', 'A', 'R', '2', 0, 'P', 'K', 'T' };
const header_len: usize = 64;

pub fn parseHeader(buf: []const u8) PacketError!PacketHeader {
	if (buf.len < header_len) return error.OutOfBounds;
	if (!std.mem.eql(u8, buf[0..8], &magic)) return error.InvalidMagic;
	const length = bytes.readU64Le(buf, 8) catch return error.OutOfBounds;
	if (length < header_len) return error.InvalidLength;
	var h: PacketHeader = undefined;
	h.length = length;
	@memcpy(&h.hash, buf[16..32]);
	@memcpy(&h.recovery_set_id, buf[32..48]);
	@memcpy(&h.packet_type, buf[48..64]);
	return h;
}

pub fn verifyPacketHash(buf: []const u8) PacketError!void {
	const h = try parseHeader(buf);
	if (h.length > buf.len) return error.OutOfBounds;
	const end: usize = @intCast(h.length);
	var digest: [16]u8 = undefined;
	md5.md5Digest(buf[32..end], &digest) catch return error.CryptoUnavailable;
	if (!std.mem.eql(u8, &h.hash, &digest)) return error.InvalidHash;
}
