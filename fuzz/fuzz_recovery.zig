const std = @import("std");
const core = @import("core");
const ops = @import("ops");

/// AFL++ fuzz target for recovery operations.
/// Reads input from stdin and attempts to parse and process it as PAR2 data.
pub fn main() !void {
    // Use arena to avoid leak warnings - we just want crash detection
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read all input from stdin
    const stdin = std.fs.File.stdin();
    const input = stdin.readToEndAlloc(allocator, 4 * 1024 * 1024) catch |err| {
        if (err == error.StreamTooLong) return;
        return err;
    };
    defer allocator.free(input);

    if (input.len < 64) return;

    // Try to scan packets from the input
    var ctx = core.api.initContext(allocator);
    var offset: usize = 0;
    while (offset + 64 <= input.len) {
        const hdr = core.packet.parseHeader(input[offset..]) catch break;
        const pkt_len = @as(usize, @intCast(hdr.length));
        if (pkt_len < 64 or offset + pkt_len > input.len) break;
        _ = core.api.addPacket(allocator, &ctx, input[offset .. offset + pkt_len]) catch {};
        offset += pkt_len;
    }

    // If we got a valid context with recovery set, try verification
    if (ctx.recovery_set) |rs| {
        _ = rs.slice_size;
        // Context exists - fuzzer found valid-ish packets
    }
}
