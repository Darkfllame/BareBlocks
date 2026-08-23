const Xoroshiro128PlusPlus = @This();
const std = @import("std");

const golden_ratio64: u64 = (~@as(u64, 7046029254386353131)) + 1;
const silver_ratio64: u64 = 7640891576956012809;

fn mixStafford13(z: u64) u64 {
    var lo = (z ^ z >> 30) *% (~@as(u64, 4658895280553007687) + 1);
    lo = (lo ^ lo >> 27) *% (~@as(u64, 7723592293110705685) + 1);
    return @bitCast(lo ^ lo >> 31);
}

fn upgradeSeedTo128BitUnmixed(seed: u64) [2]u64 {
    const lo = seed ^ silver_ratio64;
    const hi = lo +% golden_ratio64;
    return .{ lo, hi };
}

fn upgradeSeedTo128Bit(seed: u64) [2]u64 {
    const lo, const hi = upgradeSeedTo128BitUnmixed(seed);
    return .{ mixStafford13(lo), mixStafford13(hi) };
}

s: [2]u64,

pub fn init(s: u64) Xoroshiro128PlusPlus {
    const lo, const hi = upgradeSeedTo128Bit(s);
    return init2(lo, hi);
}

pub fn init2(seed_lo: u64, seed_hi: u64) Xoroshiro128PlusPlus {
    var ret = Xoroshiro128PlusPlus{ .s = .{ seed_lo, seed_hi } };
    if ((seed_lo | seed_hi) == 0) {
        ret.s = .{ golden_ratio64, silver_ratio64 };
    }
    return ret;
}

pub fn random(self: *Xoroshiro128PlusPlus) std.Random {
    return .{
        .ptr = self,
        .fillFn = @ptrCast(&fill),
    };
}

fn next(self: *Xoroshiro128PlusPlus) u64 {
    const s0 = self.s[0];
    var s1 = self.s[1];
    const result = std.math.rotl(u64, s0 +% s1, 17) +% s0;
    s1 ^= s0;
    self.s[0] = std.math.rotl(u64, s0, 49) ^ s1 ^ s1 << 21;
    self.s[1] = std.math.rotl(u64, s1, 28);
    return result;
}

fn fill(self: *Xoroshiro128PlusPlus, buf: []u8) void {
    var index: usize = 0;
    while (index < buf.len) {
        const res = self.next();
        const size = @min(buf.len, 8);
        const res_bytes = @as([]const u8, @ptrCast(&res))[0..size];
        @memcpy(buf[index..][0..size], res_bytes);
        index += size;
    }
}
