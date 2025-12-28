# PAR2 Cleanroom Implementation Plan (TDD, Zig)

## Phase 0: Project Skeleton
- [x] Define folder layout (core, io, cli, tests, fuzz)
- [x] Add build system (zig build) with safety presets
- [x] Define C ABI surface (library entry points, error codes, handle types)
- [x] Add single test entry point (./test)
- [x] Add lint/analysis entry point (./lint)
- [x] Define storage adapter interface (memory, disk, custom backends)

Curiosity poke: What minimal layout supports hexagonal architecture without over-design?

## Phase 1: Binary Utilities (Pure)
- [x] Implement byte-slice aliases and endian read helpers
- [x] Implement checked arithmetic helpers
- [x] Implement CRC32 (deterministic)
- [x] Implement MD5 (RFC 1321) or wrap platform crypto

Curiosity poke: Are we consistent about padding and endianness at every read?

## Phase 2: Packet Framing
- [x] Parse packet header (validate magic, length bounds, hash)
- [x] Verify packet hash (MD5 of body with Recovery Set ID + Type)
- [x] Parse packet types
- [x] Creator
- [x] Main
- [x] FileDesc
- [x] IFSC
- [x] RecvSlic

Curiosity poke: How do we handle duplicated packets and out-of-order packets?

## Phase 3: File Set Model
- [x] Build recovery set model from Main packet
- [x] Attach FileDesc + IFSC to File IDs
- [x] Validate file identities (File ID computation)

Curiosity poke: What if there are multiple Main packets with same ID?

## Phase 4: Slice Handling
- [x] Compute slice layout for each file
- [x] Implement slice hashing (MD5/CRC32)
- [x] Verify IFSC for existing files

Curiosity poke: Does zero-padding happen consistently across all hash and RS operations?

## Phase 5: GF(2^16) and Constants
- [x] Implement GF tables (exp/log) for polynomial 0x1100B
- [x] Implement constant sequence (exponent not divisible by 3,5,17,257)

Curiosity poke: Are we skipping the correct exponents and using the right generator?

## Phase 6: Recovery Encoding/Decoding (Core)
- [x] Encode recovery slice from data slices (needs known-good comparison)
- [x] Solve linear system for missing slices (Gaussian elimination)

Curiosity poke: What is the numerical stability or performance risk for large sets?

## Phase 7: Reconstruction
- [ ] Rebuild missing slices into files
- [ ] Verify FileDesc MD5

Curiosity poke: How do we handle partial last slice and file size truncation?

## TODOs (Tracking)
- [ ] Split recovery allocators (temp slices vs recovered output) to reduce peak memory
- [ ] Add create-side parameters (blocksize/slice size, redundancy count/percentage) for par2 compatibility
- [ ] Normalize output paths (strip leading ./, collapse separators) before safety checks
- [x] Consider Bitrot Guard heuristics for default block size (double exponential decay vs file size)
- [ ] Create: stream hashing + slice generation (avoid reading whole files)
- [x] Create: split recovery slices across multiple volume files (par2cmdline compatibility)

## Phase 8: Optional Packets
- [x] Unicode file names/comments
- [ ] File slice packets
- [ ] Packed Main / Packed Recovery
- [ ] Recovery slice checksums

Curiosity poke: Are optional packets required for compatibility with common tools?

## Phase 9: CLI + Compatibility
- [x] CLI: verify
- [x] CLI: recover
- [x] CLI: create (flags + basic implementation)
- [x] Cross-check with par2cmdline outputs

Curiosity poke: Which behaviors are de facto standards vs spec requirements?

## API Layering Goal (Cross-Cutting)
- [x] Provide a high-level API (verify/recover) and a low-level block API (packet/slice operations)
- [x] Ensure operations can run on memory-backed stores (no required disk I/O)

## Next Steps (Context Refresh)
- [ ] Document CLI commands and map to API calls
- [x] Add CLI verify/recover stubs
- [x] Add par2cmdline cross-checks for full-file recover (beyond single-slice fixtures)
