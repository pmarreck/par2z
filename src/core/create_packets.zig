const std = @import("std");
const packet_write = @import("packet_write.zig");
const types = @import("packet_types.zig");

const creator_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'r', 'e', 'a', 't', 'o', 'r', 0 };
const main_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'M', 'a', 'i', 'n', 0, 0, 0, 0 };
const filedesc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'D', 'e', 's', 'c' };
const ifsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'I', 'F', 'S', 'C', 0, 0, 0, 0 };
const recvslic_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'e', 'c', 'v', 'S', 'l', 'i', 'c' };
const unifile_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'U', 'n', 'i', 'F', 'i', 'l', 'e', 'N' };
const comm_ascii_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'o', 'm', 'm', 'A', 'S', 'C', 'I' };
const comm_uni_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'C', 'o', 'm', 'm', 'U', 'n', 'i', 0 };
const fileslic_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'F', 'i', 'l', 'e', 'S', 'l', 'i', 'c' };
const rfsc_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'R', 'F', 'S', 'C', 0, 0, 0, 0 };
const pkdmain_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'P', 'k', 'd', 'M', 'a', 'i', 'n', 0 };
const pkdrecvs_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'P', 'k', 'd', 'R', 'e', 'c', 'v', 'S' };
const sfmd_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'S', 'F', 'M', 'D', 0, 0, 0, 0 };
const sfvs_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'S', 'F', 'V', 'S', 0, 0, 0, 0 };
const aapl_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'A', 'A', 'P', 'L', 0, 0, 0, 0 };

pub fn buildCreatorPacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, text: []const u8) ![]u8 {
    return packet_write.buildPacket(allocator, recovery_set_id, creator_type, text);
}

pub fn buildMainBody(allocator: std.mem.Allocator, slice_size: u64, file_ids: []const [16]u8) ![]u8 {
    const body_len = 12 + file_ids.len * 16;
    var body = try allocator.alloc(u8, body_len);
    writeU64Le(body, 0, slice_size);
    writeU32Le(body, 8, @as(u32, @intCast(file_ids.len)));
    var i: usize = 0;
    while (i < file_ids.len) : (i += 1) {
        const start = 12 + i * 16;
        @memcpy(body[start .. start + 16], &file_ids[i]);
    }
    return body;
}

pub fn buildMainPacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, body: []const u8) ![]u8 {
    return packet_write.buildPacket(allocator, recovery_set_id, main_type, body);
}

pub fn buildSourceMetadataPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    meta: types.SourceMetadataPacket,
) ![]u8 {
    // V2 format: 64 bytes body
    const body_len: usize = 64;
    var body = try allocator.alloc(u8, body_len);
    writeU16Le(body, 0, meta.version);
    writeU16Le(body, 2, meta.flags);
    writeI64Le(body, 4, meta.source_mtime_ns);
    writeI64Le(body, 12, meta.source_ctime_ns);
    writeU64Le(body, 20, meta.source_size);
    writeU32Le(body, 28, meta.uid);
    writeU32Le(body, 32, meta.gid);
    writeU16Le(body, 36, meta.mode);
    writeU16Le(body, 38, meta.reserved1);
    @memcpy(body[40..64], &meta.reserved2);
    return packet_write.buildPacket(allocator, recovery_set_id, sfmd_type, body);
}

/// Build a Source File Validation State (SFVS) packet.
/// Records format validation state achieved when parity was created.
pub fn buildValidationStatePacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    state: types.ValidationStatePacket,
) ![]u8 {
    // Body: 16 (file_id) + 2 (version) + 1 (flags) + 1 (reserved) + 4 (container) + 4 (subtype) + 8 (reserved) = 36 bytes
    const body_len: usize = 36;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &state.file_id);
    writeU16Le(body, 16, state.version);
    body[18] = state.flags;
    body[19] = state.reserved1;
    @memcpy(body[20..24], &state.container);
    @memcpy(body[24..28], &state.subtype);
    @memcpy(body[28..36], &state.reserved2);
    return packet_write.buildPacket(allocator, recovery_set_id, sfvs_type, body);
}

