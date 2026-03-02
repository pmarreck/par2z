const std = @import("std");
const builtin = @import("builtin");

// ===== Feature detection =====

/// Returns true if the target supports ARM CRC32 hardware instructions.
pub fn hasCrc32Hw() bool {
    if (builtin.cpu.arch == .aarch64) {
        return std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
    }
    return false;
}

// ===== Standard CRC32 lookup table (comptime) =====

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

// ===== Slice-by-8 extended tables (comptime) =====

const tables8: [8][256]u32 = initTables8();

fn initTables8() [8][256]u32 {
    @setEvalBranchQuota(50000);
    var t: [8][256]u32 = undefined;
    t[0] = initTable();
    for (1..8) |k| {
        for (0..256) |i| {
            t[k][i] = t[0][t[k - 1][i] & 0xFF] ^ (t[k - 1][i] >> 8);
        }
    }
    return t;
}

// ===== Scalar implementation (byte-by-byte, reference) =====

pub fn crc32Scalar(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        const idx = (crc ^ @as(u32, b)) & 0xFF;
        crc = (crc >> 8) ^ table[@as(usize, @intCast(idx))];
    }
    return ~crc;
}

// ===== Slice-by-8 implementation =====

fn crc32SliceBy8(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    var i: usize = 0;
    const len = data.len;

    while (i + 8 <= len) : (i += 8) {
        const p = crc ^ std.mem.readInt(u32, data[i..][0..4], .little);
        const q = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        crc = tables8[7][@as(usize, @intCast(p & 0xFF))] ^
            tables8[6][@as(usize, @intCast((p >> 8) & 0xFF))] ^
            tables8[5][@as(usize, @intCast((p >> 16) & 0xFF))] ^
            tables8[4][@as(usize, @intCast(p >> 24))] ^
            tables8[3][@as(usize, @intCast(q & 0xFF))] ^
            tables8[2][@as(usize, @intCast((q >> 8) & 0xFF))] ^
            tables8[1][@as(usize, @intCast((q >> 16) & 0xFF))] ^
            tables8[0][@as(usize, @intCast(q >> 24))];
    }

    while (i < len) : (i += 1) {
        const idx = (crc ^ @as(u32, data[i])) & 0xFF;
        crc = (crc >> 8) ^ table[@as(usize, @intCast(idx))];
    }

    return ~crc;
}

// ===== ARM hardware CRC32 implementation =====

fn crc32Hw(data: []const u8) u32 {
    if (comptime !hasCrc32Hw()) @compileError("ARM CRC32 not available");
    var crc: u32 = 0xFFFFFFFF;
    var i: usize = 0;
    const len = data.len;

    // Process 8 bytes at a time: crc32x Wd, Wn, Xm
    // Pin CRC to x8 (referenced as w8), data register is free (u64 → X reg)
    while (i + 8 <= len) : (i += 8) {
        const word = std.mem.readInt(u64, data[i..][0..8], .little);
        crc = asm ("crc32x w8, w8, %[data]"
            : [_] "={x8}" (-> u32),
            : [_] "{x8}" (crc),
              [data] "r" (word),
        );
    }

    // Process 4 bytes: crc32w Wd, Wn, Wm (pin both to get W regs)
    if (i + 4 <= len) {
        const word = std.mem.readInt(u32, data[i..][0..4], .little);
        crc = asm ("crc32w w8, w8, w9"
            : [_] "={x8}" (-> u32),
            : [_] "{x8}" (crc),
              [_] "{x9}" (word),
        );
        i += 4;
    }

    // Process 2 bytes: crc32h Wd, Wn, Wm
    if (i + 2 <= len) {
        const half: u32 = std.mem.readInt(u16, data[i..][0..2], .little);
        crc = asm ("crc32h w8, w8, w9"
            : [_] "={x8}" (-> u32),
            : [_] "{x8}" (crc),
              [_] "{x9}" (half),
        );
        i += 2;
    }

    // Process 1 byte: crc32b Wd, Wn, Wm
    if (i < len) {
        const byte: u32 = data[i];
        crc = asm ("crc32b w8, w8, w9"
            : [_] "={x8}" (-> u32),
            : [_] "{x8}" (crc),
              [_] "{x9}" (byte),
        );
    }

    return ~crc;
}

// ===== Public API (dispatches to fastest available) =====

pub fn crc32(data: []const u8) u32 {
    if (comptime hasCrc32Hw()) {
        return crc32Hw(data);
    } else {
        return crc32SliceBy8(data);
    }
}

