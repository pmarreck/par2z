const std = @import("std");

pub const GF16 = struct {
    exp: [65535]u16,
    log: [65536]u16,
    valid_exponent_count: u32,
};

const poly: u32 = 0x1100B;

pub const tables: GF16 = initTables();

const max_valid_index_count: usize = @intCast(tables.valid_exponent_count);

const IndexTables = struct {
    constants: [max_valid_index_count]u16,
    exponents: [max_valid_index_count]u32,
};

pub const index_tables: IndexTables = initIndexTables();

fn initIndexTables() IndexTables {
    @setEvalBranchQuota(200000);
    var constants: [max_valid_index_count]u16 = undefined;
    var exponents: [max_valid_index_count]u32 = undefined;
    var count: usize = 0;
    var exp: u32 = 1;
    while (exp < 65535) : (exp += 1) {
        if (isValidExponent(exp)) {
            constants[count] = constantForExponent(exp);
            exponents[count] = exp;
            count += 1;
        }
    }
    return .{ .constants = constants, .exponents = exponents };
}

fn initTables() GF16 {
    @setEvalBranchQuota(200000);
    var exp: [65535]u16 = undefined;
    var log: [65536]u16 = undefined;
    log[0] = 0;
    var x: u32 = 1;
    var i: usize = 0;
    while (i < 65535) : (i += 1) {
        exp[i] = @as(u16, @intCast(x));
        log[@as(usize, @intCast(x))] = @as(u16, @intCast(i));
        x <<= 1;
        if ((x & 0x10000) != 0) {
            x ^= poly;
        }
    }
    var count: u32 = 0;
    var e: u32 = 1;
    while (e < 65535) : (e += 1) {
        if (isValidExponent(e)) count += 1;
    }
    return .{ .exp = exp, .log = log, .valid_exponent_count = count };
}

pub fn mul(a: u16, b: u16) u16 {
    if (a == 0 or b == 0) return 0;
    const la = tables.log[a];
    const lb = tables.log[b];
    var idx = @as(u32, la) + @as(u32, lb);
    if (idx >= 65535) idx -= 65535;
    return tables.exp[@as(usize, @intCast(idx))];
}

pub fn inv(a: u16) u16 {
    if (a == 0) return 0;
    const la = tables.log[a];
    var idx: u32 = 65535 - la;
    if (idx == 65535) idx = 0;
    return tables.exp[@as(usize, @intCast(idx))];
}

pub fn pow(base: u16, exponent: u32) u16 {
    if (base == 0) return 0;
    const lb = tables.log[base];
    const idx = mod65535(@as(u64, lb) * @as(u64, exponent));
    return tables.exp[@as(usize, @intCast(idx))];
}

pub fn isValidExponent(exp: u32) bool {
    return (exp % 3 != 0) and (exp % 5 != 0) and (exp % 17 != 0) and (exp % 257 != 0);
}

pub fn constantForExponent(exp: u32) u16 {
    return tables.exp[@as(usize, @intCast(mod65535(exp)))];
}

pub fn constantForIndex(index: u32) u16 {
    std.debug.assert(index < maxValidIndexCount());
    return index_tables.constants[@as(usize, @intCast(index))];
}

pub fn exponentForIndex(index: u32) u32 {
    std.debug.assert(index < maxValidIndexCount());
    return index_tables.exponents[@as(usize, @intCast(index))];
}

pub fn maxValidIndexCount() u32 {
    return tables.valid_exponent_count;
}

fn mod65535(x: u64) u32 {
    var v = x;
    while (v >= 65535) {
        v = (v & 0xFFFF) + (v >> 16);
    }
    if (v == 65535) return 0;
    return @as(u32, @intCast(v));
}

// =============================================================================
// SIMD-optimized GF(2^16) multiplication using split-table technique
// =============================================================================
//
// Mathematical basis: GF multiplication distributes over XOR (addition in GF):
//   mul(a, c) = mul(a & 0xF000, c) ^ mul(a & 0x0F00, c) ^ mul(a & 0x00F0, c) ^ mul(a & 0x000F, c)
//
// Each nibble position has only 16 possible values, so we precompute 4 tables
// of 16 entries each. SIMD shuffle instructions can do 16 parallel lookups.
//
// References:
// - GF-Complete library SPLIT_TABLE(16,4) method
// - https://github.com/animetosho/ParPar/blob/master/fast-gf-multiplication.md

/// Precomputed lookup tables for multiplying by a constant factor.
/// Uses the split-table technique with 4-bit nibbles.
pub const MulTables = struct {
    /// Tables for low byte result: table[nibble_position][nibble_value]
    lo: [4][16]u8,
    /// Tables for high byte result: table[nibble_position][nibble_value]
    hi: [4][16]u8,

    /// Create multiplication tables for a given constant factor.
    pub fn init(factor: u16) MulTables {
        var result: MulTables = undefined;
        // For each nibble position (0=bits 0-3, 1=bits 4-7, 2=bits 8-11, 3=bits 12-15)
        inline for (0..4) |nibble_pos| {
            // For each possible nibble value (0-15)
            inline for (0..16) |nibble_val| {
                // Construct the input value with this nibble at this position
                const input: u16 = @as(u16, @intCast(nibble_val)) << @intCast(nibble_pos * 4);
                const product = mul(input, factor);
                result.lo[nibble_pos][nibble_val] = @truncate(product);
                result.hi[nibble_pos][nibble_val] = @truncate(product >> 8);
            }
        }
        return result;
    }

    /// Multiply a single value using the precomputed tables (scalar fallback).
    pub inline fn mulScalar(self: *const MulTables, a: u16) u16 {
        const n0: u4 = @truncate(a);
        const n1: u4 = @truncate(a >> 4);
        const n2: u4 = @truncate(a >> 8);
        const n3: u4 = @truncate(a >> 12);
        const lo = self.lo[0][n0] ^ self.lo[1][n1] ^ self.lo[2][n2] ^ self.lo[3][n3];
        const hi = self.hi[0][n0] ^ self.hi[1][n1] ^ self.hi[2][n2] ^ self.hi[3][n3];
        return (@as(u16, hi) << 8) | lo;
    }
};

/// Multiply 8 u16 values by a constant using precomputed tables.
/// Uses the split-table technique for vectorized GF(2^16) multiplication.
pub inline fn mulVec8(tbl: *const MulTables, input: [8]u16) [8]u16 {
    var result: [8]u16 = undefined;
    inline for (0..8) |i| {
        result[i] = tbl.mulScalar(input[i]);
    }
    return result;
}

/// Accumulate: out[i] ^= tbl.mul(input[i]) for 8 words at a time.
/// This is the core operation in RS encoding.
pub inline fn mulAccVec8(tbl: *const MulTables, input: [8]u16, acc: *[8]u16) void {
    inline for (0..8) |i| {
        acc[i] ^= tbl.mulScalar(input[i]);
    }
}
