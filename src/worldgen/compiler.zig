//! Turns density functions into samplers the way vanilla's `DensityFunctionCompiler` does:
//! - references get inlined
//! - `cache`s with the same input become the same cache
//! - functions that don't use an axis get sliced on it, so they're only sampled once along it
//!
//! None of it changes what a function is worth on its own, but it decides what's cached and
//! sampled together, and vanilla's two sampling paths don't always round the same.
const Compiler = @This();
const std = @import("std");
const data = @import("data.zig");
const density = @import("density.zig");
const java = @import("java.zig");
const noise = @import("noise.zig");
const random = @import("random.zig");
const Interval = @import("Interval.zig");

const Allocator = std.mem.Allocator;
const Sampler = density.Sampler;

pub const Error = Allocator.Error || error{UnsupportedDensityFunction};

const Axes = u3;
const axis_x: Axes = 1;
const axis_y: Axes = 2;
const axis_z: Axes = 4;
const all_axes: Axes = 7;

fn axisBit(axis: data.Axis) Axes {
    return switch (axis) {
        .x => axis_x,
        .y => axis_y,
        .z => axis_z,
    };
}

/// A function being rewritten, references are gone and caches are prepared.
const Node = union(enum) {
    constant: f32,
    unary: struct { op: data.Unary, input: *Node },
    binary: struct { op: data.Binary, left: *Node, right: *Node },
    clamp: struct { input: *Node, min: f32, max: f32 },
    lerp: struct { alpha: *Node, first: *Node, second: *Node },
    range_choice: struct { input: *Node, min_inclusive: f32, max_exclusive: f32, when_in_range: *Node, when_out_of_range: *Node },
    interval_select: struct { input: *Node, thresholds: []const f32, functions: []*Node },
    /// Already compiled, the same one everywhere its input is cached.
    prepared_cache: struct { range: Interval, axes: Axes, sampler: *const Sampler },
    interpolated: struct { input: *Node, cell_size_xz: i32, cell_size_y: i32 },
    slice: struct { axis: data.Axis, coordinate: i32, input: *Node },
    find_top_surface: struct { density: *Node, upper_bound: *Node, lower_bound: i32, cell_height: i32 },
    blend_density: *Node,
    blend_alpha,
    blend_offset,
    beardifier,
    noise: struct { noise: data.NoiseId, xz_scale: f64, y_scale: f64, shift_x: *Node, shift_y: *Node, shift_z: *Node },
    shift_a: data.NoiseId,
    shift_b: data.NoiseId,
    shift: data.NoiseId,
    gradient: @FieldType(data.DensityFunction, "gradient"),
    spline: *SplineNode,
    old_blended_noise: @FieldType(data.DensityFunction, "old_blended_noise"),
};

const SplineNode = union(enum) {
    constant: f32,
    multipoint: struct {
        coordinate: *Node,
        /// The coordinate before it got rewritten, equal ones are the same coordinate.
        coordinate_id: data.FunctionId,
        locations: []const f32,
        values: []*SplineNode,
        derivatives: []const f32,
    },
};

arena: Allocator,
/// The world's random, noises are made from it (`RandomState.random`).
positional: random.Positional,
/// By `data.NoiseId`, made when first used.
noises: []?noise.Noise,
samplers: std.AutoHashMapUnmanaged(data.FunctionId, *const Sampler) = .empty,
/// By the input of the `cache` function.
caches: std.AutoHashMapUnmanaged(data.FunctionId, *Node) = .empty,
next_cache_id: u32 = 0,

pub fn init(arena: Allocator, positional: random.Positional) Allocator.Error!Compiler {
    const noises = try arena.alloc(?noise.Noise, data.noises.len);
    @memset(noises, null);
    return .{ .arena = arena, .positional = positional, .noises = noises };
}

/// `RandomState.getOrCreateNoise`
pub fn getNoise(self: *Compiler, id: data.NoiseId) Allocator.Error!*const noise.Noise {
    if (self.noises[id] == null) {
        const named = data.noises[id];
        self.noises[id] = try noise.instantiate(self.arena, self.positional, named.id, named.parameters);
    }
    return &self.noises[id].?;
}

pub fn getSampler(self: *Compiler, function: data.FunctionId) Error!*const Sampler {
    if (self.samplers.get(function)) |sampler| return sampler;
    const sampler = try self.compile(try self.optimize(function));
    try self.samplers.put(self.arena, function, sampler);
    return sampler;
}

