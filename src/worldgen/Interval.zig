//! The range of values a density function can give (vanilla's `Interval`).
//!
//! Vanilla uses them to skip work (a `min` whose sides can't overlap only keeps one), which
//! decides what gets sampled and cached, so they're computed the same way here.
const Interval = @This();
const std = @import("std");
const java = @import("java.zig");

min: f32,
max: f32,

/// "Not an interval", what operations on impossible ranges give.
pub const nai: Interval = .{ .min = std.math.nan(f32), .max = std.math.nan(f32) };
pub const infinite: Interval = .{ .min = -std.math.inf(f32), .max = std.math.inf(f32) };

pub fn isNai(self: Interval) bool {
    return self.min != self.min or self.max != self.max;
}

pub fn of(min: f32, max: f32) Interval {
    std.debug.assert(max >= min);
    return .{ .min = min, .max = max };
}

pub fn exact(value: f32) Interval {
    return .of(value, value);
}

pub fn symmetric(range: f32) Interval {
    return .of(-range, range);
}

pub fn contains(self: Interval, value: f32) bool {
    return value >= self.min and value <= self.max;
}

fn fmin(a: f32, b: f32) f32 {
    return java.javaMin(f32, a, b);
}

fn fmax(a: f32, b: f32) f32 {
    return java.javaMax(f32, a, b);
}

pub fn encapsulating(intervals: []const Interval) Interval {
    var min = std.math.inf(f32);
    var max = -std.math.inf(f32);
    for (intervals) |interval| {
        if (interval.isNai()) continue;
        min = fmin(interval.min, min);
        max = fmax(interval.max, max);
    }
    if (max < min) return nai;
    return .of(min, max);
}

pub fn encapsulatingValues(first: f32, second: f32) Interval {
    if (first != first and second != second) return nai;
    if (first != first) return .exact(second);
    if (second != second) return .exact(first);
    return .of(fmin(first, second), fmax(first, second));
}

pub fn add(left: Interval, right: Interval) Interval {
    const min = left.min + right.min;
    const max = left.max + right.max;
    if (min != min or max != max) return nai;
    return .of(min, max);
}

pub fn sub(left: Interval, right: Interval) Interval {
    const min = left.min - right.max;
    const max = left.max - right.min;
    if (min != min or max != max) return nai;
    return .of(min, max);
}

fn mulBound(left: f32, right: f32) f32 {
    return if (left == 0.0 or right == 0.0) 0.0 else left * right;
}

pub fn mul(left: Interval, right: Interval) Interval {
    if (left.isNai() or right.isNai()) return nai;
    const min_min = mulBound(left.min, right.min);
    const min_max = mulBound(left.min, right.max);
    const max_min = mulBound(left.max, right.min);
    const max_max = mulBound(left.max, right.max);
    return .of(fmin(fmin(min_min, min_max), fmin(max_min, max_max)), fmax(fmax(min_min, min_max), fmax(max_min, max_max)));
}

pub fn reciprocal(input: Interval) Interval {
    if (input.isNai() or (input.min == 0.0 and input.max == 0.0)) return nai;
    if (!input.contains(0.0)) return .of(1.0 / input.max, 1.0 / input.min);
    if (input.max == 0.0) return .of(-std.math.inf(f32), 1.0 / input.min);
    if (input.min == 0.0) return .of(1.0 / input.max, std.math.inf(f32));
    return infinite;
}

pub fn div(left: Interval, right: Interval) Interval {
    return mul(left, reciprocal(right));
}

pub fn minOf(left: Interval, right: Interval) Interval {
    if (left.isNai() or right.isNai()) return nai;
    return .of(fmin(left.min, right.min), fmin(left.max, right.max));
}

pub fn maxOf(left: Interval, right: Interval) Interval {
    if (left.isNai() or right.isNai()) return nai;
    return .of(fmax(left.min, right.min), fmax(left.max, right.max));
}

