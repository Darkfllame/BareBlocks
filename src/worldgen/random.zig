//! Vanilla's random sources that aren't in `utils` (`LegacyRandomSource` and the positional factories).
const std = @import("std");
const utils = @import("utils");
const java = @import("java.zig");

/// `XoroshiroRandomSource`
pub const Xoroshiro = utils.Xoroshiro128PlusPlus;

/// `RandomSource.forkPositional`
pub fn forkPositional(rand: *Xoroshiro) Positional {
    const lo = rand.next();
    return .{ .lo = lo, .hi = rand.next() };
}

/// `XoroshiroPositionalRandomFactory`
pub const Positional = struct {
    lo: u64,
    hi: u64,

    pub fn at(self: Positional, x: i32, y: i32, z: i32) Xoroshiro {
        return .init2(@as(u64, @bitCast(java.positionSeed(x, y, z))) ^ self.lo, self.hi);
    }

    /// The random of a name: md5 of it, first 8 bytes are the low seed, both big endian.
    pub fn fromHashOf(self: Positional, name: []const u8) Xoroshiro {
        var hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(name, &hash, .{});
        return .init2(
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

test Positional {
    var r: Xoroshiro = .init(12345);
    const positional = forkPositional(&r);
    var terrain = positional.fromHashOf("minecraft:terrain");
    try std.testing.expectEqual(@as(u64, 2469905110261187857), terrain.next());
    var at = positional.at(1, -2, 300);
    try std.testing.expectEqual(@as(u64, 358717682115456064), at.next());
}

test Legacy {
    // java.util.Random(42)
    var r: Legacy = .init(42);
    try std.testing.expectEqual(0, r.nextInt(10));
    try std.testing.expectEqual(63, r.nextInt(100));
    try std.testing.expectEqual(174, r.nextInt(256));
    try std.testing.expectEqual(@as(u64, 4587069603011894896), @as(u64, @bitCast(r.nextDouble())));
}
