const std = @import("std");

const table: [256]u32 = initTable();

fn initTable() [256]u32 {
    @setEvalBranchQuota(20000);
    var t: [256]u32 = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var c = i;
        var j: u32 = 0;
        while (j < 8) : (j += 1) {
            if ((c & 1) != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c >>= 1;
            }
        }
        t[@as(usize, @intCast(i))] = c;
    }
    return t;
}

pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        const idx = (crc ^ @as(u32, b)) & 0xFF;
        crc = (crc >> 8) ^ table[@as(usize, @intCast(idx))];
    }
    return ~crc;
}
