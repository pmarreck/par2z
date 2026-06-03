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

// =============================================================================
// SIMD-optimized GF(2^16) multiplication using PSHUFB/TBL byte shuffles
// =============================================================================
//
// This is the fastest approach for bulk GF(2^16) multiply. It uses the split-table
// technique (MulTables) with hardware byte-shuffle instructions to perform 8
// parallel table lookups per instruction. Each u16 multiply requires 8 PSHUFB/TBL
// operations (4 nibble positions × 2 result bytes), processing 8 values at once.
//
// PSHUFB (x86_64 SSSE3): pshufb xmm1, xmm2 — byte shuffle within 128-bit register
// TBL (aarch64 NEON): tbl Vd.16B, {Vn.16B}, Vm.16B — table lookup in 128-bit register
//
// Both instructions: for each byte position, use the low nibble of the index byte
// to select from a 16-byte table. If the index has bit 7 set (PSHUFB) or is >= 16
// (TBL), the result byte is 0.

const Vec16u8 = @Vector(16, u8);

/// Check if SSSE3 is available (required for PSHUFB on x86_64)
pub fn hasSsse3() bool {
    if (simd_disabled) return false;
    if (builtin.cpu.arch == .x86_64) {
        return std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
    }
    return false;
}

/// Check if NEON is available (always true on aarch64, provides TBL instruction)
pub fn hasNeonShuffle() bool {
    if (simd_disabled) return false;
    return builtin.cpu.arch == .aarch64;
}

/// Hardware-accelerated 16-byte table lookup.
/// For each byte position: result[i] = table[indices[i]] if valid, else 0.
inline fn tableLookup16(table: Vec16u8, indices: Vec16u8) Vec16u8 {
    if (comptime hasSsse3()) {
        // PSHUFB: result[i] = (indices[i] & 0x80) ? 0 : table[indices[i] & 0x0F]
        var result = table;
        asm ("pshufb %[idx], %[out]"
            : [out] "+x" (result)
            : [idx] "x" (indices)
        );
        return result;
    } else if (comptime hasNeonShuffle()) {
        // TBL: result[i] = (indices[i] >= 16) ? 0 : table[indices[i]]
        var result: Vec16u8 = undefined;
        asm ("tbl %[out].16b, {%[tbl].16b}, %[idx].16b"
            : [out] "=w" (result)
            : [tbl] "w" (table)
            , [idx] "w" (indices)
        );
        return result;
    } else {
        // Scalar fallback
        const t: [16]u8 = table;
        const idx: [16]u8 = indices;
        var result: [16]u8 = undefined;
        for (0..16) |i| {
            result[i] = if (idx[i] >= 16) 0 else t[idx[i]];
        }
        return result;
    }
}

/// Sentinel value: 0x80. When used as PSHUFB index, bit 7 set → output 0.
/// When used as TBL index, >= 16 → output 0. Used at positions 8-15 for unused lanes.
const sentinel_80: Vec16u8 = @splat(0x80);

/// Sentinel mask: positions 0-7 are 0x00, positions 8-15 are 0x80.
const upper_sentinel: Vec16u8 = blk: {
    var v: [16]u8 = undefined;
    for (0..8) |i| v[i] = 0;
    for (8..16) |i| v[i] = 0x80;
    break :blk v;
};

/// Combined mask for low nibble extraction with sentinel preservation.
/// Positions 0-7: 0x0F (extract low nibble), positions 8-15: 0x8F (preserve sentinel bit 7).
const combined_lo_mask: Vec16u8 = blk: {
    var v: [16]u8 = undefined;
    for (0..8) |i| v[i] = 0x0F;
    for (8..16) |i| v[i] = 0x8F;
    break :blk v;
};

/// Deinterleave mask: extract even-indexed bytes (0,2,4,6,8,10,12,14) into positions 0-7.
/// Positions 8-15 select from second source (sentinel_80) via negative indices: ~(-1) = 0 → src2[0] = 0x80.
const deinterleave_even_mask = @Vector(16, i32){ 0, 2, 4, 6, 8, 10, 12, 14, -1, -1, -1, -1, -1, -1, -1, -1 };
/// Deinterleave mask for odd-indexed bytes (1,3,5,7,9,11,13,15).
const deinterleave_odd_mask = @Vector(16, i32){ 1, 3, 5, 7, 9, 11, 13, 15, -1, -1, -1, -1, -1, -1, -1, -1 };

