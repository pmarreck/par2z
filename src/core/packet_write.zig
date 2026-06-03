const std = @import("std");
const md5 = @import("md5.zig");

pub const PacketWriteError = error{
    OutOfMemory,
    CryptoUnavailable,
};

const magic = [_]u8{ 'P', 'A', 'R', '2', 0, 'P', 'K', 'T' };

pub fn buildPacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, packet_type: [16]u8, body: []const u8) PacketWriteError![]u8 {
    var pad_len: usize = 0;
    if ((body.len % 4) != 0) {
        pad_len = 4 - (body.len % 4);
    }
    const total_len = 64 + body.len + pad_len;
    var out = try allocator.alloc(u8, total_len);
    @memcpy(out[0..8], &magic);
    std.mem.writeInt(u64, out[8..][0..8], @as(u64, @intCast(total_len)), .little);
    @memcpy(out[32..48], &recovery_set_id);
    @memcpy(out[48..64], &packet_type);
    @memcpy(out[64 .. 64 + body.len], body);
    if (pad_len > 0) {
        @memset(out[64 + body.len .. 64 + body.len + pad_len], 0);
    }
    var digest: [16]u8 = undefined;
    md5.md5Digest(out[32..total_len], &digest) catch return error.CryptoUnavailable;
    @memcpy(out[16..32], &digest);
    return out;
}

