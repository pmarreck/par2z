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

## Source File Metadata Extension (Non-Standard)
### Source File Metadata Packet (SFMD)
Packet Type: "PAR 2.0\0SFMD\0\0\0\0"

Records source file metadata for change detection and permission restoration.

Body (little-endian, 64 bytes total):
| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 2 | Version | Packet format version. Current version: 2. |
| 2 | 2 | Flags | Metadata flags (see below) |
| 4 | 8 | mtime | Modification time in nanoseconds since Unix epoch |
| 12 | 8 | ctime | Change time in nanoseconds since Unix epoch (0 if unavailable) |
| 20 | 8 | size | File size in bytes |
| 28 | 4 | uid | Owner user ID (POSIX). 0xFFFFFFFF if unavailable. |
| 32 | 4 | gid | Owner group ID (POSIX). 0xFFFFFFFF if unavailable. |
| 36 | 2 | mode | POSIX permission bits (e.g., 0o644 = 0x01A4). 0xFFFF if unavailable. |
| 38 | 2 | Reserved | Padding, must be zero |
| 40 | 24 | Reserved | Future expansion, must be zero |

Metadata Flags (u16 bitmask):
| Bit | Mask | Name | Description |
|-----|------|------|-------------|
| 0 | 0x0001 | HAS_UID | uid field is valid |
| 1 | 0x0002 | HAS_GID | gid field is valid |
| 2 | 0x0004 | HAS_MODE | mode field is valid |
| 3 | 0x0008 | HAS_CTIME | ctime field is valid (not just zero) |
| 4-15 | | Reserved | Reserved for future use, must be zero |

Version History:
- Version 1: mtime, ctime, size only (original Entropy Shield release)
- Version 2: Added uid, gid, mode fields for complete POSIX metadata

Backward Compatibility:
- Readers should check the version field and ignore unknown fields
- Version 1 packets have uid=0xFFFFFFFF, gid=0xFFFFFFFF, mode=0xFFFF (unavailable)
- Writers should set appropriate HAS_* flags when fields contain valid data

Placement (par2z convention):
- Written immediately after the Main packet and before any Packed Main packet.
- Stored only in the main `.par2` file (not volume files).
- Single-file recovery sets only.

Other PAR2 implementations should ignore unknown packet types per the PAR2 spec.

### Source File Validation State Packet (SFVS)
Packet Type: "PAR 2.0\0SFVS\0\0\0\0"

Records the format validation state achieved when parity was created. Enables detection of
validator improvements (triggering re-validation) and preserves format identification even
if the source file's magic bytes become corrupted.

Body (little-endian, 36 bytes total):
| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 16 | File ID | MD5 identifying the source file (matches FileDesc) |
| 16 | 2 | Version | Packet format version. Current version: 1. |
| 18 | 1 | Flags | Validation flags (see below) |
| 19 | 1 | Reserved | Padding, must be zero |
| 20 | 4 | Container | FourCC of container format (e.g., "FORM", "RIFF"), or 0x00000000 if none |
| 24 | 4 | Subtype | FourCC of format subtype/variant (e.g., "IFRS", "WEBP", "PNG\0") |
| 28 | 8 | Reserved | Future expansion, must be zero |

Validation Flags (u8 bitmask):
| Bit | Mask | Name | Description |
|-----|------|------|-------------|
| 0 | 0x01 | MAGIC | Magic bytes / file signature validated |
| 1 | 0x02 | STRUCTURE | Container/chunk structure validated |
| 2 | 0x04 | CHECKSUM | Internal checksums verified (CRC, MD5, etc.) |
| 3 | 0x08 | DECODE | Decompression/decode succeeded |
| 4 | 0x10 | CHARSET | Character encoding validated (UTF-8, etc.) |
| 5 | 0x20 | SEMANTIC | Content semantically valid (XML well-formed, JSON parses, etc.) |
| 6 | 0x40 | Reserved | Reserved for future use, must be zero |
| 7 | 0x80 | COMPLETE | Every byte covered by integrity check |

COMPLETE Flag Semantics:
- COMPLETE (0x80) indicates that every byte in the file is covered by at least one integrity
  mechanism (checksum, hash, structural parse) such that corruption would be detected.