/// Interleave mask: weave positions 0-7 from first source (r_lo) with 0-7 from second source (r_hi)
/// into alternating even/odd byte positions. Negative indices select from second source: b[~mask[i]].
const interleave_mask = @Vector(16, i32){ 0, ~@as(i32, 0), 1, ~@as(i32, 1), 2, ~@as(i32, 2), 3, ~@as(i32, 3), 4, ~@as(i32, 4), 5, ~@as(i32, 5), 6, ~@as(i32, 6), 7, ~@as(i32, 7) };

/// Multiply 8 u16 values by a constant using PSHUFB/TBL byte-shuffle instructions.
/// Processes 16 input bytes (8 little-endian u16 values) through the split-table
/// nibble lookup technique with hardware-accelerated parallel table lookups.
///
/// Algorithm:
/// 1. Deinterleave input bytes into even (lo bytes of u16) and odd (hi bytes of u16)
/// 2. Extract nibbles from each group (4 sets of 8 nibble indices)
/// 3. Look up each nibble set in the appropriate MulTables entry via PSHUFB/TBL
/// 4. XOR all contributions to produce result lo and hi bytes
/// 5. Interleave result bytes back into u16 layout
pub inline fn mulVec8Shuffle(tbl: *const MulTables, input: [8]u16) [8]u16 {
    const bytes: Vec16u8 = @bitCast(input);
    const shift_4: Vec16u8 = @splat(4);

    // Step 1: Deinterleave with sentinel merge — separate lo bytes (even) and hi bytes (odd).
    // Positions 8-15 get 0x80 from sentinel_80 via negative mask indices, so PSHUFB/TBL
    // returns 0 for those unused lanes without additional masking.
    const even = @shuffle(u8, bytes, sentinel_80, deinterleave_even_mask);
    const odd = @shuffle(u8, bytes, sentinel_80, deinterleave_odd_mask);

    // Step 2: Extract nibbles.
    // Low nibbles: AND with combined_lo_mask preserves sentinel bit 7 at positions 8-15.
    // High nibbles: shift right 4, then OR with upper_sentinel to restore sentinel.
    const even_lo = even & combined_lo_mask;
    const even_hi = (even >> shift_4) | upper_sentinel;
    const odd_lo = odd & combined_lo_mask;
    const odd_hi = (odd >> shift_4) | upper_sentinel;

    // Step 3: 8 parallel table lookups + XOR to produce lo and hi result bytes.
    const lo_tbl_0: Vec16u8 = tbl.lo[0];
    const lo_tbl_1: Vec16u8 = tbl.lo[1];
    const lo_tbl_2: Vec16u8 = tbl.lo[2];
    const lo_tbl_3: Vec16u8 = tbl.lo[3];
    const hi_tbl_0: Vec16u8 = tbl.hi[0];
    const hi_tbl_1: Vec16u8 = tbl.hi[1];
    const hi_tbl_2: Vec16u8 = tbl.hi[2];
    const hi_tbl_3: Vec16u8 = tbl.hi[3];

    const r_lo = tableLookup16(lo_tbl_0, even_lo) ^ tableLookup16(lo_tbl_1, even_hi) ^
        tableLookup16(lo_tbl_2, odd_lo) ^ tableLookup16(lo_tbl_3, odd_hi);
    const r_hi = tableLookup16(hi_tbl_0, even_lo) ^ tableLookup16(hi_tbl_1, even_hi) ^
        tableLookup16(hi_tbl_2, odd_lo) ^ tableLookup16(hi_tbl_3, odd_hi);

    // Step 4: Interleave lo and hi result bytes back into u16 layout.
    return @bitCast(@shuffle(u8, r_lo, r_hi, interleave_mask));
}

/// Multiply-accumulate 8 u16 values: acc[i] ^= factor * input[i]
/// Uses PSHUFB/TBL shuffle-based lookup when available.
pub inline fn mulAccVec8Shuffle(tbl: *const MulTables, input: [8]u16, acc: *[8]u16) void {
    const products = mulVec8Shuffle(tbl, input);
    const acc_vec: @Vector(8, u16) = acc.*;
    const prod_vec: @Vector(8, u16) = products;
    acc.* = acc_vec ^ prod_vec;
}

