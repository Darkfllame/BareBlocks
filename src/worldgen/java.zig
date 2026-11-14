//! Java's arithmetic where it's different from Zig's, and the bits of `Mth` worldgen uses.
//! Everything in worldgen has to round the same way vanilla does, so the order of operations matters.
const std = @import("std");
const lerp = @import("math").lm.lerp;

/// `(int)` of a double: saturates, NaN is 0.
pub fn toInt(v: f64) i32 {
    if (v != v) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// `(long)` of a double: saturates, NaN is 0.
pub fn toLong(v: f64) i64 {
    if (v != v) return 0;
    if (v >= 9223372036854775807.0) return std.math.maxInt(i64);
    if (v <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(v);
}

/// `Mth.floor`
pub fn floor(v: f64) i32 {
    return toInt(@floor(v));
}

pub fn lerp2(alpha1: f32, alpha2: f32, x00: f32, x10: f32, x01: f32, x11: f32) f32 {
    return lerp(f32, lerp(f32, x00, x10, alpha1), lerp(f32, x01, x11, alpha1), alpha2);
}

pub fn lerp3(alpha1: f32, alpha2: f32, alpha3: f32, x000: f32, x100: f32, x010: f32, x110: f32, x001: f32, x101: f32, x011: f32, x111: f32) f32 {
    return lerp(f32, lerp2(alpha1, alpha2, x000, x100, x010, x110), lerp2(alpha1, alpha2, x001, x101, x011, x111), alpha3);
}

pub fn smoothstep(x: f32) f32 {
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

/// `Mth.clamp` for floats, not the same as `std.math.clamp` with NaNs.
pub fn clamp(comptime T: type, value: T, min: T, max: T) T {
    if (value < min) return min;
    return javaMin(T, value, max);
}

/// `Math.min`: NaN if any is NaN, -0.0 is smaller than 0.0.
pub fn javaMin(comptime T: type, a: T, b: T) T {
    if (a != a) return a;
    if (a == 0 and b == 0 and std.math.signbit(b)) return b;
    return if (a <= b) a else b;
}

/// `Math.max`: NaN if any is NaN, 0.0 is bigger than -0.0.
pub fn javaMax(comptime T: type, a: T, b: T) T {
    if (a != a) return a;
    if (a == 0 and b == 0 and std.math.signbit(a)) return b;
    return if (a >= b) a else b;
}

/// `Mth.getSeed`
pub fn positionSeed(x: i32, y: i32, z: i32) i64 {
    var seed: i64 = @as(i64, x *% 3129871) ^ (@as(i64, z) *% 116129781) ^ @as(i64, y);
    seed = seed *% seed *% 42317861 +% seed *% 11;
    return seed >> 16;
}
