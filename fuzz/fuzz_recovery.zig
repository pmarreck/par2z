const std = @import("std");
const core = @import("core");

/// AFL++ fuzz target for recovery operations.
/// Reads input from stdin and attempts to parse and process it as PAR2 data.
/// Uses GPA to detect memory leaks - any leak will cause a non-zero exit.
///
/// Note: Par2Context currently lacks a deinit function, so we use an arena
/// for context allocations. This is acceptable as the context is designed
/// to live for the duration of processing. The arena ensures no leaks.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.process.exit(1); // Signal leak to fuzzer
        }
    }
    const allocator = gpa.allocator();

    // Use arena for context allocations (context lacks deinit)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx_allocator = arena.allocator();

    // Read all input from stdin
    const stdin = std.Io.File.stdin();
    const input = stdin.readToEndAlloc(allocator, 4 * 1024 * 1024) catch |err| {
        if (err == error.StreamTooLong) return;
        return err;
    };
    defer allocator.free(input);

    if (input.len < 64) return;

    // Try to scan packets from the input
    var ctx = core.api.initContext(ctx_allocator);
    var offset: usize = 0;
    while (offset + 64 <= input.len) {
        const hdr = core.packet.parseHeader(input[offset..]) catch break;
        const pkt_len = @as(usize, @intCast(hdr.length));
        if (pkt_len < 64 or offset + pkt_len > input.len) break;
        _ = core.api.addPacket(ctx_allocator, &ctx, input[offset .. offset + pkt_len]) catch {};
        offset += pkt_len;
    }

    // If we got a valid context with recovery set, the fuzzer found valid-ish packets
    // The arena cleanup handles all context allocations
    _ = ctx.recovery_set;
}