/// Check if shuffle-based SIMD GF16 multiply is available on this target.
/// Note: x86_64 PSHUFB disabled due to Zig 0.15.2 codegen bug (XMM/YMM mismatch).
/// ARM NEON TBL path is unaffected.
pub fn hasShuffleMul() bool {
    return hasNeonShuffle();
}

// =============================================================================
// SIMD-optimized GF(2^16) multiplication using PCLMULQDQ/PMULL
// =============================================================================
//
// This uses carry-less multiplication instructions followed by Barrett reduction.
// Polynomial: 0x1100B = x^16 + x^12 + x^3 + x + 1
//
// Algorithm:
// 1. Carry-less multiply: p = a * b (up to 31 bits)
// 2. Barrett reduction: result = p mod 0x1100B
//
// Barrett reduction for GF(2^16):
//   q = (p >> 16) * mu  where mu = floor(x^32 / poly) = 0x1100A
//   result = p ^ ((q >> 16) * poly)
//
// References:
// - Intel CLMUL white paper
// - https://www.corsix.org/content/galois-field-instructions-2021-cpus
// - https://github.com/animetosho/ParPar/blob/master/fast-gf-multiplication.md

const builtin = @import("builtin");

/// The irreducible polynomial for GF(2^16): x^16 + x^12 + x^3 + x + 1
/// The low 16 bits (without the x^16 term) are used for reduction
const gf_poly: u32 = 0x1100B;
const gf_poly_low: u16 = 0x100B; // x^12 + x^3 + x + 1

/// Check if SIMD is disabled via build option or environment
/// When build_options module is available (via zig build), use that.
/// Otherwise default to false (SIMD enabled).
const simd_disabled: bool = blk: {
    if (@hasDecl(@import("root"), "build_options")) {
        const opts = @import("root").build_options;
        if (@hasDecl(opts, "disable_simd")) {
            break :blk opts.disable_simd;
        }
    }
    break :blk false;
};

/// Check if PCLMULQDQ is available at comptime
pub fn hasPclmul() bool {
    if (simd_disabled) return false;
    if (builtin.cpu.arch == .x86_64) {
        return std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);
    }
    return false;
}

/// Check if ARM crypto extensions (PMULL) are available at comptime
pub fn hasArmCrypto() bool {
    if (simd_disabled) return false;
    if (builtin.cpu.arch == .aarch64) {
        return std.Target.aarch64.featureSetHas(builtin.cpu.features, .aes);
    }
    return false;
}

/// Carry-less multiply two 16-bit values using PCLMULQDQ (x86_64)
/// Returns the full 32-bit unreduced product
inline fn clmul16_x86(a: u16, b: u16) u32 {
    // Load into XMM registers and perform PCLMULQDQ
    // "+x" is read-write: pclmulqdq overwrites the first operand in-place
    var va: u128 = a;
    const vb: u128 = b;
    asm ("pclmulqdq $0, %[b], %[a]"
        : [a] "+x" (va),
        : [b] "x" (vb),
    );
    return @truncate(va);
}

/// Carry-less multiply two 16-bit values using PMULL (ARM64)
/// Returns the full 32-bit unreduced product
inline fn clmul16_arm(a: u16, b: u16) u32 {
    // On ARM64, PMULL multiplies polynomial values
    // We use the 64-bit variant and extract the low 32 bits
    const va: u64 = a;
    const vb: u64 = b;
    var result: u128 = undefined;
    asm ("pmull %[out].1q, %[a].1d, %[b].1d"
        : [out] "=w" (result),
        : [a] "w" (va),
          [b] "w" (vb),
    );
    return @truncate(result);
}

/// Scalar carry-less multiplication (for reduction step)
inline fn clmulScalar16(a: u16, b: u16) u32 {
    var result: u32 = 0;
    var aa: u32 = a;
    var bb: u32 = b;
    while (aa != 0) {
        if ((aa & 1) != 0) {
            result ^= bb;
        }
        aa >>= 1;
        bb <<= 1;
    }
    return result;
}

/// Precomputed reduction table: for each high 15-bit value, the XOR reduction
/// reduce_table[i] gives the 16-bit result when XORing with the low 16 bits
const reduce_table: [32768]u16 = initReduceTable();