fn optimize(self: *Compiler, function: data.FunctionId) Error!*Node {
    return self.sliceUniformAxes(try self.rewrite(function), all_axes);
}

fn create(self: *Compiler, node: Node) Allocator.Error!*Node {
    const ptr = try self.arena.create(Node);
    ptr.* = node;
    return ptr;
}

/// Inlines references and prepares caches.
fn rewrite(self: *Compiler, id: data.FunctionId) Error!*Node {
    var function = data.functions[id];
    if (function == .reference) function = data.functions[data.named_functions[function.reference].function];

    return self.create(switch (function) {
        .cache => |input| return self.prepareCache(input),
        // A reference to a file that's only a reference
        .reference => |named| return self.rewrite(data.named_functions[named].function),
        .unsupported => return error.UnsupportedDensityFunction,
        .constant => |value| .{ .constant = value },
        .unary => |f| .{ .unary = .{ .op = f.op, .input = try self.rewrite(f.input) } },
        .binary => |f| .{ .binary = .{ .op = f.op, .left = try self.rewrite(f.left), .right = try self.rewrite(f.right) } },
        .clamp => |f| .{ .clamp = .{ .input = try self.rewrite(f.input), .min = f.min, .max = f.max } },
        .lerp => |f| .{ .lerp = .{
            .alpha = try self.rewrite(f.alpha),
            .first = try self.rewrite(f.first),
            .second = try self.rewrite(f.second),
        } },
        .range_choice => |f| .{ .range_choice = .{
            .input = try self.rewrite(f.input),
            .min_inclusive = f.min_inclusive,
            .max_exclusive = f.max_exclusive,
            .when_in_range = try self.rewrite(f.when_in_range),
            .when_out_of_range = try self.rewrite(f.when_out_of_range),
        } },
        .interval_select => |f| blk: {
            const input = try self.rewrite(f.input);
            const functions = try self.arena.alloc(*Node, f.functions.len);
            for (functions, f.functions) |*out, in| out.* = try self.rewrite(in);
            break :blk .{ .interval_select = .{ .input = input, .thresholds = f.thresholds, .functions = functions } };
        },
        .interpolated => |f| .{ .interpolated = .{
            .input = try self.rewrite(f.input),
            .cell_size_xz = f.cell_size_xz,
            .cell_size_y = f.cell_size_y,
        } },
        .slice => |f| .{ .slice = .{ .axis = f.axis, .coordinate = f.coordinate, .input = try self.rewrite(f.input) } },
        .find_top_surface => |f| .{ .find_top_surface = .{
            .density = try self.rewrite(f.density),
            .upper_bound = try self.rewrite(f.upper_bound),
            .lower_bound = f.lower_bound,
            .cell_height = f.cell_height,
        } },
        .blend_density => |input| .{ .blend_density = try self.rewrite(input) },
        .blend_alpha => .blend_alpha,
        .blend_offset => .blend_offset,
        .beardifier => .beardifier,
        .noise => |f| .{ .noise = .{
            .noise = f.noise,
            .xz_scale = f.xz_scale,
            .y_scale = f.y_scale,
            .shift_x = try self.rewrite(f.shift_x),
            .shift_y = try self.rewrite(f.shift_y),
            .shift_z = try self.rewrite(f.shift_z),
        } },
        .shift_a => |n| .{ .shift_a = n },
        .shift_b => |n| .{ .shift_b = n },
        .shift => |n| .{ .shift = n },
        .gradient => |f| .{ .gradient = f },
        .spline => |spline| .{ .spline = try self.rewriteSpline(spline) },
        .old_blended_noise => |f| .{ .old_blended_noise = f },
    });
}

fn rewriteSpline(self: *Compiler, id: data.SplineId) Error!*SplineNode {
    const out = try self.arena.create(SplineNode);
    switch (data.splines[id]) {
        .constant => |value| out.* = .{ .constant = value },
        .multipoint => |s| {
            const coordinate = try self.rewrite(s.coordinate);
            const values = try self.arena.alloc(*SplineNode, s.values.len);
            for (values, s.values) |*v, value_id| v.* = try self.rewriteSpline(value_id);
            out.* = .{ .multipoint = .{
                .coordinate = coordinate,
                .coordinate_id = s.coordinate,
                .locations = s.locations,
                .values = values,
                .derivatives = s.derivatives,
            } };
        },
    }
    return out;
}

