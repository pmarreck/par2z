const std = @import("std");
const bytes = @import("bytes.zig");
const packet = @import("packet.zig");

pub const PacketTypeError = error{
    OutOfBounds,
    InvalidInput,
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

/// Metadata flags for SFMD v2 packet
pub const MetadataFlags = struct {
    pub const HAS_UID: u16 = 0x0001; // uid field is valid
    pub const HAS_GID: u16 = 0x0002; // gid field is valid
    pub const HAS_MODE: u16 = 0x0004; // mode field is valid
    pub const HAS_CTIME: u16 = 0x0008; // ctime field is valid (not just zero)
};

/// Source File Metadata Packet (SFMD v2)
/// Records source file metadata for change detection and permission restoration.
pub const SourceMetadataPacket = struct {
    version: u16, // Current version: 2
    flags: u16, // MetadataFlags bitmask
    source_mtime_ns: i64,
    source_ctime_ns: i64,
    source_size: u64,
    uid: u32, // POSIX owner user ID, 0xFFFFFFFF if unavailable
    gid: u32, // POSIX owner group ID, 0xFFFFFFFF if unavailable
    mode: u16, // POSIX permission bits, 0xFFFF if unavailable
    reserved1: u16,
    reserved2: [24]u8,
};

/// Validation flags for SFVS packet
pub const ValidationFlags = struct {
    pub const MAGIC: u8 = 0x01; // Magic bytes / file signature validated
    pub const STRUCTURE: u8 = 0x02; // Container/chunk structure validated
    pub const CHECKSUM: u8 = 0x04; // Internal checksums verified
    pub const DECODE: u8 = 0x08; // Decompression/decode succeeded
    pub const CHARSET: u8 = 0x10; // Character encoding validated
    pub const SEMANTIC: u8 = 0x20; // Content semantically valid
    pub const ENCRYPTED: u8 = 0x40; // Content is encrypted (validation limited)
    pub const COMPLETE: u8 = 0x80; // Every byte covered by integrity check
};

/// Source File Validation State Packet (SFVS)
/// Records format validation state achieved when parity was created.
pub const ValidationStatePacket = struct {
    file_id: [16]u8,
    version: u16,
    flags: u8,
    reserved1: u8,
    container: [4]u8, // FourCC of container format
    subtype: [4]u8, // FourCC of format subtype
    reserved2: [8]u8,
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

/// Extended attribute entry for AAPL packet
pub const XattrEntry = struct {
    name: []const u8, // xattr name (UTF-8, e.g., "com.apple.FinderInfo")
    value: []const u8, // xattr value (raw bytes)
};

/// Apple Extended Attributes Packet (AAPL)
/// Preserves macOS/HFS+ extended attributes including Finder Info.
pub const AaplPacket = struct {
    file_id: [16]u8,
    version: u16, // Current version: 1
    xattrs: []const XattrEntry,
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
const sfmd_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'S', 'F', 'M', 'D', 0, 0, 0, 0 };
const sfvs_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'S', 'F', 'V', 'S', 0, 0, 0, 0 };
const aapl_type = [_]u8{ 'P', 'A', 'R', ' ', '2', '.', '0', 0, 'A', 'A', 'P', 'L', 0, 0, 0, 0 };

pub const source_metadata_type = sfmd_type;
pub const validation_state_type = sfvs_type;
pub const apple_xattr_type = aapl_type;

pub fn parseCreator(buf: []const u8) PacketTypeError!CreatorPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &creator_type)) return error.InvalidInput;
    if (hdr.length < 64) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    var body = buf[64..end];
    while (body.len > 0 and body[body.len - 1] == 0) {
        body = body[0 .. body.len - 1];
    }
    return .{ .text = body };
}

pub fn parseMain(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!MainPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &main_type)) return error.InvalidInput;
    if (hdr.length < 64 + 12) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    const slice_size = bytes.readU64Le(body, 0) catch return error.OutOfBounds;
    const file_count = bytes.readU32Le(body, 8) catch return error.OutOfBounds;
    const ids_offset: usize = 12;
    const ids_bytes = body.len - ids_offset;
    if ((ids_bytes % 16) != 0) return error.InvalidInput;
    const total_ids = ids_bytes / 16;
    const recovery_count = @as(usize, file_count);
    if (total_ids < recovery_count) return error.InvalidInput;
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