fn initReduceTable() [32768]u16 {
    @setEvalBranchQuota(1000000);
    var table: [32768]u16 = undefined;
    for (0..32768) |i| {
        // i represents bits 16-30 of the product (bit 31 is always 0 for 16x16 mul)
        var result: u32 = @as(u32, @intCast(i)) << 16;

        // Reduce from high to low
        comptime var bit: u5 = 30;
        inline while (bit >= 16) : (bit -= 1) {
            if ((result & (@as(u32, 1) << bit)) != 0) {
                result ^= @as(u32, gf_poly) << (bit - 16);
            }
        }

        table[i] = @truncate(result);
    }
    return table;
}

/// Reduce a 32-bit polynomial product modulo 0x1100B using table lookup
/// Much faster than bit-by-bit reduction
inline fn polyReduce(p: u32) u16 {
    const low: u16 = @truncate(p);
    const high: u15 = @truncate(p >> 16); // Only 15 bits needed (max product is 30 bits)
    return low ^ reduce_table[high];
}

/// Slow version for testing (bit-by-bit)
fn polyReduceSlow(p: u32) u16 {
    var result = p;

    comptime var i: u5 = 30;
    inline while (i >= 16) : (i -= 1) {
        const bit_mask: u32 = @as(u32, 1) << i;
        if ((result & bit_mask) != 0) {
            result ^= @as(u32, gf_poly) << (i - 16);
        }
    }

    return @truncate(result);
}

/// SIMD GF(2^16) multiply using PMULL/PCLMULQDQ when available
pub fn mulSimd(a: u16, b: u16) u16 {
    if (a == 0 or b == 0) return 0;

    if (comptime hasArmCrypto()) {
        const p = clmul16_arm(a, b);
        return polyReduce(p);
    } else if (comptime hasPclmul()) {
        const p = clmul16_x86(a, b);
        return polyReduce(p);
    } else {
        // Fallback to table-based multiplication
        return mul(a, b);
    }
}

/// Vectorized multiply: multiply 8 u16 values by a constant
/// Uses SIMD carry-less multiply when available
pub fn mulVec8Simd(values: [8]u16, factor: u16) [8]u16 {
    if (factor == 0) return .{ 0, 0, 0, 0, 0, 0, 0, 0 };

    var result: [8]u16 = undefined;

    if (comptime hasArmCrypto()) {
        inline for (0..8) |i| {
            if (values[i] == 0) {
                result[i] = 0;
            } else {
                const p = clmul16_arm(values[i], factor);
                result[i] = polyReduce(p);
            }
        }
    } else if (comptime hasPclmul()) {
        inline for (0..8) |i| {
            if (values[i] == 0) {
                result[i] = 0;
            } else {
                const p = clmul16_x86(values[i], factor);
                result[i] = polyReduce(p);
            }
        }
    } else {
        // Fallback to table-based
        inline for (0..8) |i| {
            result[i] = mul(values[i], factor);
        }
    }

    return result;
}

/// Vectorized multiply-accumulate: acc[i] ^= values[i] * factor
pub fn mulAccVec8Simd(values: [8]u16, factor: u16, acc: *[8]u16) void {
    const products = mulVec8Simd(values, factor);
    inline for (0..8) |i| {
        acc[i] ^= products[i];
    }
}

// Tests for SIMD multiplication
test "mulSimd matches scalar mul" {
    // Test a variety of values
    const test_values = [_]u16{ 0, 1, 2, 0x1234, 0xABCD, 0xFFFF, 0x8000, 0x0001 };

    for (test_values) |a| {
        for (test_values) |b| {
            const scalar_result = mul(a, b);
            const simd_result = mulSimd(a, b);
            try std.testing.expectEqual(scalar_result, simd_result);
        }
    }
}

test "mulVec8Simd matches scalar" {
    const values = [8]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };
    const factor: u16 = 0xABCD;

    const simd_result = mulVec8Simd(values, factor);

    for (0..8) |i| {
        const expected = mul(values[i], factor);
        try std.testing.expectEqual(expected, simd_result[i]);
    }
}

test "mulVec8Shuffle matches scalar" {
    const factors = [_]u16{ 0x0000, 0x0001, 0x0002, 0x1234, 0xABCD, 0xFFFF, 0x8000, 0x100B };
    const values = [8]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };

    for (factors) |factor| {
        const tbl = MulTables.init(factor);
        const shuffle_result = mulVec8Shuffle(&tbl, values);

        for (0..8) |i| {
            const expected = mul(values[i], factor);
            try std.testing.expectEqual(expected, shuffle_result[i]);
        }
    }

    // Also test with zero inputs and edge-case inputs
    const edge_values = [8]u16{ 0, 0, 0xFFFF, 0xFFFF, 1, 0x8000, 0x100B, 0x7FFF };
    for (factors) |factor| {
        const tbl = MulTables.init(factor);
        const shuffle_result = mulVec8Shuffle(&tbl, edge_values);

        for (0..8) |i| {
            const expected = mul(edge_values[i], factor);
            try std.testing.expectEqual(expected, shuffle_result[i]);
        }
    }
}

