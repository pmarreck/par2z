const std = @import("std");
const core = @import("core");
const common = @import("ops/common.zig");
const create_mod = @import("ops/create.zig");
const verify_mod = @import("ops/verify.zig");
const recover_mod = @import("ops/recover.zig");

pub const CreateOptions = common.CreateOptions;
pub const RecoverOptions = common.RecoverOptions;
pub const VerifyOptions = common.VerifyOptions;
pub const OutputTarget = common.OutputTarget;
pub const OutputOpener = common.OutputOpener;
pub const StreamInput = common.StreamInput;
pub const LimitedAllocator = common.LimitedAllocator;
pub const transliterateAscii = common.transliterateAscii;
pub const InsufficientRecoveryDetails = recover_mod.InsufficientRecoveryDetails;

// Re-export core types needed for creating/reading parity metadata
pub const SourceMetadataPacket = core.packet_types.SourceMetadataPacket;

pub fn stdoutToStderrEnabled() bool {
    return common.stdoutToStderrEnabled();
}

pub const create = create_mod.create;
pub const createStreams = create_mod.createStreams;
pub const verify = verify_mod.verify;
pub const verifyStreams = verify_mod.verifyStreams;
pub const recover = recover_mod.recover;
pub const recoverStreams = recover_mod.recoverStreams;

pub fn takeLastInsufficientRecovery() ?InsufficientRecoveryDetails {
    return recover_mod.takeLastInsufficientRecovery();
}

/// Updates the source_ctime_ns field in the SFMD packet within PAR2 data.
/// Modifies the data in place and recomputes the packet's MD5 hash.
/// Returns error.NotFound if no SFMD packet exists.
///
/// This is used by the bitrot simulator to make simulated corruption appear
/// as real corruption to the change detection heuristic.
pub fn updateSourceMetadataCtime(par2_bytes: []u8, new_ctime_ns: i64) !void {
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;

        // Check if this is an SFMD packet
        if (std.mem.eql(u8, &hdr.packet_type, &core.packet_types.source_metadata_type)) {
            // Verify packet hash before modifying
            core.packet.verifyPacketHash(remaining[0..end]) catch {
                offset += end - 1;
                continue;
            };

            // Get mutable slice for this packet
            const pkt = par2_bytes[offset .. offset + end];

            // Update ctime field at body offset 12 (header is 64 bytes, ctime is at body+12)
            // Body layout: version(2) + flags(2) + mtime(8) + ctime(8) + ...
            const ctime_offset = 64 + 12;
            if (ctime_offset + 8 > pkt.len) return error.DataCorrupt;

            // Write new ctime as little-endian i64
            const ctime_u64: u64 = @bitCast(new_ctime_ns);
            pkt[ctime_offset + 0] = @truncate(ctime_u64);
            pkt[ctime_offset + 1] = @truncate(ctime_u64 >> 8);
            pkt[ctime_offset + 2] = @truncate(ctime_u64 >> 16);
            pkt[ctime_offset + 3] = @truncate(ctime_u64 >> 24);
            pkt[ctime_offset + 4] = @truncate(ctime_u64 >> 32);
            pkt[ctime_offset + 5] = @truncate(ctime_u64 >> 40);
            pkt[ctime_offset + 6] = @truncate(ctime_u64 >> 48);
            pkt[ctime_offset + 7] = @truncate(ctime_u64 >> 56);

            // Recompute MD5 hash of bytes 32 to end (recovery_set_id + packet_type + body)
            var digest: [16]u8 = undefined;
            core.md5.md5Digest(pkt[32..end], &digest) catch return error.CryptoUnavailable;

            // Write new hash at offset 16-31
            @memcpy(pkt[16..32], &digest);

            return; // Success
        }
        offset += end - 1;
    }
    return error.NotFound;
}