/// Build an Apple Extended Attributes (AAPL) packet.
/// Preserves macOS/HFS+ extended attributes.
pub fn buildAaplPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    aapl: types.AaplPacket,
) ![]u8 {
    // Calculate body size: 16 (file_id) + 2 (version) + 2 (xattr_count) + xattr entries
    var body_len: usize = 20;
    for (aapl.xattrs) |entry| {
        // Each entry: 2 (name_len) + 4 (value_len) + name + value
        body_len += 6 + entry.name.len + entry.value.len;
    }
    // Pad to 4-byte alignment
    const padded_len = (body_len + 3) & ~@as(usize, 3);

    var body = try allocator.alloc(u8, padded_len);
    @memcpy(body[0..16], &aapl.file_id);
    writeU16Le(body, 16, aapl.version);
    writeU16Le(body, 18, @as(u16, @intCast(aapl.xattrs.len)));

    var offset: usize = 20;
    for (aapl.xattrs) |entry| {
        writeU16Le(body, offset, @as(u16, @intCast(entry.name.len)));
        writeU32Le(body, offset + 2, @as(u32, @intCast(entry.value.len)));
        offset += 6;
        @memcpy(body[offset .. offset + entry.name.len], entry.name);
        offset += entry.name.len;
        @memcpy(body[offset .. offset + entry.value.len], entry.value);
        offset += entry.value.len;
    }
    // Zero-pad remaining bytes
    if (offset < padded_len) {
        @memset(body[offset..padded_len], 0);
    }

    return packet_write.buildPacket(allocator, recovery_set_id, aapl_type, body);
}

pub fn buildPackedMainBody(
    allocator: std.mem.Allocator,
    subslice_size: u64,
    slice_size: u64,
    recovery_ids: []const [16]u8,
    non_recovery_ids: []const [16]u8,
) ![]u8 {
    const body_len = 20 + (recovery_ids.len + non_recovery_ids.len) * 16;
    var body = try allocator.alloc(u8, body_len);
    writeU64Le(body, 0, subslice_size);
    writeU64Le(body, 8, slice_size);
    writeU32Le(body, 16, @as(u32, @intCast(recovery_ids.len)));
    var i: usize = 0;
    while (i < recovery_ids.len) : (i += 1) {
        const start = 20 + i * 16;
        @memcpy(body[start .. start + 16], &recovery_ids[i]);
    }
    var j: usize = 0;
    while (j < non_recovery_ids.len) : (j += 1) {
        const start = 20 + (recovery_ids.len + j) * 16;
        @memcpy(body[start .. start + 16], &non_recovery_ids[j]);
    }
    return body;
}

pub fn buildPackedMainPacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, body: []const u8) ![]u8 {
    return packet_write.buildPacket(allocator, recovery_set_id, pkdmain_type, body);
}

pub fn buildFileDescPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    file_id: [16]u8,
    file_hash: [16]u8,
    file_hash_16k: [16]u8,
    file_length: u64,
    file_name: []const u8,
) ![]u8 {
    var name_len = file_name.len + 1;
    if ((name_len % 4) != 0) {
        name_len += 4 - (name_len % 4);
    }
    const body_len = 56 + name_len;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &file_id);
    @memcpy(body[16..32], &file_hash);
    @memcpy(body[32..48], &file_hash_16k);
    writeU64Le(body, 48, file_length);
    @memcpy(body[56 .. 56 + file_name.len], file_name);
    body[56 + file_name.len] = 0;
    if (name_len > file_name.len + 1) {
        @memset(body[56 + file_name.len + 1 .. 56 + name_len], 0);
    }
    return packet_write.buildPacket(allocator, recovery_set_id, filedesc_type, body);
}

pub fn buildIfscPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    file_id: [16]u8,
    entries: []const types.IfscEntry,
) ![]u8 {
    const body_len = 16 + entries.len * 20;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &file_id);
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        const off = 16 + i * 20;
        @memcpy(body[off .. off + 16], &entries[i].md5);
        writeU32Le(body, off + 16, entries[i].crc32);
    }
    return packet_write.buildPacket(allocator, recovery_set_id, ifsc_type, body);
}

pub fn buildRecvSlicPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    exponent: u32,
    data: []const u8,
) ![]u8 {
    const body_len = 4 + data.len;
    var body = try allocator.alloc(u8, body_len);
    writeU32Le(body, 0, exponent);
    @memcpy(body[4..], data);
    return packet_write.buildPacket(allocator, recovery_set_id, recvslic_type, body);
}

pub fn buildPackedRecvSlicPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    exponent: u32,
    data: []const u8,
) ![]u8 {
    const body_len = 4 + data.len;
    var body = try allocator.alloc(u8, body_len);
    writeU32Le(body, 0, exponent);
    @memcpy(body[4..], data);
    return packet_write.buildPacket(allocator, recovery_set_id, pkdrecvs_type, body);
}

