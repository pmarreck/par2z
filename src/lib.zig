const std = @import("std");
pub const ops = @import("ops");

pub const version_string: []const u8 = "par2-cleanroom 0.1.0";

pub const Par2Error = enum(c_int) {
	ok = 0,
	unimplemented = 1,
	invalid_argument = 2,
};

pub const Par2Ctx = opaque {};

export fn par2_version() [*:0]const u8 {
	return "par2-cleanroom 0.1.0";
}

export fn par2_ctx_create(out_ctx: ?*?*Par2Ctx) Par2Error {
	if (out_ctx == null) {
		return .invalid_argument;
	}
	out_ctx.?.* = null;
	return .unimplemented;
}

export fn par2_ctx_destroy(_: ?*Par2Ctx) void {}

pub fn zigVersion() []const u8 {
	return version_string;
}
