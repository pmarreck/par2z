const std = @import("std");
const core = @import("core");

/// AFL++ fuzz target for packet parsing.
/// Reads input from stdin and attempts to parse it as various PAR2 packet types.
pub fn main() !void {
    // Use arena to avoid leak warnings - we just want crash detection
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read all input from stdin (AFL++ provides input this way)
    const stdin = std.fs.File.stdin();
    const input = stdin.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        if (err == error.StreamTooLong) return; // Input too large, skip
        return err;
    };
    defer allocator.free(input);

    if (input.len < 64) return; // Too small for any valid packet

    // Try parsing as each packet type - crashes indicate bugs
    _ = core.packet.parseHeader(input) catch {};
    _ = core.packet_types.parseCreator(input) catch {};
    _ = core.packet_types.parseMain(input, allocator) catch {};
    _ = core.packet_types.parsePackedMain(input, allocator) catch {};
    _ = core.packet_types.parseFileDesc(input, allocator) catch {};
    _ = core.packet_types.parseIfsc(input, allocator) catch {};
    _ = core.packet_types.parseRecvSlic(input) catch {};
    _ = core.packet_types.parsePackedRecvSlic(input) catch {};
    _ = core.packet_types.parseFileSlic(input) catch {};
    _ = core.packet_types.parseRfsc(input, allocator) catch {};
}