// ===== Tests =====

test "crc32 standard check value all implementations" {
    const data = "123456789";
    const expected: u32 = 0xCBF43926;
    try std.testing.expectEqual(expected, crc32Scalar(data));
    try std.testing.expectEqual(expected, crc32SliceBy8(data));
    if (comptime hasCrc32Hw()) {
        try std.testing.expectEqual(expected, crc32Hw(data));
    }
    try std.testing.expectEqual(expected, crc32(data));
}

test "crc32 slice-by-8 matches scalar" {
    const test_strings = [_][]const u8{
        "",
        "a",
        "ab",
        "abc",
        "abcdefg",
        "abcdefgh",
        "abcdefghijklmnop",
        "The quick brown fox jumps over the lazy dog",
    };
    for (test_strings) |data| {
        try std.testing.expectEqual(crc32Scalar(data), crc32SliceBy8(data));
    }
    // Test all sizes 0..1024 with pseudo-random data
    var buf: [1024]u8 = undefined;
    for (0..buf.len) |i| {
        buf[i] = @truncate(i *% 137 +% 42);
    }
    for (0..buf.len + 1) |size| {
        try std.testing.expectEqual(crc32Scalar(buf[0..size]), crc32SliceBy8(buf[0..size]));
    }
}

test "crc32 hw matches scalar" {
    if (comptime !hasCrc32Hw()) return;
    const test_strings = [_][]const u8{
        "",
        "a",
        "ab",
        "abc",
        "abcdefg",
        "abcdefgh",
        "abcdefghijklmnop",
        "The quick brown fox jumps over the lazy dog",
    };
    for (test_strings) |data| {
        try std.testing.expectEqual(crc32Scalar(data), crc32Hw(data));
    }
    // Test all sizes 0..1024 with pseudo-random data
    var buf: [1024]u8 = undefined;
    for (0..buf.len) |i| {
        buf[i] = @truncate(i *% 137 +% 42);
    }
    for (0..buf.len + 1) |size| {
        try std.testing.expectEqual(crc32Scalar(buf[0..size]), crc32Hw(buf[0..size]));
    }
}

test "crc32 benchmark" {
    const size = 16 * 1024;
    var buf: [size]u8 = undefined;
    for (0..size) |i| {
        buf[i] = @truncate(i *% 137 +% 42);
    }
    const iters = 10000;

    std.debug.print("\n--- CRC32 Benchmark ({d} KiB x {d} iters) ---\n", .{ size / 1024, iters });
    std.debug.print("ARM CRC32 HW available: {}\n", .{hasCrc32Hw()});

    // Scalar
    {
        var checksum: u32 = 0;
        const start = std.time.nanoTimestamp();
        for (0..iters) |_| {
            checksum +%= crc32Scalar(&buf);
        }
        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const bytes = @as(u64, size) * iters;
        const mib_per_sec = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0;
        std.debug.print("Scalar:     {d:>8.1} MiB/s (checksum: {x})\n", .{ mib_per_sec, checksum });
    }

    // Slice-by-8
    {
        var checksum: u32 = 0;
        const start = std.time.nanoTimestamp();
        for (0..iters) |_| {
            checksum +%= crc32SliceBy8(&buf);
        }
        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const bytes = @as(u64, size) * iters;
        const mib_per_sec = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0;
        std.debug.print("Slice-by-8: {d:>8.1} MiB/s (checksum: {x})\n", .{ mib_per_sec, checksum });
    }

    // HW (if available)
    if (comptime hasCrc32Hw()) {
        var checksum: u32 = 0;
        const start = std.time.nanoTimestamp();
        for (0..iters) |_| {
            checksum +%= crc32Hw(&buf);
        }
        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const bytes = @as(u64, size) * iters;
        const mib_per_sec = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0;
        std.debug.print("HW CRC32:   {d:>8.1} MiB/s (checksum: {x})\n", .{ mib_per_sec, checksum });
    }

    // Dispatched
    {
        var checksum: u32 = 0;
        const start = std.time.nanoTimestamp();
        for (0..iters) |_| {
            checksum +%= crc32(&buf);
        }
        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const bytes = @as(u64, size) * iters;
        const mib_per_sec = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0;
        std.debug.print("Dispatched: {d:>8.1} MiB/s (checksum: {x})\n", .{ mib_per_sec, checksum });
    }
}
