const builtin = @import("builtin");

pub const Md5Error = error{Unavailable};

const cc = @cImport({
	@cInclude("CommonCrypto/CommonDigest.h");
});

pub const Md5Ctx = struct {
	ctx: cc.CC_MD5_CTX,

	pub fn init() Md5Ctx {
		var ctx: cc.CC_MD5_CTX = undefined;
		_ = cc.CC_MD5_Init(&ctx);
		return .{ .ctx = ctx };
	}

	pub fn update(self: *Md5Ctx, data: []const u8) void {
		_ = cc.CC_MD5_Update(&self.ctx, data.ptr, @as(cc.CC_LONG, @intCast(data.len)));
	}

	pub fn final(self: *Md5Ctx, out: *[16]u8) void {
		_ = cc.CC_MD5_Final(out, &self.ctx);
	}
};

pub fn md5Digest(data: []const u8, out: *[16]u8) Md5Error!void {
	if (builtin.os.tag != .macos) return error.Unavailable;
	_ = cc.CC_MD5(data.ptr, @as(cc.CC_LONG, @intCast(data.len)), out);
}
