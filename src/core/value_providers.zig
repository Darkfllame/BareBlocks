const std = @import("std");
const utils = @import("utils");

const Io = std.Io;
const serial = utils.serial;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;

pub const IntProvider = union(enum) {
    constant: i32,
    uniform: utils.Range(i32),
    biased_to_bottom: utils.Range(i32),
    clamped: struct {
        range: utils.Range(i32),
        source: *const IntProvider,
    },
    clamped_normal: struct {
        range: utils.Range(i32),
        mean: f32,
        deviation: f32,
    },
    weighted_list: struct {
        weights: []const i32,
        /// Same length as `weights`
        values: [*]const IntProvider,
    },
    trapezoid: struct {
        range: utils.Range(i32),
        plateau: i32,
    },

    pub fn sample(self: *const IntProvider, rnd: *utils.RandomPair) i32 {
        return switch (self.*) {
            .constant => |v| v,
            .uniform => |r| rnd.intRangeAtMost(i32, r.min, r.max),
            .biased_to_bottom => |r| rnd.intRangeAtMost(i32, r.min, rnd.intRangeAtMost(i32, r.min, r.max)),
            .clamped => |cl| cl.range.clamp(cl.source.sample(rnd)),
            .clamped_normal => |cln| std.math.lossyCast(
                i32,
                cln.range.castLossy(f32).clamp(rnd.normal(cln.mean, cln.deviation)),
            ),
            .weighted_list => |wl| wl.values[rnd.weightedIndex(i32, wl.weights)].sample(rnd),
            .trapezoid => |trapezoid| {
                if (trapezoid.plateau == 0 and trapezoid.range.max == -trapezoid.range.min) {
                    return rnd.intRangeAtMost(i32, 0, trapezoid.range.max + 1) -
                        rnd.intRangeAtMost(i32, 0, trapezoid.range.max + 1);
                }

                const range = trapezoid.range.max - trapezoid.range.min;
                if (trapezoid.plateau == range) {
                    return rnd.intRangeAtMost(i32, trapezoid.range.min, trapezoid.range.max);
                }

                const plateau_start = @divFloor((range - trapezoid.plateau), 2);
                const plateau_end = range - plateau_start;

                return trapezoid.range.min +
                    rnd.intRangeAtMost(i32, 0, plateau_end) +
                    rnd.intRangeAtMost(i32, 0, plateau_start);
            },
        };
    }
};

pub const FloatProvider = union(enum) {
    constant: f32,
    uniform: utils.Range(f32),
    clamped_normal: struct {
        range: utils.Range(f32),
        mean: f32,
        deviation: f32,
    },
    trapezoid: struct {
        range: utils.Range(f32),
        plateau: f32,
    },
};
