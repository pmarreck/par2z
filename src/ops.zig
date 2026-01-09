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
