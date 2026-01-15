const std = @import("std");
const md5 = @import("md5.zig");

pub const FileIdError = error{
    CryptoUnavailable,
    OutOfMemory,
};

pub fn md5_16k(data: []const u8) FileIdError![16]u8 {
    const len = if (data.len > 16384) 16384 else data.len;
    var out: [16]u8 = undefined;
    md5.md5Digest(data[0..len], &out) catch return error.CryptoUnavailable;
    return out;
}

pub fn fileId(allocator: std.mem.Allocator, data: []const u8, file_length: u64, filename: []const u8) FileIdError![16]u8 {
    const hash16k = try md5_16k(data);
    return fileIdFromHash16k(allocator, hash16k, file_length, filename);
}

pub fn fileIdFromHash16k(allocator: std.mem.Allocator, hash16k: [16]u8, file_length: u64, filename: []const u8) FileIdError![16]u8 {
    const total_len = 16 + 8 + filename.len;
    var buf = try allocator.alloc(u8, total_len);
    defer allocator.free(buf);
    @memcpy(buf[0..16], &hash16k);
    buf[16] = @as(u8, @intCast(file_length & 0xFF));
    buf[17] = @as(u8, @intCast((file_length >> 8) & 0xFF));
    buf[18] = @as(u8, @intCast((file_length >> 16) & 0xFF));
    buf[19] = @as(u8, @intCast((file_length >> 24) & 0xFF));
    buf[20] = @as(u8, @intCast((file_length >> 32) & 0xFF));
    buf[21] = @as(u8, @intCast((file_length >> 40) & 0xFF));
    buf[22] = @as(u8, @intCast((file_length >> 48) & 0xFF));
    buf[23] = @as(u8, @intCast((file_length >> 56) & 0xFF));
    @memcpy(buf[24..], filename);
    var out: [16]u8 = undefined;
    md5.md5Digest(buf, &out) catch return error.CryptoUnavailable;
    return out;
}

/// Compute file ID for a directory (size = 0, content = empty).
/// Directory paths should include a trailing slash per the .par2d spec.
pub fn directoryId(allocator: std.mem.Allocator, dir_path: []const u8) FileIdError![16]u8 {
    // MD5 of empty data
    const empty_md5: [16]u8 = .{ 0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, 0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e };
    return fileIdFromHash16k(allocator, empty_md5, 0, dir_path);
}
