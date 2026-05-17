const std = @import("std");
const crc32 = @import("crc32.zig");
const md5 = @import("md5.zig");
const hash_algo = @import("hash_algo.zig");
const types = @import("packet_types.zig");

pub const SliceError = error{
    OutOfMemory,
    CryptoUnavailable,
    InvalidInput,
    Mismatch,
};

pub fn sliceCount(file_length: u64, slice_size: usize) SliceError!usize {
    if (slice_size == 0) return error.InvalidInput;
    const len = std.math.cast(usize, file_length) orelse return error.InvalidInput;
    const add = @addWithOverflow(len, slice_size - 1);
    if (add[1] != 0) return error.InvalidInput;
    return add[0] / slice_size;
}

pub fn computeIfscEntries(allocator: std.mem.Allocator, data: []const u8, slice_size: usize) SliceError![]types.IfscEntry {
    return computeIfscEntriesAlgo(allocator, data, slice_size, .md5);
}

pub fn computeIfscEntriesAlgo(allocator: std.mem.Allocator, data: []const u8, slice_size: usize, algo: hash_algo.HashAlgo) SliceError![]types.IfscEntry {
    if (slice_size == 0) return error.InvalidInput;
    const slice_count = (data.len + slice_size - 1) / slice_size;
    var entries = try allocator.alloc(types.IfscEntry, slice_count);
    var i: usize = 0;
    while (i < slice_count) : (i += 1) {
        const start = i * slice_size;
        const end = @min(start + slice_size, data.len);
        const chunk = data[start..end];
        if (chunk.len == slice_size) {
            computeIfscEntryAlgo(chunk, &entries[i], algo);
        } else {
            var tmp = try allocator.alloc(u8, slice_size);
            defer allocator.free(tmp);
            @memset(tmp, 0);
            @memcpy(tmp[0..chunk.len], chunk);
            computeIfscEntryAlgo(tmp, &entries[i], algo);
        }
    }
    return entries;
}

pub fn computeIfscEntry(slice: []const u8, out: *types.IfscEntry) SliceError!void {
    computeIfscEntryAlgo(slice, out, .md5);
}

pub fn computeIfscEntryAlgo(slice: []const u8, out: *types.IfscEntry, algo: hash_algo.HashAlgo) void {
    hash_algo.hashDigest(algo, slice, &out.md5);
    out.crc32 = crc32.crc32(slice);
}

pub fn verifyIfsc(computed: []const types.IfscEntry, expected: []const types.IfscEntry) SliceError!void {
    if (computed.len != expected.len) return error.Mismatch;
    var i: usize = 0;
    while (i < computed.len) : (i += 1) {
        if (!std.mem.eql(u8, &computed[i].md5, &expected[i].md5)) return error.Mismatch;
        if (computed[i].crc32 != expected[i].crc32) return error.Mismatch;
    }
}

pub fn findMismatchedSlices(allocator: std.mem.Allocator, computed: []const types.IfscEntry, expected: []const types.IfscEntry) SliceError![]usize {
    if (computed.len != expected.len) return error.Mismatch;
    var count: usize = 0;
    var i: usize = 0;
    while (i < computed.len) : (i += 1) {
        if (!std.mem.eql(u8, &computed[i].md5, &expected[i].md5) or computed[i].crc32 != expected[i].crc32) {
            count += 1;
        }
    }
    var out = try allocator.alloc(usize, count);
    var idx: usize = 0;
    i = 0;
    while (i < computed.len) : (i += 1) {
        if (!std.mem.eql(u8, &computed[i].md5, &expected[i].md5) or computed[i].crc32 != expected[i].crc32) {
            out[idx] = i;
            idx += 1;
        }
    }
    return out;
}