pub fn parseSourceMetadata(buf: []const u8) PacketTypeError!SourceMetadataPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &sfmd_type)) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];

    var out: SourceMetadataPacket = undefined;
    out.version = bytes.readU16Le(body, 0) catch return error.OutOfBounds;
    out.flags = bytes.readU16Le(body, 2) catch return error.OutOfBounds;
    const mtime = bytes.readU64Le(body, 4) catch return error.OutOfBounds;
    const ctime = bytes.readU64Le(body, 12) catch return error.OutOfBounds;
    out.source_mtime_ns = @bitCast(mtime);
    out.source_ctime_ns = @bitCast(ctime);
    out.source_size = bytes.readU64Le(body, 20) catch return error.OutOfBounds;

    // Handle v1 vs v2 packet format
    if (out.version >= 2 and body.len >= 64) {
        // V2 format: includes uid, gid, mode
        out.uid = bytes.readU32Le(body, 28) catch return error.OutOfBounds;
        out.gid = bytes.readU32Le(body, 32) catch return error.OutOfBounds;
        out.mode = bytes.readU16Le(body, 36) catch return error.OutOfBounds;
        out.reserved1 = bytes.readU16Le(body, 38) catch return error.OutOfBounds;
        @memcpy(&out.reserved2, body[40..64]);
    } else {
        // V1 format: no uid/gid/mode, mark as unavailable
        out.uid = 0xFFFFFFFF;
        out.gid = 0xFFFFFFFF;
        out.mode = 0xFFFF;
        out.reserved1 = 0;
        @memset(&out.reserved2, 0);
    }
    return out;
}

pub fn parsePackedMain(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!MainPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &pkdmain_type)) return error.InvalidInput;
    if (hdr.length < 64 + 20) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    const subslice_size = bytes.readU64Le(body, 0) catch return error.OutOfBounds;
    const slice_size = bytes.readU64Le(body, 8) catch return error.OutOfBounds;
    const file_count = bytes.readU32Le(body, 16) catch return error.OutOfBounds;
    const ids_offset: usize = 20;
    const ids_bytes = body.len - ids_offset;
    if ((ids_bytes % 16) != 0) return error.InvalidInput;
    const total_ids = ids_bytes / 16;
    const recovery_count = @as(usize, file_count);
    if (total_ids < recovery_count) return error.InvalidInput;
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
    if (!std.mem.eql(u8, &hdr.packet_type, &filedesc_type)) return error.InvalidInput;
    if (hdr.length < 64 + 56) return error.InvalidInput;
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
    if (!std.mem.eql(u8, &hdr.packet_type, &ifsc_type)) return error.InvalidInput;
    if (hdr.length < 64 + 16) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    var out: IfscPacket = undefined;
    @memcpy(&out.file_id, body[0..16]);
    const data = body[16..];
    if (data.len % 20 != 0) return error.InvalidInput;
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
    if (!std.mem.eql(u8, &hdr.packet_type, &recvslic_type)) return error.InvalidInput;
    if (hdr.length < 64 + 4) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    const exponent = bytes.readU32Le(body, 0) catch return error.OutOfBounds;
    return .{ .exponent = exponent, .data = body[4..] };
}

pub fn parsePackedRecvSlic(buf: []const u8) PacketTypeError!PackedRecvSlicPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &pkdrecvs_type)) return error.InvalidInput;
    if (hdr.length < 64 + 4) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    const exponent = bytes.readU32Le(body, 0) catch return error.OutOfBounds;
    return .{ .exponent = exponent, .data = body[4..] };
}

pub fn parseFileSlic(buf: []const u8) PacketTypeError!FileSlicPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &fileslic_type)) return error.InvalidInput;
    if (hdr.length < 64 + 24) return error.InvalidInput;
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
    if (!std.mem.eql(u8, &hdr.packet_type, &rfsc_type)) return error.InvalidInput;
    if (hdr.length < 64 + 16) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    var out: RfscPacket = undefined;
    @memcpy(&out.file_id, body[0..16]);
    const data = body[16..];
    if ((data.len % 24) != 0) return error.InvalidInput;
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

pub fn parseValidationState(buf: []const u8) PacketTypeError!ValidationStatePacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &sfvs_type)) return error.InvalidInput;
    // Body is 36 bytes: 16 (file_id) + 2 (version) + 1 (flags) + 1 (reserved) + 4 (container) + 4 (subtype) + 8 (reserved)
    if (hdr.length < 64 + 36) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    if (body.len < 36) return error.InvalidInput;
    var out: ValidationStatePacket = undefined;
    @memcpy(&out.file_id, body[0..16]);
    out.version = bytes.readU16Le(body, 16) catch return error.OutOfBounds;
    out.flags = body[18];
    out.reserved1 = body[19];
    @memcpy(&out.container, body[20..24]);
    @memcpy(&out.subtype, body[24..28]);
    @memcpy(&out.reserved2, body[28..36]);
    return out;
}

