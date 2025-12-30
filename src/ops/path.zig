const std = @import("std");

pub fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn dirNameOrDot(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

pub fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ a, b });
}

pub fn joinOptional(allocator: std.mem.Allocator, maybe_base: ?[]const u8, leaf: []const u8) ![]const u8 {
    return if (maybe_base) |base|
        std.fs.path.join(allocator, &.{ base, leaf })
    else
        allocator.dupe(u8, leaf);
}
