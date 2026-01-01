# PAR2 Specification (Cleanroom Derivation)

## Purpose and Cleanroom Scope
This document describes the PAR2 (Parchive 2.0) parity volume set file format and recovery algorithm at a level sufficient for an independent implementation. It is written from published specifications and public documentation only; no source code was consulted.

## Normative Sources (For Legal Provenance)
Accessed 2025-12-24.
- Parity Volume Set Specification 2.0 (Parchive), dated 2003-05-11: http://parchive.sourceforge.net/docs/specifications/parity-volume-spec/article-spec.html
- Bilingual mirror of the same specification (used for optional packet sections due to encoding access limits): https://zybuluo.com/zhongdao/note/1458958
- Parchive project site (general context): http://parchive.sourceforge.net/
- Library of Congress Format Description (context): https://www.loc.gov/preservation/digital/formats/fdd/fdd000634.shtml

## Conventions
- All integer fields are unsigned, little-endian.
- All packets are 4-byte aligned. Bodies are padded with zero bytes to a multiple of 4.
- ASCII strings are not null-terminated unless explicitly stated. Any unused bytes are zero.
- MD5 is used for packet integrity and file identification.
- CRC32 is the CCITT/Ethernet/PKZIP standard CRC32.

## Top-Level Concepts
- A PAR2 recovery set is defined by a set of input files and a parity volume set containing recovery data.
- A *recovery set* is the set of files that may be reconstructed. A *non-recovery set* contains files that may be checked for integrity but are not reconstructed.
- Files are split into fixed-size *slices*; recovery data is generated from all slices across the recovery set.

## Packet Framing (All PAR2 Packets)
Every packet has a fixed 64-byte header followed by a packet body.

Header fields:
- Magic (8 bytes): ASCII "PAR2\0PKT".
- Length (8 bytes): total packet length in bytes, including the header.
- Hash (16 bytes): MD5 of the packet from Recovery Set ID through the end of the body (i.e., excluding Magic, Length, and this Hash field).
- Recovery Set ID (16 bytes): MD5 of the *Main* packet body.
- Packet Type (16 bytes): ASCII, padded with zero bytes.

General rules:
- Packets may appear in any order and may be duplicated.
- Parsers should ignore unrecognized packet types.
- Packets with invalid hash should be ignored.

## Identifiers
### Recovery Set ID
- The Recovery Set ID is the MD5 of the *Main packet body*.
- Clients should compute it from the Main packet and then require all packets in the set to match it exactly.

### File ID
- Each file is identified by a File ID (16 bytes), computed as the MD5 of:
	1) The file’s MD5-16k (MD5 of the first 16 KiB of the file),
	2) The file length (8 bytes, little-endian),
	3) The filename (ASCII bytes).
- Filenames are case sensitive. Use the exact filename bytes present in the File Description packet.
- Implementation note: tools should avoid embedding absolute paths in FileDesc names. A safe default is to store basenames and require exact-path matching only when explicitly requested by the caller.

## Core Packet Types (Required)
### Creator Packet
Packet Type: "PAR 2.0\0Creator\0"
Body:
- Arbitrary ASCII text identifying the program that created the set. Implementations should display this if they cannot process the set.

### Main Packet
Packet Type: "PAR 2.0\0Main\0\0\0\0"
Body:
- Slice Size (8 bytes). Must be a multiple of 4.
- Number of files in the recovery set (4 bytes).
- File IDs of recovery set files (16 bytes each), sorted by numerical value of the 16-byte File ID.
- File IDs of non-recovery set files (16 bytes each), also sorted.

### File Description Packet
Packet Type: "PAR 2.0\0FileDesc"
Body:
- File ID (16 bytes).
- MD5 of the full file (16 bytes).
- MD5-16k (16 bytes).
- File Length (8 bytes).
- File Name (ASCII bytes, remainder of body).

### Input File Slice Checksum Packet (IFSC)
Packet Type: "PAR 2.0\0IFSC\0\0\0\0"
Body:
- File ID (16 bytes).
- For each slice in the file, in order:
	- MD5 of the slice (16 bytes).
	- CRC32 of the slice (4 bytes).
- The final slice is zero-padded to the slice size before hashing.