/// Parse an Apple Extended Attributes (AAPL) packet.
/// Body format: File ID (16) + Version (2) + xattr_count (2) + xattr entries
pub fn parseAapl(buf: []const u8, allocator: std.mem.Allocator) PacketTypeError!AaplPacket {
    const hdr = packet.parseHeader(buf) catch return error.OutOfBounds;
    if (!std.mem.eql(u8, &hdr.packet_type, &aapl_type)) return error.InvalidInput;
    // Minimum body: 16 (file_id) + 2 (version) + 2 (xattr_count) = 20 bytes
    if (hdr.length < 64 + 20) return error.InvalidInput;
    const end: usize = @intCast(hdr.length);
    const body = buf[64..end];
    if (body.len < 20) return error.InvalidInput;

    var out: AaplPacket = undefined;
    @memcpy(&out.file_id, body[0..16]);
    out.version = bytes.readU16Le(body, 16) catch return error.OutOfBounds;
    const xattr_count = bytes.readU16Le(body, 18) catch return error.OutOfBounds;

    // Parse xattr entries
    var entries = try allocator.alloc(XattrEntry, xattr_count);
    var offset: usize = 20;
    var i: usize = 0;
    while (i < xattr_count) : (i += 1) {
        if (offset + 6 > body.len) {
            allocator.free(entries);
            return error.OutOfBounds;
        }
        const name_len = bytes.readU16Le(body, offset) catch {
            allocator.free(entries);
            return error.OutOfBounds;
        };
        const value_len = bytes.readU32Le(body, offset + 2) catch {
            allocator.free(entries);
            return error.OutOfBounds;
        };
        offset += 6;

        if (offset + name_len > body.len) {
            allocator.free(entries);
            return error.OutOfBounds;
        }
        const name = try allocator.alloc(u8, name_len);
        @memcpy(name, body[offset .. offset + name_len]);
        offset += name_len;

        if (offset + value_len > body.len) {
            allocator.free(name);
            allocator.free(entries);
            return error.OutOfBounds;
        }
        const value = try allocator.alloc(u8, value_len);
        @memcpy(value, body[offset .. offset + value_len]);
        offset += value_len;

        entries[i] = .{ .name = name, .value = value };
    }

    out.xattrs = entries;
    return out;
}

test "ValidationFlags values are distinct and correct" {
    // Each flag should have a unique bit position
    try std.testing.expectEqual(@as(u8, 0x01), ValidationFlags.MAGIC);
    try std.testing.expectEqual(@as(u8, 0x02), ValidationFlags.STRUCTURE);
    try std.testing.expectEqual(@as(u8, 0x04), ValidationFlags.CHECKSUM);
    try std.testing.expectEqual(@as(u8, 0x08), ValidationFlags.DECODE);
    try std.testing.expectEqual(@as(u8, 0x10), ValidationFlags.CHARSET);
    try std.testing.expectEqual(@as(u8, 0x20), ValidationFlags.SEMANTIC);
    try std.testing.expectEqual(@as(u8, 0x40), ValidationFlags.ENCRYPTED);
    try std.testing.expectEqual(@as(u8, 0x80), ValidationFlags.COMPLETE);

    // Verify flags don't overlap
    const all_flags = ValidationFlags.MAGIC | ValidationFlags.STRUCTURE |
        ValidationFlags.CHECKSUM | ValidationFlags.DECODE |
        ValidationFlags.CHARSET | ValidationFlags.SEMANTIC |
        ValidationFlags.ENCRYPTED | ValidationFlags.COMPLETE;
    try std.testing.expectEqual(@as(u8, 0xFF), all_flags);
}

test "ENCRYPTED flag can be combined with validation depth flags" {
    // Encrypted file with structural validation only
    const encrypted_structural = ValidationFlags.MAGIC | ValidationFlags.STRUCTURE | ValidationFlags.ENCRYPTED;
    try std.testing.expectEqual(@as(u8, 0x43), encrypted_structural);

    // Encrypted file with checksum validation (e.g., ZIP with some encrypted entries)
    const encrypted_checksum = ValidationFlags.MAGIC | ValidationFlags.STRUCTURE |
        ValidationFlags.CHECKSUM | ValidationFlags.ENCRYPTED;
    try std.testing.expectEqual(@as(u8, 0x47), encrypted_checksum);

    // Verify ENCRYPTED flag is set in combined flags
    try std.testing.expect((encrypted_structural & ValidationFlags.ENCRYPTED) != 0);
    try std.testing.expect((encrypted_checksum & ValidationFlags.ENCRYPTED) != 0);
}