fn prepareCache(self: *Compiler, input_id: data.FunctionId) Error!*Node {
    if (self.caches.get(input_id)) |prepared| return prepared;

    const id = self.next_cache_id;
    self.next_cache_id += 1;
    const input = try self.optimize(input_id);
    const sampler = try self.arena.create(Sampler);
    sampler.* = .{ .caching = .{ .id = id, .input = try self.compile(input) } };

    const prepared = try self.create(.{ .prepared_cache = .{ .range = try self.range(input), .axes = domainAxes(input), .sampler = sampler } });
    try self.caches.put(self.arena, input_id, prepared);
    return prepared;
}

/// The axes a function's value depends on.
fn domainAxes(node: *const Node) Axes {
    return switch (node.*) {
        .constant => 0,
        .unary => |f| domainAxes(f.input),
        .binary => |f| domainAxes(f.left) | domainAxes(f.right),
        .clamp => |f| domainAxes(f.input),
        .lerp => |f| domainAxes(f.alpha) | domainAxes(f.first) | domainAxes(f.second),
        .range_choice => |f| domainAxes(f.input) | domainAxes(f.when_in_range) | domainAxes(f.when_out_of_range),
        .interval_select => |f| blk: {
            var axes = domainAxes(f.input);
            for (f.functions) |function| axes |= domainAxes(function);
            break :blk axes;
        },
        .prepared_cache => |f| f.axes,
        .interpolated => |f| domainAxes(f.input),
        .slice => |f| domainAxes(f.input) & ~axisBit(f.axis),
        .find_top_surface => |f| (domainAxes(f.density) | domainAxes(f.upper_bound)) & ~axis_y,
        .blend_density => |input| domainAxes(input),
        .blend_alpha, .blend_offset => axis_x | axis_z,
        .beardifier => all_axes,
        .noise => |f| blk: {
            var axes = all_axes;
            if (f.y_scale == 0.0) axes &= ~axis_y;
            if (f.xz_scale == 0.0) axes &= ~(axis_x | axis_z);
            break :blk axes | domainAxes(f.shift_x) | domainAxes(f.shift_y) | domainAxes(f.shift_z);
        },
        .shift_a, .shift_b => axis_x | axis_z,
        .shift => all_axes,
        .gradient => |f| axisBit(f.axis),
        .spline => |spline| splineAxes(spline),
        .old_blended_noise => all_axes,
    };
}

fn splineAxes(spline: *const SplineNode) Axes {
    switch (spline.*) {
        .constant => return 0,
        .multipoint => |s| {
            var axes = domainAxes(s.coordinate);
            for (s.values) |value| axes |= splineAxes(value);
            return axes;
        },
    }
}

