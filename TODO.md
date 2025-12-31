# TODO

## Performance: SIMD-optimized GF16 multiplication

**Priority:** High (10-15x speedup potential on create/repair)

### Problem

Current benchmarks show par2cmdline-turbo is 10-15x faster than par2z on create operations:

| Tool | Create (MiB/s) | Verify (MiB/s) | Repair (MiB/s) |
|------|----------------|----------------|----------------|
| par2cmdline | 11.7 | 160.0 | 85.1 |
| par2cmdline-turbo | 172.0 | 363.6 | 111.9 |
| par2z-cli | 10.4 | 166.7 | 56.9 |

The bottleneck is GF16 (Galois Field 2^16) multiplication in `src/core/gf16.zig`.

### What We Tried

A split-table approach (`MulTables` in gf16.zig) was implemented but showed no improvement:
- Table initialization overhead (~64 scalar muls per factor) wasn't amortized well
- Zig's `@shuffle` requires comptime indices, preventing runtime PSHUFB-style lookups
- The scalar `mulScalar` using 4-nibble XOR was slower than log/exp table approach
- Branchless masking for zero handling added overhead without benefit
- Extended exp table (doubled size) caused comptime initialization timeout

The split-table code remains in gf16.zig for reference but isn't used in the hot path.

**Key insight**: True SIMD optimization requires either:
1. Inline assembly for PCLMULQDQ/PMULL (carry-less multiply)
2. Inline assembly for PSHUFB/TBL (vectorized shuffle-based table lookup)
3. Zig's vector operations alone cannot express these patterns efficiently

### Current Implementation

```zig
pub fn mul(a: u16, b: u16) u16 {
    if (a == 0 or b == 0) return 0;  // Branch prevents vectorization
    const la = tables.log[a];         // Table lookup (gather)
    const lb = tables.log[b];         // Table lookup (gather)
    var idx = @as(u32, la) + @as(u32, lb);
    if (idx >= 65535) idx -= 65535;
    return tables.exp[idx];           // Table lookup (gather)
}
```

Problems:
1. **Branches** inside hot loop prevent auto-vectorization
2. **Indirect memory access** (table lookups) are gather operations that don't vectorize
3. The "SIMD" attempt in `rs.zig:encodeRangeSimd` still calls scalar `gf.mul` per lane

### Solution Approaches

#### Option 1: Carry-less multiplication (PCLMUL/PMULL)

Use CPU instructions for polynomial multiplication:
- x86: `PCLMULQDQ` (SSE4.2+)
- ARM: `PMULL` (NEON crypto extensions)

This computes GF multiplication directly without tables, processing multiple elements per instruction.

References:
- [Intel PCLMULQDQ](https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#text=pclmul)
- par2cmdline-turbo's `gf16_clmul.c`

#### Option 2: Split-table with PSHUFB

Use 4-bit lookup tables with vectorized shuffle:
- Split each 16-bit value into 4 nibbles
- Use `PSHUFB` (x86) / `TBL` (ARM) for parallel 16-way lookups
- Combine results with XOR

This approach works on older CPUs without PCLMUL.

References:
- par2cmdline-turbo's `gf16_shuffle.c`
- [Plank's GF-Complete library](http://jerasure.org/jerasure/gf-complete)

#### Option 3: Affine transformations (GFNI)

Intel Ice Lake+ has `GF2P8AFFINEQB` for direct GF operations, but limited availability.

### Implementation Notes

Zig supports inline assembly and SIMD vectors. Example structure:

```zig
// Detect CPU features at comptime or runtime
const has_pclmul = std.Target.x86.featureSetHas(target.cpu.features, .pclmul);

pub fn mulVec(a: @Vector(8, u16), b: @Vector(8, u16)) @Vector(8, u16) {
    if (has_pclmul) {
        return mulVecPclmul(a, b);
    } else {
        return mulVecShuffle(a, b);
    }
}
```

The RS encoding loop in `src/core/rs.zig` would then use `mulVec` instead of scalar `mul`.

### Testing

- Existing tests should pass with any implementation
- Add benchmark regression test to CI
- Verify correctness across all CPU feature combinations

### References

- [par2cmdline-turbo source](https://github.com/animetosho/par2cmdline-turbo)
- [ParPar](https://github.com/animetosho/ParPar) - Node.js PAR2 with extensive SIMD
- [GF-Complete](http://jerasure.org/jerasure/gf-complete) - Generic GF arithmetic library