/// Updates both mtime and ctime in the SFMD packet within PAR2 data.
/// Modifies the data in place and recomputes the packet's MD5 hash.
/// Returns error.NotFound if no SFMD packet exists.
///
/// This is used by the bitrot simulator to sync stored metadata with
/// the file's current metadata after simulating corruption.
pub fn updateSourceMetadataTimestamps(par2_bytes: []u8, new_mtime_ns: i64, new_ctime_ns: i64) !void {
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;

        // Check if this is an SFMD packet
        if (std.mem.eql(u8, &hdr.packet_type, &core.packet_types.source_metadata_type)) {
            // Verify packet hash before modifying
            core.packet.verifyPacketHash(remaining[0..end]) catch {
                offset += end - 1;
                continue;
            };

            // Get mutable slice for this packet
            const pkt = par2_bytes[offset .. offset + end];

            // Body layout: version(2) + flags(2) + mtime(8) + ctime(8) + ...
            const mtime_offset = 64 + 4;
            const ctime_offset = 64 + 12;
            if (ctime_offset + 8 > pkt.len) return error.DataCorrupt;

            // Write new mtime as little-endian i64
            const mtime_u64: u64 = @bitCast(new_mtime_ns);
            pkt[mtime_offset + 0] = @truncate(mtime_u64);
            pkt[mtime_offset + 1] = @truncate(mtime_u64 >> 8);
            pkt[mtime_offset + 2] = @truncate(mtime_u64 >> 16);
            pkt[mtime_offset + 3] = @truncate(mtime_u64 >> 24);
            pkt[mtime_offset + 4] = @truncate(mtime_u64 >> 32);
            pkt[mtime_offset + 5] = @truncate(mtime_u64 >> 40);
            pkt[mtime_offset + 6] = @truncate(mtime_u64 >> 48);
            pkt[mtime_offset + 7] = @truncate(mtime_u64 >> 56);

            // Write new ctime as little-endian i64
            const ctime_u64: u64 = @bitCast(new_ctime_ns);
            pkt[ctime_offset + 0] = @truncate(ctime_u64);
            pkt[ctime_offset + 1] = @truncate(ctime_u64 >> 8);
            pkt[ctime_offset + 2] = @truncate(ctime_u64 >> 16);
            pkt[ctime_offset + 3] = @truncate(ctime_u64 >> 24);
            pkt[ctime_offset + 4] = @truncate(ctime_u64 >> 32);
            pkt[ctime_offset + 5] = @truncate(ctime_u64 >> 40);
            pkt[ctime_offset + 6] = @truncate(ctime_u64 >> 48);
            pkt[ctime_offset + 7] = @truncate(ctime_u64 >> 56);

            // Recompute MD5 hash of bytes 32 to end (recovery_set_id + packet_type + body)
            var digest: [16]u8 = undefined;
            core.md5.md5Digest(pkt[32..end], &digest) catch return error.CryptoUnavailable;

            // Write new hash at offset 16-31
            @memcpy(pkt[16..32], &digest);

            return; // Success
        }
        offset += end - 1;
    }
    return error.NotFound;
}

/// Extracts source file metadata (SFMD packet) from PAR2 data.
/// Returns null if no SFMD packet is found.
/// This scans the PAR2 bytes for the SFMD packet and returns its contents.
pub fn extractSourceMetadata(par2_bytes: []const u8) !?SourceMetadataPacket {
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            offset += end - 1;
            continue;
        };
        if (std.mem.eql(u8, &hdr.packet_type, &core.packet_types.source_metadata_type)) {
            const meta = core.packet_types.parseSourceMetadata(pkt) catch return error.DataCorrupt;
            return meta;
        }
        offset += end - 1;
    }
    return null;
}

pub const ValidationStatePacket = core.packet_types.ValidationStatePacket;

/// Extracts source file validation state (SFVS packet) from PAR2 data.
/// Returns null if no SFVS packet is found.
/// This scans the PAR2 bytes for the SFVS packet and returns its contents.
pub fn extractValidationState(par2_bytes: []const u8) !?ValidationStatePacket {
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            offset += end - 1;
            continue;
        };
        if (std.mem.eql(u8, &hdr.packet_type, &core.packet_types.validation_state_type)) {
            const state = core.packet_types.parseValidationState(pkt) catch return error.DataCorrupt;
            return state;
        }
        offset += end - 1;
    }
    return null;
}

pub const AaplPacket = core.packet_types.AaplPacket;
pub const XattrEntry = core.packet_types.XattrEntry;