/// Slices functions on the axes their parent has but they don't use (`SliceUniformAxes`).
fn sliceUniformAxes(self: *Compiler, node: *Node, parent_axes: Axes) Error!*Node {
    if (node.* == .constant or node.* == .gradient) return node;

    const axes = domainAxes(node);
    switch (node.*) {
        .constant, .gradient, .prepared_cache, .blend_alpha, .blend_offset, .beardifier, .shift_a, .shift_b, .shift, .old_blended_noise => {},
        .unary => |*f| f.input = try self.sliceUniformAxes(f.input, axes),
        .binary => |*f| {
            f.left = try self.sliceUniformAxes(f.left, axes);
            f.right = try self.sliceUniformAxes(f.right, axes);
        },
        .clamp => |*f| f.input = try self.sliceUniformAxes(f.input, axes),
        .lerp => |*f| {
            f.alpha = try self.sliceUniformAxes(f.alpha, axes);
            f.first = try self.sliceUniformAxes(f.first, axes);
            f.second = try self.sliceUniformAxes(f.second, axes);
        },
        .range_choice => |*f| {
            f.input = try self.sliceUniformAxes(f.input, axes);
            f.when_in_range = try self.sliceUniformAxes(f.when_in_range, axes);
            f.when_out_of_range = try self.sliceUniformAxes(f.when_out_of_range, axes);
        },
        .interval_select => |*f| {
            f.input = try self.sliceUniformAxes(f.input, axes);
            for (f.functions) |*function| function.* = try self.sliceUniformAxes(function.*, axes);
        },
        .interpolated => |*f| f.input = try self.sliceUniformAxes(f.input, axes),
        .slice => |*f| f.input = try self.sliceUniformAxes(f.input, axes),
        .find_top_surface => |*f| {
            f.density = try self.sliceUniformAxes(f.density, axes);
            f.upper_bound = try self.sliceUniformAxes(f.upper_bound, axes);
        },
        .blend_density => |*input| input.* = try self.sliceUniformAxes(input.*, axes),
        .noise => |*f| {
            f.shift_x = try self.sliceUniformAxes(f.shift_x, axes);
            f.shift_y = try self.sliceUniformAxes(f.shift_y, axes);
            f.shift_z = try self.sliceUniformAxes(f.shift_z, axes);
        },
        .spline => |spline| try self.sliceSpline(spline, axes),
    }
    if (parent_axes == axes) return node;

    // Not the ones it's already sliced on
    var existing: Axes = 0;
    var inner: *const Node = node;
    while (inner.* == .slice) : (inner = inner.slice.input) existing |= axisBit(inner.slice.axis);
    const removed = parent_axes & ~axes & ~existing;

    var out = node;
    if (removed & axis_x != 0) out = try self.create(.{ .slice = .{ .axis = .x, .coordinate = 0, .input = out } });
    if (removed & axis_z != 0) out = try self.create(.{ .slice = .{ .axis = .z, .coordinate = 0, .input = out } });
    if (removed & axis_y != 0) out = try self.create(.{ .slice = .{ .axis = .y, .coordinate = 0, .input = out } });
    return out;
}

fn sliceSpline(self: *Compiler, spline: *SplineNode, axes: Axes) Error!void {
    switch (spline.*) {
        .constant => {},
        .multipoint => |*s| {
            s.coordinate = try self.sliceUniformAxes(s.coordinate, axes);
            for (s.values) |value| try self.sliceSpline(value, axes);
        },
    }
}

fn noiseRange(id: data.NoiseId) Interval {
    return .symmetric(data.noises[id].parameters.maxValue());
}

fn cube(_: void, input: f32) f32 {
    return input * input * input;
}

fn squeeze(_: void, input: f32) f32 {
    return Sampler.squeezeValue(input);
}

/// `DensityFunction.range`
fn range(self: *Compiler, node: *const Node) Error!Interval {
    return switch (node.*) {
        .constant => |value| .exact(value),
        .unary => |f| blk: {
            const input = try self.range(f.input);
            break :blk switch (f.op) {
                .abs => Interval.abs(input),
                .square => Interval.square(input),
                .reciprocal => Interval.reciprocal(input),
                .negate => Interval.sub(.exact(0.0), input),
                .cube => Interval.mapMonotonic(input, {}, cube),
                .half_negative => Interval.mapMonotonic(input, @as(f32, 0.5), Sampler.leakyRelu),
                .quarter_negative => Interval.mapMonotonic(input, @as(f32, 0.25), Sampler.leakyRelu),
                .squeeze => Interval.mapMonotonic(input, {}, squeeze),
                .sign => Interval.sign(input),
                .sqrt, .log => return error.UnsupportedDensityFunction,
            };
        },
        .binary => |f| blk: {
            const left = try self.range(f.left);
            const right = try self.range(f.right);
            break :blk switch (f.op) {
                .add => Interval.add(left, right),
                .sub => Interval.sub(left, right),
                .mul => Interval.mul(left, right),
                .div => Interval.div(left, right),
                .min => Interval.minOf(left, right),
                .max => Interval.maxOf(left, right),
            };
        },
        .clamp => |f| Interval.clamp(try self.range(f.input), f.min, f.max),
        .lerp => |f| Interval.lerp(try self.range(f.alpha), try self.range(f.first), try self.range(f.second)),
        .range_choice => |f| Interval.encapsulating(&.{ try self.range(f.when_in_range), try self.range(f.when_out_of_range) }),
        .interval_select => |f| blk: {
            const ranges = try self.arena.alloc(Interval, f.functions.len);
            for (ranges, f.functions) |*r, function| r.* = try self.range(function);
            break :blk Interval.encapsulating(ranges);
        },
        .prepared_cache => |f| f.range,
        .interpolated => |f| try self.range(f.input),
        .slice => |f| try self.range(f.input),
        .find_top_surface => |f| blk: {
            const lower: f32 = @floatFromInt(f.lower_bound);
            break :blk .of(lower, java.javaMax(f32, lower, (try self.range(f.upper_bound)).max));
        },
        .blend_density => |input| try self.range(input),
        .blend_alpha => .of(0.0, 1.0),
        .blend_offset, .beardifier => .infinite,
        .noise => |f| noiseRange(f.noise),
        .shift_a, .shift_b, .shift => |n| Interval.mul(noiseRange(n), .exact(4.0)),
        .gradient => |f| Interval.encapsulatingValues(f.from_value, f.to_value),
        .spline => |spline| try self.splineRange(spline),
        .old_blended_noise => |f| blendedRange(-15, 684.412 * f.y_scale * f.smear_scale_multiplier, 0.9999847412109375),
    };
}