- For container formats with entry checksums (ZIP CRC32, PNG chunk CRCs), the container's
  checksums covering payload bytes satisfies COMPLETE - semantic validity of payloads
  (e.g., XML well-formedness inside DOCX) is not required.
- For text formats at top level (XML, JSON, UTF-8), successful parse implies COMPLETE
  since corruption would typically break the parse.
- COMPLETE should NOT be set for formats lacking internal integrity mechanisms (e.g., plain
  IFF with only length fields, arbitrary binary blobs) unless external validation is applied.

Container/Subtype Encoding:
- Use native FourCC codes where available (IFF: "FORM"/"AIFF", RIFF: "RIFF"/"WAVE")
- For non-container formats, Container = 0x00000000, Subtype = format identifier
- Suggested subtypes for common formats:
  - PNG: "PNG\0" (0x504E4700)
  - JPEG: "JPEG" (0x4A504547)
  - PDF: "PDF\0" (0x50444600)
  - ZIP: "ZIP\0" (0x5A495000)
  - FLAC: "fLaC" (0x664C6143)
  - Unknown: 0x00000000

Examples:
| File Type | Container | Subtype | Flags | Meaning |
|-----------|-----------|---------|-------|---------|
| PNG image | 0x00000000 | "PNG\0" | 0x87 | MAGIC\|STRUCTURE\|CHECKSUM\|COMPLETE |
| FLAC audio | 0x00000000 | "fLaC" | 0x8F | MAGIC\|STRUCTURE\|CHECKSUM\|DECODE\|COMPLETE |
| DOCX | "PK\x03\x04" | "DOCX" | 0x8F | MAGIC\|STRUCTURE\|CHECKSUM\|DECODE\|COMPLETE |
| Blorb (IF) | "FORM" | "IFRS" | 0x03 | MAGIC\|STRUCTURE (no COMPLETE - no checksums) |
| MP4 video | "ftyp" | "mp42" | 0x03 | MAGIC\|STRUCTURE (no deep validation) |
| UTF-8 text | 0x00000000 | "UTF8" | 0x90 | CHARSET\|COMPLETE |
| Unknown | 0x00000000 | 0x00000000 | 0x00 | No validation performed |

Placement (par2z convention):
- Written immediately after the SFMD packet (if present) or after Main packet.
- One SFVS packet per source file in the recovery set.
- Stored only in the main `.par2` file (not volume files).

Use Cases:
1. **Validator evolution**: Compare stored flags/format against current validator capabilities
   to identify files that would benefit from re-validation with improved validators.
2. **Corruption recovery**: If source file magic bytes are corrupted, Container/Subtype fields
   preserve format identification for recovery or reporting.
3. **Validation auditing**: Track validation coverage across a file collection over time.

### Directory Metadata Files (.par2d)

PAR2 is file-oriented and has no native directory concept. To preserve directory metadata
(permissions, timestamps, xattrs), we treat directories as special "files" with their own
parity containers using the `.par2d` extension.

**Naming Convention:**
- Directory path uses trailing slash: `photos/vacation/`
- Sidecar file: `.vacation.par2d` (in parity store, mirroring directory structure)
- SQLite relative_path: `"photos/vacation/"` (trailing slash indicates directory)

**File Structure:**
A `.par2d` file contains standard PAR2 packets but represents a directory, not a file:

| Packet | Contents |
|--------|----------|
| Main | Slice size = 0, single "file" (the directory) |
| FileDesc | File ID (MD5 of path), size = 0, name = "vacation/" |
| SFMD | Directory's uid, gid, mode, mtime, ctime |
| AAPL | Directory's extended attributes (optional, if present) |

**No recovery data**: Directories have no content, so no IFSC or RecvSlic packets.
The `.par2d` file is purely metadata. Packet MD5 hashes provide integrity checking.

**File ID for Directories:**
Since directories have no content, the File ID is computed as:
- MD5 of: MD5(empty) + length(0) + path_with_trailing_slash

**Tool Compatibility:**
- Standard PAR2 tools will ignore `.par2d` files (unknown extension)
- Our tools recognize the extension and trailing-slash path convention
- SQLite storage uses the same schema - just a different path pattern

