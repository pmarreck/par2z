const std = @import("std");
const gf = @import("gf16.zig");
const thread_pool = @import("thread_pool.zig");

pub const RsError = error{
    InvalidInput,
    OutOfMemory,
    SingularMatrix,
    TooManySlices,
};

pub const RecoverySlice = struct {
    exponent: u32,
    data: []const u8,
};

pub fn accumulateRecoverySlice(out: []u8, data_slice: []const u8, factor: u16) RsError!void {
    if (out.len == 0 or data_slice.len == 0) return error.InvalidInput;
    if (out.len != data_slice.len) return error.InvalidInput;
    if ((out.len % 2) != 0) return error.InvalidInput;
    if (factor == 0) return;
    const word_count = out.len / 2;
    var w: usize = 0;
    while (w < word_count) : (w += 1) {
        const word = readWord(data_slice, w);
        const prod = gf.mul(word, factor);
        const acc = readWord(out, w) ^ prod;
        writeWord(out, w, acc);
    }
}

pub fn encodeRecoverySlice(allocator: std.mem.Allocator, out: []u8, data_slices: []const []const u8, exponent: u32) RsError!void {
    return encodeRecoverySliceParallel(allocator, out, data_slices, exponent);
}

pub fn encodeRecoverySliceSerial(allocator: std.mem.Allocator, out: []u8, data_slices: []const []const u8, exponent: u32) RsError!void {
    if (data_slices.len == 0) return;
    if (data_slices.len > gf.maxValidIndexCount()) return error.TooManySlices;
    const slice_size = data_slices[0].len;
    if (slice_size == 0 or (slice_size % 2) != 0) return error.InvalidInput;
    if (out.len != slice_size) return error.InvalidInput;
    const factors = try allocator.alloc(u16, data_slices.len);
    defer allocator.free(factors);
    var i: usize = 0;
    while (i < data_slices.len) : (i += 1) {
        const slice = data_slices[i];
        if (slice.len != slice_size) return error.InvalidInput;
        const c = gf.constantForIndex(@as(u32, @intCast(i)));
        factors[i] = gf.pow(c, exponent);
    }
    encodeRange(out, data_slices, factors, slice_size, 0, slice_size / 2);
}

fn encodeRecoverySliceParallel(allocator: std.mem.Allocator, out: []u8, data_slices: []const []const u8, exponent: u32) RsError!void {
    if (data_slices.len == 0) return;
    if (data_slices.len > gf.maxValidIndexCount()) return error.TooManySlices;
    const slice_size = data_slices[0].len;
    if (slice_size == 0 or (slice_size % 2) != 0) return error.InvalidInput;
    if (out.len != slice_size) return error.InvalidInput;
    const word_count = slice_size / 2;
    const factors = try allocator.alloc(u16, data_slices.len);
    defer allocator.free(factors);
    var i: usize = 0;
    while (i < data_slices.len) : (i += 1) {
        const slice = data_slices[i];
        if (slice.len != slice_size) return error.InvalidInput;
        const c = gf.constantForIndex(@as(u32, @intCast(i)));
        factors[i] = gf.pow(c, exponent);
    }

    const thread_count = threadCount(word_count);
    if (thread_count == 1) {
        encodeRange(out, data_slices, factors, slice_size, 0, word_count);
        return;
    }
    const pool = thread_pool.getGlobalPool() catch return error.OutOfMemory;
    var ctxs = try allocator.alloc(EncodeCtx, thread_count);
    defer allocator.free(ctxs);

    var t: usize = 0;
    while (t < thread_count) : (t += 1) {
        const start = (word_count * t) / thread_count;
        const end = (word_count * (t + 1)) / thread_count;
        ctxs[t] = .{
            .out = out,
            .data_slices = data_slices,
            .factors = factors,
            .slice_size = slice_size,
            .start_word = start,
            .end_word = end,
        };
    }
    var wg: std.Thread.WaitGroup = .{};
    t = 0;
    while (t + 1 < thread_count) : (t += 1) {
        pool.spawnWg(&wg, encodeRangeThread, .{&ctxs[t]});
    }
    encodeRangeThread(&ctxs[thread_count - 1]);
    wg.wait();
}

