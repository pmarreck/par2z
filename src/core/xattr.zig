const std = @import("std");
const builtin = @import("builtin");

pub const XattrError = error{
    OutOfMemory,
    NotSupported,
    AccessDenied,
    FileNotFound,
    SystemError,
};

/// Extended attribute entry
pub const XattrEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Check if the platform supports extended attributes
pub fn isSupported() bool {
    return builtin.os.tag == .macos or builtin.os.tag == .linux;
}

/// List all extended attribute names for a file.
/// Returns a slice of attribute names. Caller owns the returned memory.
pub fn listXattrs(allocator: std.mem.Allocator, path: []const u8) XattrError![][]const u8 {
    if (builtin.os.tag == .macos) {
        return listXattrsDarwin(allocator, path);
    } else if (builtin.os.tag == .linux) {
        return listXattrsLinux(allocator, path);
    } else {
        return error.NotSupported;
    }
}

/// Get the value of a specific extended attribute.
/// Caller owns the returned memory.
pub fn getXattr(allocator: std.mem.Allocator, path: []const u8, name: []const u8) XattrError![]const u8 {
    if (builtin.os.tag == .macos) {
        return getXattrDarwin(allocator, path, name);
    } else if (builtin.os.tag == .linux) {
        return getXattrLinux(allocator, path, name);
    } else {
        return error.NotSupported;
    }
}

/// Set an extended attribute on a file.
pub fn setXattr(path: []const u8, name: []const u8, value: []const u8) XattrError!void {
    if (builtin.os.tag == .macos) {
        return setXattrDarwin(path, name, value);
    } else if (builtin.os.tag == .linux) {
        return setXattrLinux(path, name, value);
    } else {
        return error.NotSupported;
    }
}

/// Read all extended attributes from a file.
/// Returns array of XattrEntry. Caller owns the returned memory.
pub fn readAllXattrs(allocator: std.mem.Allocator, path: []const u8) XattrError![]XattrEntry {
    const names = try listXattrs(allocator, path);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var entries = try allocator.alloc(XattrEntry, names.len);
    var valid_count: usize = 0;
    errdefer {
        for (entries[0..valid_count]) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(entries);
    }

    for (names) |name| {
        const value = getXattr(allocator, path, name) catch |e| {
            // Skip attributes we can't read (e.g., resource forks)
            if (e == error.AccessDenied) continue;
            return e;
        };
        const name_copy = try allocator.alloc(u8, name.len);
        @memcpy(name_copy, name);
        entries[valid_count] = .{ .name = name_copy, .value = value };
        valid_count += 1;
    }

    // Resize to actual count
    if (valid_count < entries.len) {
        const result = try allocator.realloc(entries, valid_count);
        return result;
    }
    return entries;
}

/// Write all extended attributes to a file.
pub fn writeAllXattrs(path: []const u8, entries: []const XattrEntry) XattrError!void {
    for (entries) |entry| {
        try setXattr(path, entry.name, entry.value);
    }
}

// Darwin/macOS implementation
fn listXattrsDarwin(allocator: std.mem.Allocator, path: []const u8) XattrError![][]const u8 {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;

    // First call to get size
    const size = std.posix.system.listxattr(&path_z, null, 0, 0);
    if (size < 0) {
        const errno: std.posix.E = @enumFromInt(-size);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }
    if (size == 0) return allocator.alloc([]const u8, 0);

    // Allocate buffer and get names
    const buf = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(buf);

    const result = std.posix.system.listxattr(&path_z, buf.ptr, buf.len, 0);
    if (result < 0) {
        const errno: std.posix.E = @enumFromInt(-result);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }

    // Count names (null-separated)
    var count: usize = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result))) {
        if (buf[i] == 0) count += 1;
        i += 1;
    }

    // Parse names
    var names = try allocator.alloc([]const u8, count);
    var name_idx: usize = 0;
    var start: usize = 0;
    i = 0;
    while (i < @as(usize, @intCast(result))) : (i += 1) {
        if (buf[i] == 0) {
            const name = try allocator.alloc(u8, i - start);
            @memcpy(name, buf[start..i]);
            names[name_idx] = name;
            name_idx += 1;
            start = i + 1;
        }
    }

    return names;
}