**Use Cases:**
1. **Permission restoration**: Restore directory permissions after recovery.
2. **Access auditing**: Detect if directory permissions changed.
3. **Complete backup**: Combined with file SFMD, provides full POSIX metadata tree.

### Apple Extended Attributes Packet (AAPL)
Packet Type: "PAR 2.0\0AAPL\0\0\0\0"

Preserves macOS/HFS+ extended attributes including Finder Info (type/creator codes,
Finder flags, icon position) and other xattrs.

Body (little-endian, variable length):
| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 16 | File ID | MD5 identifying the source file (matches FileDesc) |
| 16 | 2 | Version | Packet format version. Current version: 1. |
| 18 | 2 | xattr_count | Number of extended attributes |
| 20 | ... | xattrs | Xattr entries (see below) |

Each xattr entry:
| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 2 | name_len | Length of xattr name in bytes |
| 2 | 4 | value_len | Length of xattr value in bytes |
| 6 | name_len | name | Xattr name (UTF-8, e.g., "com.apple.FinderInfo") |
| 6+name_len | value_len | value | Xattr value (raw bytes) |

Common xattrs preserved:
- `com.apple.FinderInfo` (32 bytes): Type code, creator code, Finder flags (including
  label color, custom icon, stationery, invisible, alias, and the infamous "BOZO bit"),
  icon location, extended flags.
- `com.apple.quarantine`: Gatekeeper quarantine info (configurable).
- `com.apple.metadata:*`: Spotlight metadata (configurable).
- Custom xattrs: User/application-defined attributes.

Platform Behavior:
- **macOS**: Always attempt to read/write xattrs.
- **Non-Apple platforms**: Skip AAPL packet creation to save space.
- **HFS+ on Linux/Windows**: Attempt if xattrs accessible via POSIX APIs.

Placement:
- One AAPL packet per source file with extended attributes.
- Written after DIRD packets, before recovery data.
- Stored only in the main `.par2` file (not volume files).

Note: Resource forks are handled separately as virtual files (large, benefit from own
recovery blocks). AAPL packet is for small metadata only.

### Windows ACL Packet (WACL)
Packet Type: "PAR 2.0\0WACL\0\0\0\0"

Preserves Windows NTFS access control lists (DACLs) and ownership information.

Body (little-endian, variable length):
| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 16 | File ID | MD5 identifying the source file (matches FileDesc) |
| 16 | 2 | Version | Packet format version (current: 1) |
| 18 | 2 | flags | Control flags (see below) |
| 20 | 4 | owner_len | Length of owner SID string (SDDL format) |
| 24 | 4 | group_len | Length of group SID string |
| 28 | 4 | dacl_len | Length of serialized DACL |
| 32 | owner_len | owner | Owner SID in SDDL format (e.g., "S-1-5-21-...") |
| ... | group_len | group | Group SID in SDDL format |
| ... | dacl_len | dacl | Serialized DACL (binary blob from GetSecurityDescriptorDacl) |

Flags (16-bit):
| Bit | Name | Description |
|-----|------|-------------|
| 0 | OWNER_PRESENT | Owner SID is included |
| 1 | GROUP_PRESENT | Group SID is included |
| 2 | DACL_PRESENT | DACL is included |
| 3 | DACL_PROTECTED | SE_DACL_PROTECTED - don't inherit from parent |
| 4-15 | Reserved | Must be zero |

Design Notes:
- SACL (audit ACLs) is intentionally excluded - requires elevated privileges (SeSecurityPrivilege)
  and is rarely user-configurable
- Owner/Group stored as SDDL strings for human readability and cross-version portability
- DACL stored as binary blob to preserve exact ACE ordering and flags
- Skip files with only inherited ACLs (no custom permissions set)

Platform Behavior:
- **Windows**: Read/write ACLs via GetFileSecurity/SetFileSecurity with
  OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION
- **Non-Windows platforms**: Skip WACL packet creation entirely

Placement:
- One WACL packet per source file with custom (non-inherited) ACLs
- Written after AAPL packets, before recovery data
- Stored only in the main `.par2` file (not volume files)

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