pub fn decodeMissingSlices(
    allocator: std.mem.Allocator,
    data_slices: []const ?[]const u8,
    missing_indices: []const usize,
    recovery_slices: []const RecoverySlice,
    slice_size: usize,
) RsError![][]u8 {
    const n = missing_indices.len;
    if (n == 0) return allocator.alloc([]u8, 0);
    if (recovery_slices.len != n) return error.SingularMatrix;
    if (slice_size == 0 or (slice_size % 2) != 0) return error.InvalidInput;
    if (data_slices.len > gf.maxValidIndexCount()) return error.TooManySlices;
    for (missing_indices) |mi| {
        if (mi >= data_slices.len) return error.InvalidInput;
    }
    for (data_slices) |s| {
        if (s) |slice| {
            if (slice.len != slice_size) return error.InvalidInput;
        }
    }

    var matrix = try allocator.alloc(u16, n * n);
    const inv = try allocator.alloc(u16, n * n);
    defer allocator.free(matrix);
    defer allocator.free(inv);

    // Build matrix.
    var row: usize = 0;
    while (row < n) : (row += 1) {
        var col: usize = 0;
        while (col < n) : (col += 1) {
            const idx = missing_indices[col];
            const c = gf.constantForIndex(@as(u32, @intCast(idx)));
            matrix[row * n + col] = gf.pow(c, recovery_slices[row].exponent);
        }
    }

    try invertMatrix(matrix, inv, n);

    var out_slices = try allocator.alloc([]u8, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out_slices[i] = try allocator.alloc(u8, slice_size);
        @memset(out_slices[i], 0);
    }

    const word_count = slice_size / 2;
    const constants = try allocator.alloc(u16, data_slices.len);
    defer allocator.free(constants);
    var idx: usize = 0;
    while (idx < data_slices.len) : (idx += 1) {
        constants[idx] = gf.constantForIndex(@as(u32, @intCast(idx)));
    }
    var present_indices = try allocator.alloc(usize, data_slices.len - n);
    var present_slices = try allocator.alloc([]const u8, data_slices.len - n);
    var pcount: usize = 0;
    idx = 0;
    while (idx < data_slices.len) : (idx += 1) {
        if (data_slices[idx]) |slice| {
            present_indices[pcount] = idx;
            present_slices[pcount] = slice;
            pcount += 1;
        }
    }
    present_indices = present_indices[0..pcount];
    present_slices = present_slices[0..pcount];

    const factors = try allocator.alloc(u16, n * pcount);
    defer allocator.free(factors);
    var r: usize = 0;
    while (r < n) : (r += 1) {
        const exp = recovery_slices[r].exponent;
        var j: usize = 0;
        while (j < pcount) : (j += 1) {
            const idx_c = constants[present_indices[j]];
            factors[r * pcount + j] = gf.pow(idx_c, exp);
        }
    }

    const thread_count = threadCount(word_count);
    var rhs_buf = try allocator.alloc(u16, n * thread_count);
    defer allocator.free(rhs_buf);
    if (thread_count == 1) {
        try decodeRange(word_count, n, present_slices, factors, inv, recovery_slices, out_slices, pcount, 0, word_count, rhs_buf[0..n]);
        return out_slices;
    }
    const pool = thread_pool.getGlobalPool() catch return error.OutOfMemory;
    var ctxs = try allocator.alloc(DecodeCtx, thread_count);
    defer allocator.free(ctxs);
    var t: usize = 0;
    while (t < thread_count) : (t += 1) {
        const start = (word_count * t) / thread_count;
        const end = (word_count * (t + 1)) / thread_count;
        const rhs = rhs_buf[(t * n)..((t + 1) * n)];
        ctxs[t] = .{
            .word_count = word_count,
            .n = n,
            .present_slices = present_slices,
            .factors = factors,
            .inv = inv,
            .recovery_slices = recovery_slices,
            .out_slices = out_slices,
            .pcount = pcount,
            .start_word = start,
            .end_word = end,
            .rhs = rhs,
            .err = null,
        };
    }
    var wg: std.Thread.WaitGroup = .{};
    t = 0;
    while (t + 1 < thread_count) : (t += 1) {
        pool.spawnWg(&wg, decodeRangeThread, .{&ctxs[t]});
    }
    decodeRangeThread(&ctxs[thread_count - 1]);
    wg.wait();
    t = 0;
    while (t < thread_count) : (t += 1) {
        if (ctxs[t].err) |e| return e;
    }

    return out_slices;
}

const EncodeCtx = struct {
    out: []u8,
    data_slices: []const []const u8,
    factors: []const u16,
    slice_size: usize,
    start_word: usize,
    end_word: usize,
};

fn encodeRangeThread(ctx: *const EncodeCtx) void {
    encodeRange(ctx.out, ctx.data_slices, ctx.factors, ctx.slice_size, ctx.start_word, ctx.end_word);
}

fn encodeRange(out: []u8, data_slices: []const []const u8, factors: []const u16, slice_size: usize, start_word: usize, end_word: usize) void {
    const simd_done = encodeRangeSimd(out, data_slices, factors, start_word, end_word);
    var w: usize = start_word + simd_done;
    while (w < end_word) : (w += 1) {
        var acc: u16 = 0;
        var i: usize = 0;
        while (i < data_slices.len) : (i += 1) {
            const slice = data_slices[i];
            const word = readWord(slice, w);
            acc ^= gf.mul(word, factors[i]);
        }
        writeWord(out, w, acc);
    }
    _ = slice_size;
}