test "mulAccVec8Shuffle accumulates correctly" {
    const factor: u16 = 0xABCD;
    const tbl = MulTables.init(factor);
    const values = [8]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };
    const initial_acc = [8]u16{ 0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x6000, 0x7000, 0x8000 };
    var acc = initial_acc;

    mulAccVec8Shuffle(&tbl, values, &acc);

    for (0..8) |i| {
        const expected = mul(values[i], factor) ^ initial_acc[i];
        try std.testing.expectEqual(expected, acc[i]);
    }
}

test "MulTables.mulScalar matches scalar mul" {
    const factors = [_]u16{ 0x0000, 0x0001, 0x0002, 0x1234, 0xABCD, 0xFFFF, 0x8000, 0x100B };
    const test_values = [_]u16{ 0, 1, 2, 0x1234, 0xABCD, 0xFFFF, 0x8000, 0x0001 };

    for (factors) |factor| {
        const tbl = MulTables.init(factor);
        for (test_values) |val| {
            try std.testing.expectEqual(mul(val, factor), tbl.mulScalar(val));
        }
    }
}

test "clmul16_arm produces correct carry-less product" {
    if (comptime !hasArmCrypto()) return error.SkipZigTest;

    // Test case: 3 * 5 in polynomial arithmetic
    // 3 = x + 1 = 0b11
    // 5 = x^2 + 1 = 0b101
    // Product: (x+1)(x^2+1) = x^3 + x + x^2 + 1 = x^3 + x^2 + x + 1 = 0b1111 = 15
    const p = clmul16_arm(3, 5);
    try std.testing.expectEqual(@as(u32, 15), p);

    // Test: 0xFF * 0xFF
    // Result should be carry-less square of 0xFF
    const p2 = clmul16_arm(0xFF, 0xFF);
    // 0xFF = x^7 + x^6 + ... + x + 1
    // Squaring doubles exponents: x^14 + x^12 + x^10 + x^8 + x^6 + x^4 + x^2 + 1
    // = 0b101010101010101 = 0x5555
    try std.testing.expectEqual(@as(u32, 0x5555), p2);
}

test "polyReduce correctly reduces modulo polynomial" {
    // Test: x^16 should reduce to x^12 + x^3 + x + 1 = 0x100B
    const p1: u32 = 0x10000; // x^16
    try std.testing.expectEqual(@as(u16, 0x100B), polyReduce(p1));

    // Test: x^17 should reduce to x^13 + x^4 + x^2 + x = 0x2016
    const p2: u32 = 0x20000; // x^17
    try std.testing.expectEqual(@as(u16, 0x2016), polyReduce(p2));

    // Test: values < 2^16 should be unchanged
    const p3: u32 = 0x1234;
    try std.testing.expectEqual(@as(u16, 0x1234), polyReduce(p3));

    // Verify table-based matches slow version for all high values
    for (0..32768) |high| {
        const p: u32 = (@as(u32, @intCast(high)) << 16) | 0xABCD;
        try std.testing.expectEqual(polyReduceSlow(p), polyReduce(p));
    }
}

test "comprehensive mulSimd correctness" {
    // Test all combinations of small values
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        var j: u16 = 0;
        while (j < 256) : (j += 1) {
            const expected = mul(i, j);
            const actual = mulSimd(i, j);
            try std.testing.expectEqual(expected, actual);
        }
    }

    // Test some larger values
    const large_tests = [_][2]u16{
        .{ 0xFFFF, 0xFFFF },
        .{ 0x8000, 0x8000 },
        .{ 0x1234, 0x5678 },
        .{ 0xABCD, 0xEF01 },
        .{ 0x0001, 0xFFFF },
        .{ 0x1000, 0x0100 },
    };

    for (large_tests) |pair| {
        const expected = mul(pair[0], pair[1]);
        const actual = mulSimd(pair[0], pair[1]);
        try std.testing.expectEqual(expected, actual);
    }
}