/// Extracts Apple extended attributes (AAPL packet) from PAR2 data.
/// Returns null if no AAPL packet is found.
/// Caller owns the returned memory (xattr names and values).
pub fn extractAapl(allocator: std.mem.Allocator, par2_bytes: []const u8) !?AaplPacket {
    var offset: usize = 0;
    while (offset + 64 <= par2_bytes.len) : (offset += 1) {
        const remaining = par2_bytes[offset..];
        const hdr = core.packet.parseHeader(remaining) catch {
            continue;
        };
        const end: usize = @intCast(hdr.length);
        if (end > remaining.len) break;
        const pkt = remaining[0..end];
        core.packet.verifyPacketHash(pkt) catch {
            offset += end - 1;
            continue;
        };
        if (std.mem.eql(u8, &hdr.packet_type, &core.packet_types.apple_xattr_type)) {
            const aapl = core.packet_types.parseAapl(pkt, allocator) catch return error.DataCorrupt;
            return aapl;
        }
        offset += end - 1;
    }
    return null;
}

/// Options for creating directory metadata (.par2d) files.
pub const DirectoryMetadataOptions = struct {
    dir_path: []const u8, // Path with trailing slash, e.g., "photos/vacation/"
    metadata: ?SourceMetadataPacket,
    aapl_packet: ?AaplPacket,
};

/// Creates a directory metadata container (.par2d).
/// Contains Main, FileDesc, SFMD, and optionally AAPL packets.
/// No recovery data since directories have no content.
pub fn createDirectoryMetadata(allocator: std.mem.Allocator, opts: DirectoryMetadataOptions) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Ensure path has trailing slash
    const dir_path = if (opts.dir_path.len > 0 and opts.dir_path[opts.dir_path.len - 1] != '/')
        try std.fmt.allocPrint(arena_alloc, "{s}/", .{opts.dir_path})
    else
        opts.dir_path;

    // Compute file ID for directory
    const file_id = try core.file_id.directoryId(arena_alloc, dir_path);

    // Build Main packet body (slice_size = 0, 1 file)
    const main_body = try core.create_packets.buildMainBody(arena_alloc, 0, &.{file_id});

    // Compute recovery set ID (MD5 of main body)
    var recovery_set_id: [16]u8 = undefined;
    try core.md5.md5Digest(main_body, &recovery_set_id);

    // Build packets
    var packets = std.ArrayList([]const u8).empty;
    defer packets.deinit(arena_alloc);

    // Creator packet
    const creator_pkt = try core.create_packets.buildCreatorPacket(arena_alloc, recovery_set_id, "par2z");
    try packets.append(arena_alloc, creator_pkt);

    // Main packet
    const main_pkt = try core.create_packets.buildMainPacket(arena_alloc, recovery_set_id, main_body);
    try packets.append(arena_alloc, main_pkt);

    // FileDesc packet (size = 0 for directory)
    const empty_md5: [16]u8 = .{ 0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, 0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e };
    const filedesc_pkt = try core.create_packets.buildFileDescPacket(
        arena_alloc,
        recovery_set_id,
        file_id,
        empty_md5,
        empty_md5,
        0,
        dir_path,
    );
    try packets.append(arena_alloc, filedesc_pkt);

    // SFMD packet if metadata provided
    if (opts.metadata) |meta| {
        const sfmd_pkt = try core.create_packets.buildSourceMetadataPacket(arena_alloc, recovery_set_id, meta);
        try packets.append(arena_alloc, sfmd_pkt);
    }

    // AAPL packet if xattrs provided
    if (opts.aapl_packet) |aapl| {
        var ap = aapl;
        ap.file_id = file_id;
        const aapl_pkt = try core.create_packets.buildAaplPacket(arena_alloc, recovery_set_id, ap);
        try packets.append(arena_alloc, aapl_pkt);
    }

    // Concatenate all packets
    var total_len: usize = 0;
    for (packets.items) |pkt| {
        total_len += pkt.len;
    }

    var output = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (packets.items) |pkt| {
        @memcpy(output[offset .. offset + pkt.len], pkt);
        offset += pkt.len;
    }

    return output;
}

// Pull inline `test` blocks from the ops submodules into the `test-ops` binary
// (same-module `_ = decl` reference; a cross-module ref from tests/tests.zig
// cannot). create/recover/common carry path-safety + arg/format unit tests.
test {
    _ = common;
    _ = create_mod;
    _ = verify_mod;
    _ = recover_mod;
}
