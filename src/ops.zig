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