/// `CubicSpline.Multipoint.range`
fn splineRange(self: *Compiler, spline: *const SplineNode) Error!Interval {
    const s = switch (spline.*) {
        .constant => |value| return .exact(value),
        .multipoint => |s| s,
    };
    const fmin = java.javaMin;
    const fmax = java.javaMax;
    const linearExtend = density.Spline.linearExtend;
    const last = s.locations.len - 1;
    var min = std.math.inf(f32);
    var max = -std.math.inf(f32);

    const input = try self.range(s.coordinate);
    if (input.isNai()) return input;

    const ranges = try self.arena.alloc(Interval, s.values.len);
    for (ranges, s.values) |*r, value| r.* = try self.splineRange(value);

    if (input.min < s.locations[0]) {
        const edge1 = linearExtend(input.min, s.locations[0], ranges[0].min, s.derivatives[0]);
        const edge2 = linearExtend(input.min, s.locations[0], ranges[0].max, s.derivatives[0]);
        min = fmin(f32, min, fmin(f32, edge1, edge2));
        max = fmax(f32, max, fmax(f32, edge1, edge2));
    }
    if (input.max > s.locations[last]) {
        const edge1 = linearExtend(input.max, s.locations[last], ranges[last].min, s.derivatives[last]);
        const edge2 = linearExtend(input.max, s.locations[last], ranges[last].max, s.derivatives[last]);
        min = fmin(f32, min, fmin(f32, edge1, edge2));
        max = fmax(f32, max, fmax(f32, edge1, edge2));
    }
    for (ranges) |r| {
        min = fmin(f32, min, r.min);
        max = fmax(f32, max, r.max);
    }
    for (0..last) |i| {
        const x_diff = s.locations[i + 1] - s.locations[i];
        const min1 = ranges[i].min;
        const max1 = ranges[i].max;
        const min2 = ranges[i + 1].min;
        const max2 = ranges[i + 1].max;
        const d1 = s.derivatives[i];
        const d2 = s.derivatives[i + 1];
        if (d1 == 0.0 and d2 == 0.0) continue;
        const p1 = d1 * x_diff;
        const p2 = d2 * x_diff;
        const min_lerp1 = fmin(f32, min1, min2);
        const max_lerp1 = fmax(f32, max1, max2);
        const min_a = p1 - max2 + min1;
        const max_a = p1 - min2 + max1;
        const min_b = -p2 + min2 - max1;
        const max_b = -p2 + max2 - min1;
        const min_lerp2 = fmin(f32, min_a, min_b);
        const max_lerp2 = fmax(f32, max_a, max_b);
        min = fmin(f32, min, min_lerp1 + 0.25 * min_lerp2);
        max = fmax(f32, max, max_lerp1 + 0.25 * max_lerp2);
    }
    return .of(min, max);
}

/// `BlendedNoise.computeFbmRange`
fn blendedRange(first_octave: i32, smear_scale_y: f64, in_value_factor: f64) Interval {
    const octaves = -first_octave + 1;
    var factor: f64 = 1.0;
    var value_factor = in_value_factor / (std.math.ldexp(@as(f64, 1.0), octaves) - 1.0);
    var out: Interval = .exact(0.0);
    for (0..@intCast(octaves)) |_| {
        const layer: Interval = .symmetric(@floatCast(@abs(smear_scale_y * factor) + 2.0));
        out = Interval.add(out, Interval.mul(layer, .exact(@floatCast(value_factor))));
        factor /= 2.0;
        value_factor *= 2.0;
    }
    return out;
}