fn getXattrDarwin(allocator: std.mem.Allocator, path: []const u8, name: []const u8) XattrError![]const u8 {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;
    const name_z = std.posix.toPosixPath(name) catch return error.SystemError;

    // First call to get size
    const size = std.posix.system.getxattr(&path_z, &name_z, null, 0, 0, 0);
    if (size < 0) {
        const errno: std.posix.E = @enumFromInt(-size);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            .NOATTR => error.FileNotFound,
            else => error.SystemError,
        };
    }
    if (size == 0) return allocator.alloc(u8, 0);

    // Allocate and get value
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const result = std.posix.system.getxattr(&path_z, &name_z, buf.ptr, buf.len, 0, 0);
    if (result < 0) {
        const errno: std.posix.E = @enumFromInt(-result);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            .NOATTR => error.FileNotFound,
            else => error.SystemError,
        };
    }

    return buf;
}

fn setXattrDarwin(path: []const u8, name: []const u8, value: []const u8) XattrError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;
    const name_z = std.posix.toPosixPath(name) catch return error.SystemError;

    const result = std.posix.system.setxattr(&path_z, &name_z, value.ptr, value.len, 0, 0);
    if (result < 0) {
        const errno: std.posix.E = @enumFromInt(-result);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }
}

// Linux implementation
fn listXattrsLinux(allocator: std.mem.Allocator, path: []const u8) XattrError![][]const u8 {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;

    // First call to get size
    const size = std.os.linux.listxattr(&path_z, null, 0);
    if (@as(isize, @bitCast(size)) < 0) {
        const errno: std.posix.E = @enumFromInt(@as(u16, @truncate(-%@as(isize, @bitCast(size)))));
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }
    if (size == 0) return allocator.alloc([]const u8, 0);

    // Allocate buffer and get names
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    const result = std.os.linux.listxattr(&path_z, buf.ptr, buf.len);
    if (@as(isize, @bitCast(result)) < 0) {
        const errno: std.posix.E = @enumFromInt(@as(u16, @truncate(-%@as(isize, @bitCast(result)))));
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }

    // Count and parse names (null-separated)
    var count: usize = 0;
    for (buf[0..result]) |c| {
        if (c == 0) count += 1;
    }

    var names = try allocator.alloc([]const u8, count);
    var name_idx: usize = 0;
    var start: usize = 0;
    for (buf[0..result], 0..) |c, i| {
        if (c == 0) {
            const name = try allocator.alloc(u8, i - start);
            @memcpy(name, buf[start..i]);
            names[name_idx] = name;
            name_idx += 1;
            start = i + 1;
        }
    }

    return names;
}

fn getXattrLinux(allocator: std.mem.Allocator, path: []const u8, name: []const u8) XattrError![]const u8 {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;
    const name_z = std.posix.toPosixPath(name) catch return error.SystemError;

    // First call to get size
    const size = std.os.linux.getxattr(&path_z, &name_z, null, 0);
    if (@as(isize, @bitCast(size)) < 0) {
        const errno: std.posix.E = @enumFromInt(@as(u16, @truncate(-%@as(isize, @bitCast(size)))));
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            .NODATA => error.FileNotFound,
            else => error.SystemError,
        };
    }
    if (size == 0) return allocator.alloc(u8, 0);

    // Allocate and get value
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    const result = std.os.linux.getxattr(&path_z, &name_z, buf.ptr, buf.len);
    if (@as(isize, @bitCast(result)) < 0) {
        const errno: std.posix.E = @enumFromInt(@as(u16, @truncate(-%@as(isize, @bitCast(result)))));
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            .NODATA => error.FileNotFound,
            else => error.SystemError,
        };
    }

    return buf;
}

fn setXattrLinux(path: []const u8, name: []const u8, value: []const u8) XattrError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.FileNotFound;
    const name_z = std.posix.toPosixPath(name) catch return error.SystemError;

    const result = std.os.linux.setxattr(&path_z, &name_z, value.ptr, value.len, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        const errno: std.posix.E = @enumFromInt(@as(u16, @truncate(-%@as(isize, @bitCast(result)))));
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTSUP => error.NotSupported,
            else => error.SystemError,
        };
    }
}
