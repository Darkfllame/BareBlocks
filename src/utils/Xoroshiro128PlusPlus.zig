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

pub fn next(self: *Xoroshiro128PlusPlus) u64 {
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
        const size = @min(buf.len - index, 8);
        @memcpy(buf[index..][0..size], std.mem.asBytes(&res)[0..size]);
        index += size;
    }
}

// What vanilla's `XoroshiroRandomSource` makes of it, worldgen needs the same numbers

fn nextBits(self: *Xoroshiro128PlusPlus, comptime bits: u7) u64 {
    return self.next() >> (64 - bits);
}

/// In `[0; bound[`
pub fn nextInt(self: *Xoroshiro128PlusPlus, bound: u32) u32 {
    std.debug.assert(bound > 0);
    var multiplied = @as(u64, @as(u32, @truncate(self.next()))) * bound;
    var fractional: u32 = @truncate(multiplied);
    if (fractional < bound) {
        const unbiased_start = (0 -% bound) % bound;
        while (fractional < unbiased_start) {
            multiplied = @as(u64, @as(u32, @truncate(self.next()))) * bound;
            fractional = @truncate(multiplied);
        }
    }
    return @intCast(multiplied >> 32);
}

pub fn nextIntBetweenInclusive(self: *Xoroshiro128PlusPlus, min: i32, max: i32) i32 {
    return @as(i32, @intCast(self.nextInt(@intCast(max - min + 1)))) + min;
}

pub fn nextBoolean(self: *Xoroshiro128PlusPlus) bool {
    return self.next() & 1 != 0;
}

pub fn nextFloat(self: *Xoroshiro128PlusPlus) f32 {
    return @as(f32, @floatFromInt(self.nextBits(24))) * 0x1p-24;
}

pub fn nextDouble(self: *Xoroshiro128PlusPlus) f64 {
    return @as(f64, @floatFromInt(self.nextBits(53))) * 0x1p-53;
}

test Xoroshiro128PlusPlus {
    // Same as vanilla's `XoroshiroRandomSource(12345)`
    var r: Xoroshiro128PlusPlus = .init(12345);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -8118485274630516485))), r.next());
    try std.testing.expectEqual(209, r.nextInt(256));
    try std.testing.expectEqual(@as(u64, 4597261291842716824), @as(u64, @bitCast(r.nextDouble())));
    try std.testing.expectEqual(@as(u32, 1032334136), @as(u32, @bitCast(r.nextFloat())));

    var buf: [12]u8 = undefined;
    r.random().bytes(&buf);
}
