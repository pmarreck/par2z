const std = @import("std");

/// Hash algorithm selector. Values are stable on-disk identifiers — they appear
/// in MECHCFG packet bodies and MUST NOT change between releases.
pub const HashAlgo = enum(u32) {
    md5 = 0,
    blake3_128 = 1,
};

/// One-shot 16-byte digest dispatch. BLAKE3 is truncated to 128 bits so it
/// drops into PAR2's existing 16-byte hash fields without changing the wire
/// format.
pub fn hashDigest(algo: HashAlgo, data: []const u8, out: *[16]u8) void {
    switch (algo) {
        .md5 => {
            var ctx = std.crypto.hash.Md5.init(.{});
            ctx.update(data);
            ctx.final(out);
        },
        .blake3_128 => {
            var ctx = std.crypto.hash.Blake3.init(.{});
            ctx.update(data);
            ctx.final(out[0..16]);
        },
    }
}

/// Streaming context. Use init/update/final for incremental hashing.
pub const HashCtx = struct {
    algo: HashAlgo,
    state: State,

    const State = union {
        md5: std.crypto.hash.Md5,
        blake3: std.crypto.hash.Blake3,
    };

    pub fn init(algo: HashAlgo) HashCtx {
        return switch (algo) {
            .md5 => .{ .algo = algo, .state = .{ .md5 = std.crypto.hash.Md5.init(.{}) } },
            .blake3_128 => .{ .algo = algo, .state = .{ .blake3 = std.crypto.hash.Blake3.init(.{}) } },
        };
    }

    pub fn update(self: *HashCtx, data: []const u8) void {
        switch (self.algo) {
            .md5 => self.state.md5.update(data),
            .blake3_128 => self.state.blake3.update(data),
        }
    }

    pub fn final(self: *HashCtx, out: *[16]u8) void {
        switch (self.algo) {
            .md5 => self.state.md5.final(out),
            .blake3_128 => self.state.blake3.final(out[0..16]),
        }
    }
};