fn encodeRangeSimd(out: []u8, data_slices: []const []const u8, factors: []const u16, start_word: usize, end_word: usize) usize {
    const lanes: usize = 8;
    const word_count = end_word - start_word;
    if (word_count < lanes) return 0;
    var w: usize = start_word;
    const simd_end = end_word - (word_count % lanes);
    while (w < simd_end) : (w += lanes) {
        var acc: @Vector(lanes, u16) = @splat(0);
        var i: usize = 0;
        while (i < data_slices.len) : (i += 1) {
            var prod_arr: [lanes]u16 = undefined;
            var lane: usize = 0;
            while (lane < lanes) : (lane += 1) {
                const word = readWord(data_slices[i], w + lane);
                prod_arr[lane] = gf.mul(word, factors[i]);
            }
            acc ^= @as(@Vector(lanes, u16), prod_arr);
        }
        var lane_write: usize = 0;
        while (lane_write < lanes) : (lane_write += 1) {
            writeWord(out, w + lane_write, acc[lane_write]);
        }
    }
    return w - start_word;
}

const DecodeCtx = struct {
    word_count: usize,
    n: usize,
    present_slices: []const []const u8,
    factors: []const u16,
    inv: []const u16,
    recovery_slices: []const RecoverySlice,
    out_slices: [][]u8,
    pcount: usize,
    start_word: usize,
    end_word: usize,
    rhs: []u16,
    err: ?RsError,
};

fn decodeRangeThread(ctx: *DecodeCtx) void {
    decodeRange(ctx.word_count, ctx.n, ctx.present_slices, ctx.factors, ctx.inv, ctx.recovery_slices, ctx.out_slices, ctx.pcount, ctx.start_word, ctx.end_word, ctx.rhs) catch |e| {
        ctx.err = e;
    };
}

fn decodeRange(
    word_count: usize,
    n: usize,
    present_slices: []const []const u8,
    factors: []const u16,
    inv: []const u16,
    recovery_slices: []const RecoverySlice,
    out_slices: [][]u8,
    pcount: usize,
    start_word: usize,
    end_word: usize,
    rhs: []u16,
) RsError!void {
    _ = word_count;
    var w: usize = start_word;
    while (w < end_word) : (w += 1) {
        var r: usize = 0;
        while (r < n) : (r += 1) {
            const rec = recovery_slices[r];
            const rec_word = readWord(rec.data, w);
            var acc = rec_word;
            var j: usize = 0;
            while (j < pcount) : (j += 1) {
                const word = readWord(present_slices[j], w);
                acc ^= gf.mul(word, factors[r * pcount + j]);
            }
            rhs[r] = acc;
        }

        var mi: usize = 0;
        while (mi < n) : (mi += 1) {
            var sum: u16 = 0;
            var mj: usize = 0;
            while (mj < n) : (mj += 1) {
                const coeff = inv[mi * n + mj];
                sum ^= gf.mul(coeff, rhs[mj]);
            }
            writeWord(out_slices[mi], w, sum);
        }
    }
}

fn threadCount(word_count: usize) usize {
    const min_words_per_thread: usize = 1024;
    if (word_count < min_words_per_thread) return 1;
    const cpu = std.Thread.getCpuCount() catch return 1;
    const desired = @max(@as(usize, 1), word_count / min_words_per_thread);
    var cap = cpu;
    if (thread_pool.maxJobs()) |max_jobs| {
        if (max_jobs > 0) cap = @min(cap, max_jobs);
    }
    if (cap == 0) cap = 1;
    return @min(cap, desired);
}

fn invertMatrix(mat: []u16, inv: []u16, n: usize) RsError!void {
    @memset(inv, 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        inv[i * n + i] = 1;
    }

    var col: usize = 0;
    while (col < n) : (col += 1) {
        var pivot: usize = col;
        while (pivot < n and mat[pivot * n + col] == 0) : (pivot += 1) {}
        if (pivot == n) return error.SingularMatrix;
        if (pivot != col) {
            swapRow(mat, n, pivot, col);
            swapRow(inv, n, pivot, col);
        }
        const pivot_val = mat[col * n + col];
        const inv_pivot = gf.inv(pivot_val);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            mat[col * n + j] = gf.mul(mat[col * n + j], inv_pivot);
            inv[col * n + j] = gf.mul(inv[col * n + j], inv_pivot);
        }
        var row: usize = 0;
        while (row < n) : (row += 1) {
            if (row == col) continue;
            const factor = mat[row * n + col];
            if (factor == 0) continue;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                mat[row * n + k] ^= gf.mul(factor, mat[col * n + k]);
                inv[row * n + k] ^= gf.mul(factor, inv[col * n + k]);
            }
        }
    }
}

fn swapRow(m: []u16, n: usize, a: usize, b: usize) void {
    if (a == b) return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ai = a * n + i;
        const bi = b * n + i;
        const tmp = m[ai];
        m[ai] = m[bi];
        m[bi] = tmp;
    }
}

fn readWord(buf: []const u8, word_index: usize) u16 {
    const off = word_index * 2;
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn writeWord(buf: []u8, word_index: usize, word: u16) void {
    const off = word_index * 2;
    buf[off] = @as(u8, @intCast(word & 0xFF));
    buf[off + 1] = @as(u8, @intCast(word >> 8));
}
