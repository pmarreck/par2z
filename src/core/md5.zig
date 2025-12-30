const std = @import("std");

pub const Md5Error = error{};
pub const Md5Ctx = std.crypto.hash.Md5;

pub fn md5Digest(data: []const u8, out: *[16]u8) Md5Error!void {
	var ctx = Md5Ctx.init(.{});
	ctx.update(data);
	ctx.final(out);
}
