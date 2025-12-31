const std = @import("std");
const core = @import("core");

/// AFL++ fuzz target for packet parsing.
/// Reads input from stdin and attempts to parse it as various PAR2 packet types.
/// Uses GPA to detect memory leaks - any leak will cause a non-zero exit.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.process.exit(1); // Signal leak to fuzzer
        }
    }
    const allocator = gpa.allocator();

    // Read all input from stdin (AFL++ provides input this way)
    const stdin = std.fs.File.stdin();
    const input = stdin.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        if (err == error.StreamTooLong) return; // Input too large, skip
        return err;
    };
    defer allocator.free(input);

    if (input.len < 64) return; // Too small for any valid packet

    // Try parsing as each packet type - crashes or leaks indicate bugs
    // Non-allocating parsers
    _ = core.packet.parseHeader(input) catch {};
    _ = core.packet_types.parseCreator(input) catch {};
    _ = core.packet_types.parseRecvSlic(input) catch {};
    _ = core.packet_types.parsePackedRecvSlic(input) catch {};
    _ = core.packet_types.parseFileSlic(input) catch {};

    // Allocating parsers - must free on success
    if (core.packet_types.parseMain(input, allocator)) |pkt| {
        allocator.free(pkt.recovery_file_ids);
        allocator.free(pkt.non_recovery_file_ids);
    } else |_| {}

    if (core.packet_types.parsePackedMain(input, allocator)) |pkt| {
        allocator.free(pkt.recovery_file_ids);
        allocator.free(pkt.non_recovery_file_ids);
    } else |_| {}

    if (core.packet_types.parseFileDesc(input, allocator)) |pkt| {
        allocator.free(pkt.file_name);
    } else |_| {}

    if (core.packet_types.parseIfsc(input, allocator)) |pkt| {
        allocator.free(pkt.entries);
    } else |_| {}

    if (core.packet_types.parseRfsc(input, allocator)) |pkt| {
        allocator.free(pkt.entries);
    } else |_| {}
}