/// Monotonic nanosecond clock for microbenchmarks (0.16 Io.Timestamp).
fn benchNowNs(io: std.Io) i128 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @as(i128, ts.nanoseconds);
}

/// Benchmark utility: measure ops/sec for a multiplication function
fn benchmarkMul(io: std.Io, comptime name: []const u8, comptime mulFn: fn (u16, u16) u16) !void {
    const iterations: usize = 1_000_000;
    var checksum: u32 = 0;

    const start = benchNowNs(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const a: u16 = @truncate(i *% 0x1234);
        const b: u16 = @truncate(i *% 0x5678);
        checksum +%= mulFn(a, b);
    }

    const end = benchNowNs(io);
    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));

    std.debug.print("{s}: {d:.2} M ops/sec (checksum: {x})\n", .{ name, ops_per_sec / 1_000_000.0, checksum });
}

/// Benchmark: measure just the PMULL instruction throughput
fn benchmarkPmullOnly(io: std.Io) !void {
    if (comptime !hasArmCrypto()) {
        std.debug.print("PMULL only: N/A (not available)\n", .{});
        return;
    }

    const iterations: usize = 1_000_000;
    var checksum: u32 = 0;

    const start = benchNowNs(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const a: u16 = @truncate(i *% 0x1234);
        const b: u16 = @truncate(i *% 0x5678);
        const p = clmul16_arm(a, b);
        checksum +%= p;
    }

    const end = benchNowNs(io);
    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));

    std.debug.print("PMULL only: {d:.2} M ops/sec (checksum: {x})\n", .{ ops_per_sec / 1_000_000.0, checksum });
}

/// Benchmark: measure just polyReduce
fn benchmarkPolyReduceOnly(io: std.Io) !void {
    const iterations: usize = 1_000_000;
    var checksum: u32 = 0;

    const start = benchNowNs(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const p: u32 = @truncate(i *% 0x12345678);
        checksum +%= polyReduce(p);
    }

    const end = benchNowNs(io);
    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));

    std.debug.print("polyReduce: {d:.2} M ops/sec (checksum: {x})\n", .{ ops_per_sec / 1_000_000.0, checksum });
}

fn benchmarkVec8(io: std.Io, comptime name: []const u8, comptime vec_fn: anytype) !void {
    const iterations = 1_000_000;
    var checksum: u16 = 0;
    const input = [8]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };

    const start = benchNowNs(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = vec_fn(input, @as(u16, @truncate(i)));
        checksum +%= result[0];
    }

    const end = benchNowNs(io);
    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 8.0 * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print("{s}: {d:.2} M muls/sec (checksum: {x})\n", .{ name, ops_per_sec / 1_000_000.0, checksum });
}

fn benchmarkVec8Shuffle(io: std.Io) !void {
    const iterations = 1_000_000;
    var checksum: u16 = 0;
    var input = [8]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };
    const tbl = MulTables.init(0xABCD);

    const start = benchNowNs(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        input = mulVec8Shuffle(&tbl, input);
        checksum +%= input[0];
    }

    const end = benchNowNs(io);
    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) * 8.0 * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print("Shuffle mul: {d:.2} M muls/sec (checksum: {x})\n", .{ ops_per_sec / 1_000_000.0, checksum });
}

/// Run the GF(2^16) multiplication microbenchmarks. Invoked by the
/// `bench-micro` build step (src/tools/microbench.zig), not by the test
/// suite — timing loops are not correctness tests. Parity/correctness of
/// these kernels is covered by the `test` blocks above.
pub fn runBenchmarks(io: std.Io) !void {
    std.debug.print("\n--- GF16 Multiplication Benchmark ---\n", .{});
    std.debug.print("PMULL available: {}\n", .{hasArmCrypto()});
    std.debug.print("PCLMUL available: {}\n", .{hasPclmul()});
    std.debug.print("SSSE3 available: {}\n", .{hasSsse3()});
    std.debug.print("NEON shuffle available: {}\n", .{hasNeonShuffle()});

    try benchmarkMul(io, "Table mul ", mul);
    try benchmarkMul(io, "SIMD mul  ", mulSimd);
    try benchmarkVec8(io, "Vec8 SIMD ", mulVec8Simd);
    try benchmarkVec8Shuffle(io);
    try benchmarkPmullOnly(io);
    try benchmarkPolyReduceOnly(io);
}
