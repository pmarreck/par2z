const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
	.macos => @import("md5_macos.zig"),
	.linux => @import("md5_linux.zig"),
	else => @compileError("Unsupported OS for MD5 backend"),
};

pub const Md5Error = error{Unavailable};
pub const Md5Ctx = backend.Md5Ctx;

pub fn md5Digest(data: []const u8, out: *[16]u8) Md5Error!void {
	return backend.md5Digest(data, out);
}