/// `BlendedNoise.createFbm`, the octaves of the old terrain noise.
fn blendedFbm(self: *Compiler, rand: *random.Xoroshiro, first_octave: i32, smear_scale_y: f64, in_value_factor: f64) Allocator.Error!*const noise.Noise {
    const octaves: usize = @intCast(-first_octave + 1);
    var factor: f64 = 1.0;
    var value_factor = in_value_factor / (std.math.ldexp(@as(f64, 1.0), @as(i32, @intCast(octaves))) - 1.0);
    const layers = try self.arena.alloc(noise.Noise.Layer, octaves);
    for (layers) |*layer| {
        var perlin: noise.Perlin = .init(rand);
        perlin.smear = smear_scale_y * factor;
        layer.* = .{ .noise = perlin, .frequency = factor, .amplitude = @floatCast(value_factor) };
        factor /= 2.0;
        value_factor *= 2.0;
    }
    const out = try self.arena.create(noise.Noise);
    out.* = .{ .layers = layers };
    return out;
}

fn newSampler(self: *Compiler, value: Sampler) Allocator.Error!*const Sampler {
    const ptr = try self.arena.create(Sampler);
    ptr.* = value;
    return ptr;
}

fn isZero(node: *const Node) bool {
    return node.* == .constant and @as(u32, @bitCast(node.constant)) == 0;
}