pub fn buildFileSlicPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    file_id: [16]u8,
    slice_index: u64,
    data: []const u8,
) ![]u8 {
    const body_len = 24 + data.len;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &file_id);
    writeU64Le(body, 16, slice_index);
    @memcpy(body[24..], data);
    return packet_write.buildPacket(allocator, recovery_set_id, fileslic_type, body);
}

pub fn buildRfscPacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    file_id: [16]u8,
    entries: []const types.RfscEntry,
) ![]u8 {
    const body_len = 16 + entries.len * 24;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &file_id);
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        const off = 16 + i * 24;
        @memcpy(body[off .. off + 16], &entries[i].md5);
        writeU32Le(body, off + 16, entries[i].crc32);
        writeU32Le(body, off + 20, entries[i].exponent);
    }
    return packet_write.buildPacket(allocator, recovery_set_id, rfsc_type, body);
}

pub fn buildUnicodeFilenamePacket(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    file_id: [16]u8,
    utf8_name: []const u8,
) ![]u8 {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8_name);
    defer allocator.free(utf16);
    const utf16_bytes = std.mem.sliceAsBytes(utf16);
    const body_len = 16 + utf16_bytes.len;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &file_id);
    @memcpy(body[16..], utf16_bytes);
    return packet_write.buildPacket(allocator, recovery_set_id, unifile_type, body);
}

pub fn buildCommentAsciiPacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, text: []const u8) ![]u8 {
    return packet_write.buildPacket(allocator, recovery_set_id, comm_ascii_type, text);
}

pub fn buildCommentUnicodePacket(allocator: std.mem.Allocator, recovery_set_id: [16]u8, utf8_text: []const u8) ![]u8 {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8_text);
    defer allocator.free(utf16);
    const utf16_bytes = std.mem.sliceAsBytes(utf16);
    const body_len = 16 + utf16_bytes.len;
    var body = try allocator.alloc(u8, body_len);
    @memset(body[0..16], 0);
    @memcpy(body[16..], utf16_bytes);
    return packet_write.buildPacket(allocator, recovery_set_id, comm_uni_type, body);
}

pub fn buildCommentUnicodePacketWithAscii(
    allocator: std.mem.Allocator,
    recovery_set_id: [16]u8,
    utf8_text: []const u8,
    ascii_text: []const u8,
) ![]u8 {
    var ascii_md5: [16]u8 = undefined;
    try @import("md5.zig").md5Digest(ascii_text, &ascii_md5);
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8_text);
    defer allocator.free(utf16);
    const utf16_bytes = std.mem.sliceAsBytes(utf16);
    const body_len = 16 + utf16_bytes.len;
    var body = try allocator.alloc(u8, body_len);
    @memcpy(body[0..16], &ascii_md5);
    @memcpy(body[16..], utf16_bytes);
    return packet_write.buildPacket(allocator, recovery_set_id, comm_uni_type, body);
}

fn writeU64Le(buf: []u8, offset: usize, value: u64) void {
    buf[offset + 0] = @as(u8, @intCast(value & 0xFF));
    buf[offset + 1] = @as(u8, @intCast((value >> 8) & 0xFF));
    buf[offset + 2] = @as(u8, @intCast((value >> 16) & 0xFF));
    buf[offset + 3] = @as(u8, @intCast((value >> 24) & 0xFF));
    buf[offset + 4] = @as(u8, @intCast((value >> 32) & 0xFF));
    buf[offset + 5] = @as(u8, @intCast((value >> 40) & 0xFF));
    buf[offset + 6] = @as(u8, @intCast((value >> 48) & 0xFF));
    buf[offset + 7] = @as(u8, @intCast((value >> 56) & 0xFF));
}

fn writeI64Le(buf: []u8, offset: usize, value: i64) void {
    writeU64Le(buf, offset, @bitCast(value));
}

fn writeU32Le(buf: []u8, offset: usize, value: u32) void {
    buf[offset + 0] = @as(u8, @intCast(value & 0xFF));
    buf[offset + 1] = @as(u8, @intCast((value >> 8) & 0xFF));
    buf[offset + 2] = @as(u8, @intCast((value >> 16) & 0xFF));
    buf[offset + 3] = @as(u8, @intCast((value >> 24) & 0xFF));
}

fn writeU16Le(buf: []u8, offset: usize, value: u16) void {
    buf[offset + 0] = @as(u8, @intCast(value & 0xFF));
    buf[offset + 1] = @as(u8, @intCast((value >> 8) & 0xFF));
}
