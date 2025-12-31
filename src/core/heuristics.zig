const std = @import("std");

pub fn blockSizeHeuristic(file_size: u64) u64 {
    if (file_size == 0) return 4;
    const k = @as(f64, @floatFromInt(file_size)) / 1024.0;
    const percent = 1.2 + 2.0 * std.math.exp(-0.001 * k) + 21.0 * std.math.exp(-0.3 * k);
    const raw = @as(f64, @floatFromInt(file_size)) * percent / 100.0;
    var block_size: u64 = if (raw <= 0) 4 else @as(u64, @intFromFloat(raw));
    if (block_size < 4) block_size = 4;
    if ((block_size % 4) != 0) {
        block_size = (block_size + 3) / 4 * 4;
    }
    return block_size;
}