/// `DensityFunction.compileSampler`
fn compile(self: *Compiler, node: *const Node) Error!*const Sampler {
    return self.newSampler(switch (node.*) {
        .constant => |value| .{ .constant = value },
        .unary => |f| blk: {
            const input = try self.compile(f.input);
            break :blk switch (f.op) {
                .abs => .{ .abs = input },
                .square => .{ .square = input },
                .cube => .{ .cube = input },
                .half_negative => .{ .leaky_relu = .{ .input = input, .factor = 0.5 } },
                .quarter_negative => .{ .leaky_relu = .{ .input = input, .factor = 0.25 } },
                .reciprocal => .{ .reciprocal = input },
                .negate => .{ .negate = input },
                .squeeze => .{ .squeeze = input },
                .sign => .{ .sign = input },
                .sqrt, .log => return error.UnsupportedDensityFunction,
            };
        },
        .binary => |f| blk: {
            const left = try self.compile(f.left);
            const right = try self.compile(f.right);
            const left_const: ?f32 = if (f.left.* == .constant) f.left.constant else null;
            const right_const: ?f32 = if (f.right.* == .constant) f.right.constant else null;
            switch (f.op) {
                .add => {
                    if (left_const) |c| break :blk .{ .const_add = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_add = .{ .input = left, .value = c } };
                    break :blk .{ .add = .{ .left = left, .right = right } };
                },
                .sub => {
                    if (left_const) |c| break :blk .{ .const_sub = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_add = .{ .input = left, .value = -c } };
                    break :blk .{ .sub = .{ .left = left, .right = right } };
                },
                .mul => {
                    if (left_const) |c| break :blk .{ .const_mul = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_mul = .{ .input = left, .value = c } };
                    break :blk .{ .mul = .{ .left = left, .right = right } };
                },
                .div => {
                    if (left_const) |c| break :blk .{ .const_div = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_mul = .{ .input = left, .value = 1.0 / c } };
                    break :blk .{ .div = .{ .left = left, .right = right } };
                },
                .min => {
                    const left_range = try self.range(f.left);
                    const right_range = try self.range(f.right);
                    // One side is always the smallest
                    if (left_range.max < right_range.min) return left;
                    if (right_range.max < left_range.min) return right;
                    if (left_const) |c| break :blk .{ .const_min = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_min = .{ .input = left, .value = c } };
                    break :blk .{ .min = .{ .left = left, .right = right, .bound = right_range.min } };
                },
                .max => {
                    const left_range = try self.range(f.left);
                    const right_range = try self.range(f.right);
                    if (left_range.min > right_range.max) return left;
                    if (right_range.min > left_range.max) return right;
                    if (left_const) |c| break :blk .{ .const_max = .{ .input = right, .value = c } };
                    if (right_const) |c| break :blk .{ .const_max = .{ .input = left, .value = c } };
                    break :blk .{ .max = .{ .left = left, .right = right, .bound = right_range.max } };
                },
            }
        },
        .clamp => |f| .{ .clamp = .{ .input = try self.compile(f.input), .min = f.min, .max = f.max } },
        .lerp => |f| blk: {
            const alpha = try self.compile(f.alpha);
            const first = try self.compile(f.first);
            const second = try self.compile(f.second);
            if (f.first.* == .constant) break :blk .{ .lerp_const_first = .{ .alpha = alpha, .first = f.first.constant, .second = second } };
            if (f.second.* == .constant) break :blk .{ .lerp_const_second = .{ .alpha = alpha, .first = first, .second = f.second.constant } };
            break :blk .{ .lerp = .{ .alpha = alpha, .first = first, .second = second } };
        },
        .range_choice => |f| blk: {
            const input = try self.compile(f.input);
            if (f.when_in_range.* == .constant and f.when_out_of_range.* == .constant) break :blk .{ .range_choice_const = .{
                .input = input,
                .min_inclusive = f.min_inclusive,
                .max_exclusive = f.max_exclusive,
                .when_in_range = f.when_in_range.constant,
                .when_out_of_range = f.when_out_of_range.constant,
            } };
            break :blk .{ .range_choice = .{
                .input = input,
                .min_inclusive = f.min_inclusive,
                .max_exclusive = f.max_exclusive,
                .when_in_range = try self.compile(f.when_in_range),
                .when_out_of_range = try self.compile(f.when_out_of_range),
            } };
        },
        .interval_select => |f| blk: {
            const input = try self.compile(f.input);
            if (f.thresholds.len == 1) break :blk .{ .threshold = .{
                .input = input,
                .threshold = f.thresholds[0],
                .if_below = try self.compile(f.functions[0]),
                .if_above = try self.compile(f.functions[f.functions.len - 1]),
            } };
            const samplers = try self.arena.alloc(*const Sampler, f.functions.len);
            for (samplers, f.functions) |*s, function| s.* = try self.compile(function);
            break :blk .{ .interval_select = .{ .input = input, .thresholds = f.thresholds, .samplers = samplers } };
        },
        .prepared_cache => |f| return f.sampler,
        .interpolated => |f| .{ .interpolated = .{
            .input = try self.compile(f.input),
            .cell_size_xz = f.cell_size_xz,
            .cell_size_y = f.cell_size_y,
            .cell_size_xz_inv = 1.0 / @as(f32, @floatFromInt(f.cell_size_xz)),
            .cell_size_y_inv = 1.0 / @as(f32, @floatFromInt(f.cell_size_y)),
        } },
        .slice => |f| blk: {
            // x and z together are a column
            if (f.input.* == .slice) {
                const inner = f.input.slice;
                if ((f.axis == .x and inner.axis == .z) or (f.axis == .z and inner.axis == .x)) break :blk .{ .slice_xz = .{
                    .input = try self.compile(inner.input),
                    .x = if (f.axis == .x) f.coordinate else inner.coordinate,
                    .z = if (f.axis == .x) inner.coordinate else f.coordinate,
                } };
            }
            const slice: Sampler.Slice = .{ .input = try self.compile(f.input), .coordinate = f.coordinate };
            break :blk switch (f.axis) {
                .x => .{ .slice_x = slice },
                .y => .{ .slice_y = slice },
                .z => .{ .slice_z = slice },
            };
        },
        .find_top_surface => |f| .{ .slice_y = .{
            .input = try self.newSampler(.{ .find_top_surface = .{
                .density = try self.compile(f.density),
                .upper_bound = try self.compile(f.upper_bound),
                .lower_bound = f.lower_bound,
                .cell_height = f.cell_height,
            } }),
            .coordinate = 0,
        } },
        // No blending with old chunks and no structures: these are what vanilla falls back to
        .blend_density => |input| return self.compile(input),
        .blend_alpha => .{ .constant = 1.0 },
        .blend_offset, .beardifier => .{ .constant = 0.0 },
        .noise => |f| blk: {
            const n: Sampler.Noise = .{ .noise = try self.getNoise(f.noise), .xz_scale = f.xz_scale, .y_scale = f.y_scale };
            if (isZero(f.shift_x) and isZero(f.shift_y) and isZero(f.shift_z)) break :blk .{ .noise = n };
            const shift_x = try self.compile(f.shift_x);
            const shift_z = try self.compile(f.shift_z);
            if (isZero(f.shift_y)) break :blk .{ .shifted_xz = .{ .shift_x = shift_x, .shift_z = shift_z, .noise = n } };
            break :blk .{ .shifted_xyz = .{ .shift_x = shift_x, .shift_y = try self.compile(f.shift_y), .shift_z = shift_z, .noise = n } };
        },
        .shift_a => |n| .{ .const_mul = .{
            .input = try self.newSampler(.{ .noise = .{ .noise = try self.getNoise(n), .xz_scale = 0.25, .y_scale = 0.0 } }),
            .value = 4.0,
        } },
        .shift => |n| .{ .const_mul = .{
            .input = try self.newSampler(.{ .noise = .{ .noise = try self.getNoise(n), .xz_scale = 0.25, .y_scale = 0.25 } }),
            .value = 4.0,
        } },
        .shift_b => |n| .{ .shift_b = try self.getNoise(n) },
        .gradient => |f| blk: {
            const coordinate_range = f.to_coordinate - f.from_coordinate;
            break :blk .{ .gradient = .{
                .axis = f.axis,
                .tiling = f.tiling,
                .from_coordinate = f.from_coordinate,
                .min_coordinate = @min(f.from_coordinate, f.to_coordinate),
                .max_coordinate = @max(f.from_coordinate, f.to_coordinate),
                .coordinate_range = coordinate_range,
                .from_value = f.from_value,
                .coordinate_factor = (f.to_value - f.from_value) / @as(f32, @floatFromInt(coordinate_range)),
            } };
        },
        .spline => |spline| blk: {
            var coordinates: std.ArrayList(data.FunctionId) = .empty;
            const root = try self.compileSpline(spline, &coordinates);
            break :blk .{ .spline = .{ .root = root, .coordinate_count = coordinates.items.len } };
        },
        .old_blended_noise => |f| blk: {
            var rand = self.positional.fromHashOf("minecraft:terrain");
            const xz_multiplier = 684.412 * f.xz_scale;
            const y_multiplier = 684.412 * f.y_scale;
            const limit_smear = y_multiplier * f.smear_scale_multiplier;
            const main_smear = limit_smear / f.y_factor;
            const min_limit = try self.blendedFbm(&rand, -15, limit_smear, 0.9999847412109375);
            const max_limit = try self.blendedFbm(&rand, -15, limit_smear, 0.9999847412109375);
            const main = try self.blendedFbm(&rand, -7, main_smear, 12.75);

            const main_sampler = try self.newSampler(.{ .noise = .{ .noise = main, .xz_scale = xz_multiplier / f.xz_factor, .y_scale = y_multiplier / f.y_factor } });
            const choice = try self.newSampler(.{ .clamp = .{
                .input = try self.newSampler(.{ .const_add = .{ .input = main_sampler, .value = 0.5 } }),
                .min = 0.0,
                .max = 1.0,
            } });
            break :blk .{ .lerp = .{
                .alpha = choice,
                .first = try self.newSampler(.{ .noise = .{ .noise = min_limit, .xz_scale = xz_multiplier, .y_scale = y_multiplier } }),
                .second = try self.newSampler(.{ .noise = .{ .noise = max_limit, .xz_scale = xz_multiplier, .y_scale = y_multiplier } }),
            } };
        },
    });
}

fn compileSpline(self: *Compiler, spline: *const SplineNode, coordinates: *std.ArrayList(data.FunctionId)) Error!density.Spline {
    const s = switch (spline.*) {
        .constant => |value| return .{ .constant = value },
        .multipoint => |s| s,
    };
    const index = std.mem.indexOfScalar(data.FunctionId, coordinates.items, s.coordinate_id) orelse blk: {
        try coordinates.append(self.arena, s.coordinate_id);
        break :blk coordinates.items.len - 1;
    };
    // Only the first of a coordinate is used, they're all the same sampler
    const coordinate = try self.compile(s.coordinate);
    const values = try self.arena.alloc(density.Spline, s.values.len);
    for (values, s.values) |*v, value| v.* = try self.compileSpline(value, coordinates);
    return .{ .multipoint = .{
        .coordinate = coordinate,
        .index = index,
        .locations = s.locations,
        .values = values,
        .derivatives = s.derivatives,
    } };
}
