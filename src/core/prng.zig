const std = @import("std");

pub const Pcg32 = struct {
    state: u64,
    inc: u64,

    pub fn init(seed: u64, seq: u64) Pcg32 {
        var rng = Pcg32{
            .state = 0,
            .inc = (seq << 1) | 1,
        };
        _ = rng.nextU32();
        rng.state +%= seed;
        _ = rng.nextU32();
        return rng;
    }

    pub fn nextU32(self: *Pcg32) u32 {
        const oldstate = self.state;
        self.state = (oldstate *% 6364136223846793005) +% self.inc;
        const xorshifted: u32 = @as(u32, @truncate(((oldstate >> 18) ^ oldstate) >> 27));
        const rot: u5 = @intCast(oldstate >> 59);
        return std.math.rotr(u32, xorshifted, rot);
    }

    pub fn fillBytes(self: *Pcg32, out: []u8) void {
        var i: usize = 0;
        while (i < out.len) {
            const v = self.nextU32();
            out[i] = @as(u8, @intCast(v & 0xFF));
            i += 1;
            if (i >= out.len) break;
            out[i] = @as(u8, @intCast((v >> 8) & 0xFF));
            i += 1;
            if (i >= out.len) break;
            out[i] = @as(u8, @intCast((v >> 16) & 0xFF));
            i += 1;
            if (i >= out.len) break;
            out[i] = @as(u8, @intCast((v >> 24) & 0xFF));
            i += 1;
        }
    }
};
