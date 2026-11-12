//! Vanilla's random sources (`XoroshiroRandomSource`, `LegacyRandomSource` and their positional factories).
const std = @import("std");
const java = @import("java.zig");

const golden_ratio_64: u64 = @bitCast(@as(i64, -7046029254386353131));
const silver_ratio_64: u64 = 7640891576956012809;

fn mixStafford13(seed: u64) u64 {
    var z = seed;
    z = (z ^ z >> 30) *% @as(u64, @bitCast(@as(i64, -4658895280553007687)));
    z = (z ^ z >> 27) *% @as(u64, @bitCast(@as(i64, -7723592293110705685)));
    return z ^ z >> 31;
}

pub const Xoroshiro = struct {
    lo: u64,
    hi: u64,

    pub fn init(seed: i64) Xoroshiro {
        const lo = @as(u64, @bitCast(seed)) ^ silver_ratio_64;
        const hi = lo +% golden_ratio_64;
        return .initSeeds(mixStafford13(lo), mixStafford13(hi));
    }

    pub fn initSeeds(lo: u64, hi: u64) Xoroshiro {
        if (lo | hi == 0) return .{ .lo = golden_ratio_64, .hi = silver_ratio_64 };
        return .{ .lo = lo, .hi = hi };
    }

    pub fn nextLong(self: *Xoroshiro) u64 {
        const s0 = self.lo;
        var s1 = self.hi;
        const result = std.math.rotl(u64, s0 +% s1, 17) +% s0;
        s1 ^= s0;
        self.lo = std.math.rotl(u64, s0, 49) ^ s1 ^ s1 << 21;
        self.hi = std.math.rotl(u64, s1, 28);
        return result;
    }

    fn nextBits(self: *Xoroshiro, comptime bits: u7) u64 {
        return self.nextLong() >> (64 - bits);
    }

    /// `nextInt(bound)`, in `[0; bound[`
    pub fn nextInt(self: *Xoroshiro, bound: u32) u32 {
        std.debug.assert(bound > 0);
        var multiplied = @as(u64, @as(u32, @truncate(self.nextLong()))) * bound;
        var fractional: u32 = @truncate(multiplied);
        if (fractional < bound) {
            const unbiased_start = (0 -% bound) % bound;
            while (fractional < unbiased_start) {
                multiplied = @as(u64, @as(u32, @truncate(self.nextLong()))) * bound;
                fractional = @truncate(multiplied);
            }
        }
        return @intCast(multiplied >> 32);
    }

    pub fn nextIntBetweenInclusive(self: *Xoroshiro, min: i32, max: i32) i32 {
        return @as(i32, @intCast(self.nextInt(@intCast(max - min + 1)))) + min;
    }

    pub fn nextBoolean(self: *Xoroshiro) bool {
        return self.nextLong() & 1 != 0;
    }

    pub fn nextFloat(self: *Xoroshiro) f32 {
        return @as(f32, @floatFromInt(self.nextBits(24))) * 0x1p-24;
    }

    pub fn nextDouble(self: *Xoroshiro) f64 {
        return @as(f64, @floatFromInt(self.nextBits(53))) * 0x1p-53;
    }

    pub fn forkPositional(self: *Xoroshiro) Positional {
        const lo = self.nextLong();
        return .{ .lo = lo, .hi = self.nextLong() };
    }
};

/// `XoroshiroPositionalRandomFactory`
pub const Positional = struct {
    lo: u64,
    hi: u64,

    pub fn at(self: Positional, x: i32, y: i32, z: i32) Xoroshiro {
        return .initSeeds(@as(u64, @bitCast(java.positionSeed(x, y, z))) ^ self.lo, self.hi);
    }

    /// The random of a name: md5 of it, first 8 bytes are the low seed, both big endian.
    pub fn fromHashOf(self: Positional, name: []const u8) Xoroshiro {
        var hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(name, &hash, .{});
        return .initSeeds(
            std.mem.readInt(u64, hash[0..8], .big) ^ self.lo,
            std.mem.readInt(u64, hash[8..16], .big) ^ self.hi,
        );
    }
};

/// `LegacyRandomSource`, the same generator as `java.util.Random`. Only old noises still use it.
pub const Legacy = struct {
    seed: u64,

    const mask = (1 << 48) - 1;

    pub fn init(seed: i64) Legacy {
        return .{ .seed = (@as(u64, @bitCast(seed)) ^ 0x5DEECE66D) & mask };
    }

    fn next(self: *Legacy, comptime bits: u6) i32 {
        self.seed = (self.seed *% 25214903917 +% 11) & mask;
        return @bitCast(@as(u32, @truncate(self.seed >> (48 - bits))));
    }

    pub fn nextInt(self: *Legacy, bound: i32) i32 {
        std.debug.assert(bound > 0);
        if (bound & (bound - 1) == 0) return @intCast((@as(i64, bound) * self.next(31)) >> 31);
        while (true) {
            const sample = self.next(31);
            const modulo = @rem(sample, bound);
            if (sample -% modulo +% (bound - 1) >= 0) return modulo;
        }
    }

    pub fn nextDouble(self: *Legacy) f64 {
        const upper: i64 = self.next(26);
        const lower: i64 = self.next(27);
        return @as(f64, @floatFromInt((upper << 27) + lower)) * 0x1p-53;
    }
};

test Xoroshiro {
    var r: Xoroshiro = .init(12345);
    try std.testing.expectEqual(@as(i64, -8118485274630516485), @as(i64, @bitCast(r.nextLong())));
    try std.testing.expectEqual(209, r.nextInt(256));
    try std.testing.expectEqual(@as(u64, 4597261291842716824), @as(u64, @bitCast(r.nextDouble())));
    try std.testing.expectEqual(@as(u32, 1032334136), @as(u32, @bitCast(r.nextFloat())));
}

test Positional {
    var r: Xoroshiro = .init(12345);
    const positional = r.forkPositional();
    var terrain = positional.fromHashOf("minecraft:terrain");
    try std.testing.expectEqual(@as(u64, 2469905110261187857), terrain.nextLong());
    var at = positional.at(1, -2, 300);
    try std.testing.expectEqual(@as(u64, 358717682115456064), at.nextLong());
}

test Legacy {
    // java.util.Random(42)
    var r: Legacy = .init(42);
    try std.testing.expectEqual(0, r.nextInt(10));
    try std.testing.expectEqual(63, r.nextInt(100));
    try std.testing.expectEqual(174, r.nextInt(256));
    try std.testing.expectEqual(@as(u64, 4587069603011894896), @as(u64, @bitCast(r.nextDouble())));
}
