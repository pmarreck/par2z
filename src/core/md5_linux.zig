const builtin = @import("builtin");

pub const Md5Error = error{Unavailable};

const ssl = @cImport({
	@cInclude("openssl/md5.h");
});

pub const Md5Ctx = struct {
	ctx: ssl.MD5_CTX,

	pub fn init() Md5Ctx {
		var ctx: ssl.MD5_CTX = undefined;
		_ = ssl.MD5_Init(&ctx);
		return .{ .ctx = ctx };
	}

	pub fn update(self: *Md5Ctx, data: []const u8) void {
		_ = ssl.MD5_Update(&self.ctx, data.ptr, data.len);
	}

	pub fn final(self: *Md5Ctx, out: *[16]u8) void {
		_ = ssl.MD5_Final(out, &self.ctx);
	}
};

pub fn md5Digest(data: []const u8, out: *[16]u8) Md5Error!void {
	if (builtin.os.tag != .linux) return error.Unavailable;
	_ = ssl.MD5(data.ptr, data.len, out);
}