### Recovery Slice Packet
Packet Type: "PAR 2.0\0RecvSlic"
Body:
- Exponent (4 bytes).
- Recovery Data (slice size bytes).

## Optional Packet Types (Should Be Parsed)
### Unicode Filename Packet
Packet Type: "PAR 2.0\0UniFileN"
Body:
- File ID (16 bytes).
- UTF-16LE filename (remainder of body).

### ASCII Comment Packet
Packet Type: "PAR 2.0\0CommASCI"
Body:
- ASCII comment text (remainder of body).

### Unicode Comment Packet
Packet Type: "PAR 2.0\0CommUni"
Body:
- MD5 of the ASCII comment text (16 bytes), or zeros if the ASCII comment packet does not exist or is not a translation.
- UTF-16LE comment text (remainder of body).

### Input File Slice Packet
Packet Type: "PAR 2.0\0FileSlic"
Body:
- File ID (16 bytes).
- Slice index (8 bytes).
- Slice Data (slice size bytes, zero-padded to 4-byte alignment).

### Recovery File Slice Checksum Packet
Packet Type: "PAR 2.0\0RFSC\0\0\0\0"
Body:
- File ID (16 bytes).
- For each recovery slice in the file, in order:
	- MD5 of the recovery slice (16 bytes).
	- CRC32 of the recovery slice (4 bytes).
	- Exponent used to generate the recovery slice (4 bytes).

### Packed Main Packet
Packet Type: "PAR 2.0\0PkdMain\0"
Body:
- Sub-slice size (8 bytes).
- Slice size (8 bytes).
- Number of files in the recovery set (4 bytes).
- File IDs of recovery set files (16 bytes each), sorted by numerical value.
- File IDs of non-recovery set files (16 bytes each), sorted by numerical value.

### Packed Recovery Slice Packet
Packet Type: "PAR 2.0\0PkdRecvS"
Body:
- Exponent (4 bytes).
- Packed recovery data (slice size bytes).

## File Naming Conventions (Non-Normative)
Common naming patterns observed in PAR2 tools:
- Base parity file: name.par2
- Recovery volumes: name.volXX-YY.par2 or name.partXX-YY.par2
Where XX-YY indicates the inclusive range of recovery exponents contained in the volume.

## Recovery Algorithm (Reed-Solomon over GF(2^16))
### Slicing and Ordering
1) Slice size is given by the Main packet. Split each recovery-set file into slices of that size, padding the final slice with zeros.
2) Order all slices by:
	- The file order in the Main packet (sorted by File ID), then
	- Slice index within each file.
3) For each slice in order, assign a *constant* from the sequence of valid 16-bit constants:
	- Constants are powers of two in GF(2^16) whose exponents are not divisible by 3, 5, 17, or 257.
	- There are 32768 such constants. Use them in increasing exponent order.

### Galois Field Definition
- Operations are in GF(2^16) with a generator polynomial 0x0001100B.
- Addition is XOR.
- Multiplication and exponentiation are defined in this field with the above generator polynomial.

### Recovery Slice Generation
For each recovery slice with exponent E:
- Interpret each slice as a sequence of 16-bit words (little-endian). Let s(i, t) be word t from input slice i.
- Let c(i) be the constant assigned to slice i.
- The recovery word r(t) is:
	r(t) = sum over i of s(i, t) * (c(i) ^ E) in GF(2^16)
- Emit all words r(t) in order as the recovery slice data.

### Validation
- Input file slices are validated using IFSC MD5/CRC32.
- Recovery slices can be validated using RecvChk packets (MD5/CRC32) if present.
- Full-file integrity is checked with the MD5 in File Description packets.

### Repair (Decoding)
- If slices are missing or invalid, select any set of recovery slices whose count equals the number of missing slices.
- Construct the linear system using the same constants/exponents and solve in GF(2^16) to recover missing slices.
- Use recovered slices plus verified slices to reconstruct the file bytes, then validate using File Description MD5.

## Implementation Notes (Non-Normative)
- Unknown packet types should be ignored, but preserved if you build a pass-through tool.
- Multiple Main packets or mixed Recovery Set IDs should be treated as distinct recovery sets.
- Always zero-pad slices before hashing or RS operations.
- Use streaming I/O and memory-mapped files for large sets to avoid memory spikes.