pub fn clamp(input: Interval, min: f32, max: f32) Interval {
    if (input.isNai()) return nai;
    if (input.min >= max) return .of(max, max);
    if (input.max <= min) return .of(min, min);
    return .of(fmax(input.min, min), fmin(input.max, max));
}

pub fn abs(input: Interval) Interval {
    if (input.isNai()) return nai;
    const max = fmax(@abs(input.min), @abs(input.max));
    if (input.contains(0.0)) return .of(0.0, max);
    return .of(fmin(@abs(input.min), @abs(input.max)), max);
}

pub fn square(input: Interval) Interval {
    if (input.isNai()) return nai;
    const max = fmax(input.min * input.min, input.max * input.max);
    if (input.contains(0.0)) return .of(0.0, max);
    return .of(fmin(input.min * input.min, input.max * input.max), max);
}

/// The range of `op` over the input, `op` only ever goes up or down.
pub fn mapMonotonic(input: Interval, context: anytype, comptime op: fn (@TypeOf(context), f32) f32) Interval {
    if (input.isNai()) return nai;
    const mapped_min = op(context, input.min);
    const mapped_max = op(context, input.max);
    return .of(fmin(mapped_min, mapped_max), fmax(mapped_min, mapped_max));
}

pub fn sign(input: Interval) Interval {
    if (input.isNai()) return nai;
    if (input.min == input.max) return .exact(std.math.sign(input.min));
    if (input.contains(0.0)) {
        if (input.min == 0.0) return .of(0.0, 1.0);
        if (input.max == 0.0) return .of(-1.0, 0.0);
        return .of(-1.0, 1.0);
    }
    return .exact(if (input.min > 0.0) 1.0 else -1.0);
}

pub fn lerp(alpha: Interval, first: Interval, second: Interval) Interval {
    if (alpha.isNai() or first.isNai() or second.isNai()) return nai;
    return encapsulating(&.{
        lerpValues(alpha, first.min, second.min),
        lerpValues(alpha, first.max, second.min),
        lerpValues(alpha, first.min, second.max),
        lerpValues(alpha, first.max, second.max),
    });
}

fn lerpValues(alpha: Interval, first: f32, second: f32) Interval {
    if (alpha.isNai() or first != first or second != second) return nai;
    if (std.math.isFinite(first) and std.math.isFinite(second)) {
        return encapsulatingValues(first + mulBound(alpha.min, second - first), first + mulBound(alpha.max, second - first));
    }
    if (first == second) return .exact(first);
    const new_min = lerpInfiniteBound(alpha.min, first, second);
    const new_max = lerpInfiniteBound(alpha.max, first, second);
    if (new_min != new_min or new_max != new_max) return nai;
    return encapsulatingValues(new_min, new_max);
}

fn lerpInfiniteBound(alpha: f32, first: f32, second: f32) f32 {
    const first_part = mulBound(1.0 - alpha, first);
    const second_part = mulBound(alpha, second);
    if (std.math.isInf(first_part) and std.math.isInf(second_part)) {
        if (alpha <= 0.0) return if (second > first) -std.math.inf(f32) else std.math.inf(f32);
        if (alpha >= 1.0) return if (second > first) std.math.inf(f32) else -std.math.inf(f32);
        return std.math.nan(f32);
    }
    return first_part + second_part;
}

test Interval {
    const a: Interval = .of(-1.0, 2.0);
    const b: Interval = .of(0.5, 3.0);
    try std.testing.expectEqual(Interval.of(-0.5, 5.0), add(a, b));
    try std.testing.expectEqual(Interval.of(-4.0, 1.5), sub(a, b));
    try std.testing.expectEqual(Interval.of(-3.0, 6.0), mul(a, b));
    try std.testing.expectEqual(Interval.of(0.0, 4.0), square(a));
    try std.testing.expectEqual(Interval.of(0.0, 2.0), abs(a));
    try std.testing.expectEqual(Interval.of(-1.0, 2.0), minOf(a, b));
    try std.testing.expect(reciprocal(.exact(0.0)).isNai());
    try std.testing.expectEqual(infinite, reciprocal(a));
}
