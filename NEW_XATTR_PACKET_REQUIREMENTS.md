# AAPL Packet - Extended Attributes Preservation

**Note:** The formal packet specification is now in [PAR2_SPECIFICATION.md](PAR2_SPECIFICATION.md).
This document contains additional implementation notes and rationale.

## Overview

A new PAR2 packet type for preserving Apple/HFS+ extended attributes, including Finder Info (type/creator codes, Finder flags, icon position, etc.).

Named "AAPL" after Apple's ticker symbol.

---

## Motivation

macOS files can have extended attributes (`xattrs`) that contain important metadata:

- **`com.apple.FinderInfo`** (32 bytes) - The classic HFS metadata:
  - Type code (4 bytes) - e.g., 'TEXT', 'APPL'
  - Creator code (4 bytes) - e.g., 'MSWD', 'R*ch'
  - Finder flags (2 bytes) - 16 bits including:
    - Bits 1-3: Label color
    - Bit 7: Has custom icon
    - Bit 8: Is stationery
    - Bit 11: Is invisible
    - Bit 12: Is alias
    - Bit 13: The infamous "BOZO bit" (copy protection)
  - Icon location (4 bytes) - position in folder window
  - Folder ID (2 bytes)
  - Extended flags, put-away folder, etc. (16 more bytes)

- **`com.apple.quarantine`** - Gatekeeper quarantine info
- **`com.apple.metadata:*`** - Spotlight metadata
- **Custom xattrs** - User/application-defined attributes

Standard PAR2 only preserves filename, size, and content hash. Extended attributes are lost.

---

## Packet Specification

### Packet Type

```
Magic: "PAR 2.0\0AAPL\0\0\0\0"
```

(16 bytes, null-padded to align with PAR2 packet type field)

### Packet Body Structure

```
┌─────────────────────────────────────────────────────────┐
│ File ID (16 bytes)                                      │
│   - MD5 hash matching the FileDesc packet               │
├─────────────────────────────────────────────────────────┤
│ Xattr Count (u16, little-endian)                        │
│   - Number of extended attributes stored                │
├─────────────────────────────────────────────────────────┤
│ Reserved (2 bytes)                                      │
│   - For future use, set to 0                            │
├─────────────────────────────────────────────────────────┤
│ Xattr Entries (variable length, repeated)               │
│   ┌─────────────────────────────────────────────────┐   │
│   │ Name Length (u16, little-endian)                │   │
│   │   - Length of xattr name in bytes (excl. null)  │   │
│   ├─────────────────────────────────────────────────┤   │
│   │ Value Length (u32, little-endian)               │   │
│   │   - Length of xattr value in bytes              │   │
│   ├─────────────────────────────────────────────────┤   │
│   │ Name (variable, UTF-8)                          │   │
│   │   - e.g., "com.apple.FinderInfo"                │   │
│   │   - NOT null-terminated                         │   │
│   ├─────────────────────────────────────────────────┤   │
│   │ Value (variable, raw bytes)                     │   │
│   │   - The xattr value as-is                       │   │
│   └─────────────────────────────────────────────────┘   │
│   (repeat for each xattr)                               │
└─────────────────────────────────────────────────────────┘
```

### Size Constraints

- Maximum xattr name length: 127 bytes (XATTR_MAXNAMELEN on macOS)
- Maximum xattr value length: Technically unlimited, but typically small
  - `com.apple.FinderInfo`: 32 bytes
  - `com.apple.quarantine`: ~100 bytes typically
- One AAPL packet per file (if file has xattrs)

---

## Platform Behavior

### When to Create AAPL Packets

AAPL packets should **only** be created when:

1. **Running on macOS**, OR
2. **Accessing an Apple filesystem** (HFS+, APFS) from another OS

Detection heuristic:
```
if (builtin.os.tag == .macos) {
    // Always try to read xattrs
} else {
    // Check if filesystem supports Apple xattrs
    // This is a corner case (e.g., HFS+ disk on Linux/Windows)
    // Implementation TBD - may require filesystem type detection
}
```

### When to Skip AAPL Packets

- On non-Apple platforms accessing non-Apple filesystems
- When a file has no extended attributes
- When all xattrs are empty

### On Restore/Repair

When restoring a file:

1. If AAPL packet exists for the file AND platform supports xattrs:
   - Restore all xattrs from the packet
2. If AAPL packet exists but platform doesn't support xattrs:
   - Log a warning, skip xattr restoration
   - File content is still restored correctly
3. If no AAPL packet exists:
   - Normal restoration (no xattrs to restore)

---

## Corner Cases

### HFS+ Disk Accessed from Windows/Linux

This is technically possible via:
- Linux: `hfsplus` kernel module, `hfsprogs`
- Windows: Paragon HFS+, MacDrive, etc.

In these cases:
- xattrs may be accessible through the mount driver
- Or may be stored in AppleDouble (`._filename`) sidecar files

**Recommendation**: If we can read xattrs via standard POSIX APIs (`getxattr`/`listxattr`), store them. Don't try to parse AppleDouble files - that's a separate concern.

### AppleDouble Files (`._filename`)

These are sidecar files created when copying Mac files to non-Apple filesystems. They contain:
- Resource fork data
- Finder Info
- Other metadata

**Recommendation**: Treat AppleDouble files as regular files. If the user wants to protect them, protect them. Don't try to merge/extract their contents into AAPL packets - too complex and error-prone.

### Resource Forks

Resource forks are handled separately (as virtual files via `/..namedfork/rsrc`). The AAPL packet is for small metadata only, not large resource fork data.

---

## Implementation Notes

### Reading Xattrs (macOS)

```zig
const std = @import("std");

pub fn listXattrs(path: []const u8) ![][]const u8 {
    // Use listxattr() syscall
}

pub fn getXattr(path: []const u8, name: []const u8) ![]const u8 {
    // Use getxattr() syscall
}
```

### Writing Xattrs (macOS)

```zig
pub fn setXattr(path: []const u8, name: []const u8, value: []const u8) !void {
    // Use setxattr() syscall
}
```

### Xattrs to Preserve

Suggested default list:
- `com.apple.FinderInfo` - Always (if present)
- `com.apple.ResourceFork` - Skip (handled separately as virtual file)
- `com.apple.quarantine` - Configurable (security implications)
- `com.apple.metadata:*` - Configurable (Spotlight, may be large)
- All others - Configurable

### Configuration

User settings should include:
- `preserve_finder_info: bool = true`
- `preserve_quarantine: bool = false` (default off - security)
- `preserve_spotlight_metadata: bool = false` (can be regenerated)
- `preserve_custom_xattrs: bool = true`

---

## Compatibility

### With Standard PAR2 Tools

Standard PAR2 tools (par2cmdline, MultiPar, etc.) will:
- Ignore AAPL packets (unknown packet type)
- Still be able to verify and repair file content
- Not restore xattrs (they don't know about them)

This is acceptable - the PAR2 spec explicitly allows custom packet types.

### Forward Compatibility

The packet includes:
- Reserved bytes for future expansion
- Version could be added if needed (use reserved bytes)

---

## References

- [PAR2 Specification](PAR2_SPECIFICATION.md)
- [Apple Extended Attributes](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/GeneralCharacteristics/GeneralCharacteristics.html)
- [HFS+ Volume Format](https://developer.apple.com/library/archive/technotes/tn/tn1150.html)
- [xattr(2) man page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getxattr.2.html)

---

## Status

**Draft** - Not yet implemented.

Target: Entropy Shield future release (see `FUTURE_PLANS.md`)
