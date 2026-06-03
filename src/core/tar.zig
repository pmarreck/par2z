//! Minimal ustar (POSIX tar) header construction for emitting `.par2.tar`
//! archives. Extracted from cli.zig so the numeric-field encoding can be
//! unit-tested — the size field in particular must never silently overflow,
//! or the resulting archive is corrupt and unreadable by external `tar`.

const std = @import("std");

pub const TarError = error{FileTooLargeForTar};

/// Write `value` as a right-justified, zero-padded octal string into `field`,
/// reserving the final byte for the NUL terminator (ustar numeric-field
/// convention: `field.len - 1` octal digits followed by NUL).
pub fn writeOctalField(field: []u8, value: u64) TarError!void {
    std.debug.assert(field.len >= 1);
    const digits = field.len - 1;
    var tmp: [24]u8 = undefined; // u64 max is 22 octal digits
    const s = std.fmt.bufPrint(&tmp, "{o}", .{value}) catch unreachable;
    if (s.len > digits) return error.FileTooLargeForTar;
    const pad = digits - s.len;
    @memset(field[0..pad], '0');
    @memcpy(field[pad..digits], s);
    field[digits] = 0;
}

/// Build a complete 512-byte ustar header for a regular file.
pub fn buildHeader(name: []const u8, size: u64) TarError![512]u8 {
    var header: [512]u8 = undefined;
    @memset(&header, 0);
    const name_len = @min(name.len, 100);
    @memcpy(header[0..name_len], name[0..name_len]);
    @memcpy(header[100..107], "0000644");
    header[107] = 0;
    @memcpy(header[108..115], "0000000");
    header[115] = 0;
    @memcpy(header[116..123], "0000000");
    header[123] = 0;
    // size field: bytes 124..136 = 11 octal digits + NUL.
    try writeOctalField(header[124..136], size);
    @memcpy(header[136..147], "00000000000");
    header[147] = 0;
    // checksum field placeholder: 8 bytes of spaces during checksum calc.
    @memset(header[148..156], ' ');
    header[156] = '0'; // typeflag: regular file
    @memcpy(header[257..262], "ustar");
    header[262] = 0;
    @memcpy(header[263..265], "00");
    var checksum: u32 = 0;
    for (header) |b| checksum += b;
    // checksum field: bytes 148..155 = 6 octal digits + NUL, then 155 = space.
    // Max checksum is 512*255 = 130560 = 0o377700 (6 digits) — cannot overflow.
    writeOctalField(header[148..155], checksum) catch unreachable;
    header[155] = ' ';
    return header;
}
