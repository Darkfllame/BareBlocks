//! Compiled density functions (vanilla's `DensitySampler`s), `compiler.zig` makes them.
//!
//! Every sampler can be sampled a whole volume at once or one position at a time. The two don't
//! always round the same way (`interpolated`), and vanilla uses both, so do we.
const std = @import("std");
const math = @import("math");
const java = @import("java.zig");
const noise = @import("noise.zig");
const data = @import("data.zig");
const Volume = @import("Volume.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// What a sampling needs besides the sampler: buffers and the `cache` functions' cells.
/// One per chunk being generated, not thread safe.
pub const Context = struct {
    gpa: Allocator,
    /// `null` when caches are disabled.
    cells: ?std.ArrayList(Cell),

    const Cell = struct {
        /// The last volume sampled and its values.
        volume: Volume = undefined,
        buffer: ?[]f32 = null,
        /// The last position sampled alone, nothing while `value` is NaN.
        key: [3]i32 = .{ 0, 0, 0 },
        value: f32 = std.math.nan(f32),
    };

    pub fn init(gpa: Allocator, caches: bool) Context {
        return .{ .gpa = gpa, .cells = if (caches) .empty else null };
    }

    pub fn deinit(self: *Context) void {
        if (self.cells) |*cells| {
            for (cells.items) |c| {
                if (c.buffer) |b| self.gpa.free(b);
            }
            cells.deinit(self.gpa);
        }
        self.* = undefined;
    }

    pub fn acquire(self: *Context, volume: Volume) Error![]f32 {
        return self.gpa.alloc(f32, volume.size());
    }

    pub fn release(self: *Context, buffer: []f32) void {
        self.gpa.free(buffer);
    }

    /// Don't keep it across samplings, the list can grow.
    fn cell(self: *Context, id: u32) Error!?*Cell {
        const cells = if (self.cells) |*c| c else return null;
        if (id >= cells.items.len) {
            const old_len = cells.items.len;
            try cells.resize(self.gpa, id + 1);
            @memset(cells.items[old_len..], .{});
        }
        return &cells.items[id];
    }
};

pub const Gradient = struct {
    axis: data.Axis,
    tiling: data.Tiling,
    from_coordinate: i32,
    min_coordinate: i32,
    max_coordinate: i32,
    coordinate_range: i32,
    from_value: f32,
    coordinate_factor: f32,

    fn compute(self: Gradient, coordinate: i32) f32 {
        switch (self.tiling) {
            .clamp_to_edge => {
                const relative = @min(@max(coordinate, self.min_coordinate), self.max_coordinate) - self.from_coordinate;
                return self.from_value + @as(f32, @floatFromInt(relative)) * self.coordinate_factor;
            },
            .repeat => {
                const relative = coordinate -% self.from_coordinate;
                return self.from_value + @as(f32, @floatFromInt(@mod(relative, self.coordinate_range))) * self.coordinate_factor;
            },
            .mirrored_repeat => {
                const relative = coordinate -% self.from_coordinate;
                const tile = @divFloor(relative, self.coordinate_range);
                const local = relative - tile * self.coordinate_range;
                if (tile & 1 == 0) return self.from_value + @as(f32, @floatFromInt(local)) * self.coordinate_factor;
                return self.from_value + @as(f32, @floatFromInt(self.coordinate_range - local)) * self.coordinate_factor;
            },
        }
    }
};

pub const Spline = union(enum) {
    constant: f32,
    multipoint: struct {
        coordinate: *const Sampler,
        /// Which of the sampler's coordinates it is, the same function is only sampled once.
        index: usize,
        locations: []const f32,
        values: []const Spline,
        derivatives: []const f32,
    },

    /// `input.coordinate(sampler, index)` gives the value of a coordinate.
    fn sample(self: *const Spline, input: anytype) Error!f32 {
        const s = switch (self.*) {
            .constant => |value| return value,
            .multipoint => |*s| s,
        };
        const x = try input.coordinate(s.coordinate, s.index);

        // The first location above x, binary search like vanilla's
        var from: usize = 0;
        var len = s.locations.len;
        while (len > 0) {
            const half = len / 2;
            const middle = from + half;
            if (x < s.locations[middle]) {
                len = half;
            } else {
                from = middle + 1;
                len -= half + 1;
            }
        }
        const last = s.locations.len - 1;
        if (from == 0) return linearExtend(x, s.locations[0], try s.values[0].sample(input), s.derivatives[0]);
        const start = from - 1;
        if (start == last) return linearExtend(x, s.locations[last], try s.values[last].sample(input), s.derivatives[last]);

        const x1 = s.locations[start];
        const x2 = s.locations[start + 1];
        const t = (x - x1) / (x2 - x1);
        const d1 = s.derivatives[start];
        const d2 = s.derivatives[start + 1];
        const y1 = try s.values[start].sample(input);
        const y2 = try s.values[start + 1].sample(input);
        const a = d1 * (x2 - x1) - (y2 - y1);
        const b = -d2 * (x2 - x1) + (y2 - y1);
        return math.lm.lerp(f32, y1, y2, t) + t * (1.0 - t) * math.lm.lerp(f32, a, b, t);
    }

    pub fn linearExtend(input: f32, location: f32, value: f32, derivative: f32) f32 {
        if (derivative == 0.0) return value;
        return value + derivative * (input - location);
    }
};

pub const Sampler = union(enum) {
    constant: f32,

    abs: *const Sampler,
    square: *const Sampler,
    cube: *const Sampler,
    reciprocal: *const Sampler,
    negate: *const Sampler,
    squeeze: *const Sampler,
    sign: *const Sampler,
    /// `half_negative` and `quarter_negative`
    leaky_relu: struct { input: *const Sampler, factor: f32 },

    const_add: Const,
    const_sub: Const,
    const_mul: Const,
    const_div: Const,
    const_min: Const,
    const_max: Const,
    add: Pair,
    sub: Pair,
    mul: Pair,
    div: Pair,
    min: Bounded,
    max: Bounded,

    clamp: struct { input: *const Sampler, min: f32, max: f32 },
    lerp: struct { alpha: *const Sampler, first: *const Sampler, second: *const Sampler },
    lerp_const_first: struct { alpha: *const Sampler, first: f32, second: *const Sampler },
    lerp_const_second: struct { alpha: *const Sampler, first: *const Sampler, second: f32 },
    range_choice: struct {
        input: *const Sampler,
        min_inclusive: f32,
        max_exclusive: f32,
        when_in_range: *const Sampler,
        when_out_of_range: *const Sampler,
    },
    range_choice_const: struct {
        input: *const Sampler,
        min_inclusive: f32,
        max_exclusive: f32,
        when_in_range: f32,
        when_out_of_range: f32,
    },
    threshold: struct { input: *const Sampler, threshold: f32, if_below: *const Sampler, if_above: *const Sampler },
    interval_select: struct { input: *const Sampler, thresholds: []const f32, samplers: []const *const Sampler },

    caching: struct { id: u32, input: *const Sampler },
    interpolated: Interpolated,
    slice_x: Slice,
    slice_y: Slice,
    slice_z: Slice,
    slice_xz: struct { input: *const Sampler, x: i32, z: i32 },
    find_top_surface: FindTopSurface,

    noise: Noise,
    shifted_xz: struct { shift_x: *const Sampler, shift_z: *const Sampler, noise: Noise },
    shifted_xyz: struct { shift_x: *const Sampler, shift_y: *const Sampler, shift_z: *const Sampler, noise: Noise },
    shift_b: *const noise.Noise,
    gradient: Gradient,
    spline: struct { root: Spline, coordinate_count: usize },

    /// The constant is `left` for `const_sub` and `const_div`, `right` for the others.
    pub const Const = struct { input: *const Sampler, value: f32 };
    pub const Pair = struct { left: *const Sampler, right: *const Sampler };
    /// `bound` is the lowest (`min`) or highest (`max`) value `right` can have.
    pub const Bounded = struct { left: *const Sampler, right: *const Sampler, bound: f32 };
    pub const Slice = struct { input: *const Sampler, coordinate: i32 };
    pub const Noise = struct { noise: *const noise.Noise, xz_scale: f64, y_scale: f64 };

    pub const Interpolated = struct {
        input: *const Sampler,
        cell_size_xz: i32,
        cell_size_y: i32,
        cell_size_xz_inv: f32,
        cell_size_y_inv: f32,

        const sampleVolume = interpolatedVolume;
        const sampleValue = interpolatedValue;
    };

    pub const FindTopSurface = struct {
        density: *const Sampler,
        upper_bound: *const Sampler,
        lower_bound: i32,
        cell_height: i32,

        const findSurface = findSurfaceFrom;
    };

    pub fn squeezeValue(input: f32) f32 {
        const clamped = java.clamp(f32, input, -1.0, 1.0);
        return clamped / 2.0 - clamped * clamped * clamped / 24.0;
    }

    pub fn leakyRelu(factor: f32, input: f32) f32 {
        return if (input > 0.0) input else input * factor;
    }

    /// `Math.signum`
    fn signum(v: f32) f32 {
        if (v != v or v == 0.0) return v;
        return if (v > 0.0) 1.0 else -1.0;
    }

    /// Samples every position of `volume`, `out` is indexed like `Volume.index`.
    pub fn sampleVolume(self: *const Sampler, ctx: *Context, out: []f32, volume: Volume) Error!void {
        std.debug.assert(out.len == volume.size());
        switch (self.*) {
            .constant => |value| @memset(out, value),

            .abs => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = @abs(v.*);
            },
            .square => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = v.* * v.*;
            },
            .cube => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = v.* * v.* * v.*;
            },
            .reciprocal => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = 1.0 / v.*;
            },
            .negate => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = -v.*;
            },
            .squeeze => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = squeezeValue(v.*);
            },
            .sign => |input| {
                try input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = signum(v.*);
            },
            .leaky_relu => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = leakyRelu(s.factor, v.*);
            },

            .const_add => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* += s.value;
            },
            .const_sub => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = s.value - v.*;
            },
            .const_mul => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = v.* * s.value;
            },
            .const_div => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = s.value / v.*;
            },
            .const_min => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| {
                    if (s.value < v.*) v.* = s.value;
                }
            },
            .const_max => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| {
                    if (s.value > v.*) v.* = s.value;
                }
            },
            inline .add, .sub, .mul, .div => |s, tag| {
                try s.left.sampleVolume(ctx, out, volume);
                const right = try ctx.acquire(volume);
                defer ctx.release(right);
                try s.right.sampleVolume(ctx, right, volume);
                for (out, right) |*v, r| {
                    v.* = switch (tag) {
                        .add => v.* + r,
                        .sub => v.* + -r,
                        .mul => v.* * r,
                        .div => v.* / r,
                        else => comptime unreachable,
                    };
                }
            },
            inline .min, .max => |s, tag| {
                try s.left.sampleVolume(ctx, out, volume);
                const right = try ctx.acquire(volume);
                defer ctx.release(right);
                try s.right.sampleVolume(ctx, right, volume);
                for (out, right) |*v, r| {
                    if (if (tag == .min) r < v.* else r > v.*) v.* = r;
                }
            },

            .clamp => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = java.clamp(f32, v.*, s.min, s.max);
            },
            .lerp => |s| {
                try s.alpha.sampleVolume(ctx, out, volume);
                const first = try ctx.acquire(volume);
                defer ctx.release(first);
                try s.first.sampleVolume(ctx, first, volume);
                const second = try ctx.acquire(volume);
                defer ctx.release(second);
                try s.second.sampleVolume(ctx, second, volume);
                for (out, first, second) |*v, f, sec| v.* = lerpOrEnd(v.*, f, sec);
            },
            .lerp_const_first => |s| {
                try s.alpha.sampleVolume(ctx, out, volume);
                const second = try ctx.acquire(volume);
                defer ctx.release(second);
                try s.second.sampleVolume(ctx, second, volume);
                for (out, second) |*v, sec| v.* = lerpOrEnd(v.*, s.first, sec);
            },
            .lerp_const_second => |s| {
                try s.alpha.sampleVolume(ctx, out, volume);
                const first = try ctx.acquire(volume);
                defer ctx.release(first);
                try s.first.sampleVolume(ctx, first, volume);
                for (out, first) |*v, f| v.* = lerpOrEnd(v.*, f, s.second);
            },
            .range_choice => |s| {
                try s.when_in_range.sampleVolume(ctx, out, volume);
                const input = try ctx.acquire(volume);
                defer ctx.release(input);
                try s.input.sampleVolume(ctx, input, volume);
                const out_of_range = try ctx.acquire(volume);
                defer ctx.release(out_of_range);
                try s.when_out_of_range.sampleVolume(ctx, out_of_range, volume);
                for (out, input, out_of_range) |*v, in, o| {
                    if (in >= s.min_inclusive and in < s.max_exclusive) continue;
                    v.* = o;
                }
            },
            .range_choice_const => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                for (out) |*v| v.* = if (v.* >= s.min_inclusive and v.* < s.max_exclusive) s.when_in_range else s.when_out_of_range;
            },
            .threshold => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                const below = try ctx.acquire(volume);
                defer ctx.release(below);
                try s.if_below.sampleVolume(ctx, below, volume);
                const above = try ctx.acquire(volume);
                defer ctx.release(above);
                try s.if_above.sampleVolume(ctx, above, volume);
                for (out, below, above) |*v, b, a| v.* = if (v.* < s.threshold) b else a;
            },
            .interval_select => |s| {
                try s.input.sampleVolume(ctx, out, volume);
                const buffers = try ctx.gpa.alloc([]f32, s.samplers.len);
                defer ctx.gpa.free(buffers);
                var acquired: usize = 0;
                defer for (buffers[0..acquired]) |b| ctx.release(b);
                for (s.samplers, buffers) |sampler, *buffer| {
                    buffer.* = try ctx.acquire(volume);
                    acquired += 1;
                    try sampler.sampleVolume(ctx, buffer.*, volume);
                }
                for (out, 0..) |*v, i| v.* = buffers[selectInterval(s.thresholds, s.samplers.len, v.*)][i];
            },

            .caching => |s| {
                var cell = try ctx.cell(s.id) orelse return s.input.sampleVolume(ctx, out, volume);
                if (cell.buffer == null or !volume.eql(cell.volume)) {
                    if (cell.buffer) |old| ctx.release(old);
                    cell.buffer = null;
                    const buffer = try ctx.acquire(volume);
                    cell.volume = volume;
                    cell.buffer = buffer;
                    try s.input.sampleVolume(ctx, buffer, volume);
                    cell = (try ctx.cell(s.id)).?;
                }
                @memcpy(out, cell.buffer.?);
            },
            .interpolated => |*s| try s.sampleVolume(ctx, out, volume),
            .slice_x => |s| {
                if (volume.size_x == 1 and volume.min_x == s.coordinate) return s.input.sampleVolume(ctx, out, volume);
                var input_volume = volume;
                input_volume.size_x = 1;
                input_volume.min_x = s.coordinate;
                const input = try ctx.acquire(input_volume);
                defer ctx.release(input);
                try s.input.sampleVolume(ctx, input, input_volume);
                var index: usize = 0;
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        var y: i32 = 0;
                        while (y < volume.size_y) : (y += 1) {
                            out[index] = input[input_volume.index(0, y, z)];
                            index += 1;
                        }
                    }
                }
            },
            .slice_y => |s| {
                if (volume.size_y == 1 and volume.min_y == s.coordinate) return s.input.sampleVolume(ctx, out, volume);
                var input_volume = volume;
                input_volume.size_y = 1;
                input_volume.min_y = s.coordinate;
                const input = try ctx.acquire(input_volume);
                defer ctx.release(input);
                try s.input.sampleVolume(ctx, input, input_volume);
                const size_y: usize = @intCast(volume.size_y);
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        @memset(out[volume.index(x, 0, z)..][0..size_y], input[input_volume.index(x, 0, z)]);
                    }
                }
            },
            .slice_z => |s| {
                if (volume.size_z == 1 and volume.min_z == s.coordinate) return s.input.sampleVolume(ctx, out, volume);
                var input_volume = volume;
                input_volume.size_z = 1;
                input_volume.min_z = s.coordinate;
                const input = try ctx.acquire(input_volume);
                defer ctx.release(input);
                try s.input.sampleVolume(ctx, input, input_volume);
                var index: usize = 0;
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        var y: i32 = 0;
                        while (y < volume.size_y) : (y += 1) {
                            out[index] = input[input_volume.index(x, y, 0)];
                            index += 1;
                        }
                    }
                }
            },
            .slice_xz => |s| {
                if (volume.size_x == 1 and volume.size_z == 1 and volume.min_x == s.x and volume.min_z == s.z) {
                    return s.input.sampleVolume(ctx, out, volume);
                }
                var input_volume = volume;
                input_volume.size_x = 1;
                input_volume.size_z = 1;
                input_volume.min_x = s.x;
                input_volume.min_z = s.z;
                const input = try ctx.acquire(input_volume);
                defer ctx.release(input);
                try s.input.sampleVolume(ctx, input, input_volume);
                const size_y: usize = @intCast(volume.size_y);
                var y: usize = 0;
                while (y < size_y) : (y += 1) {
                    var index = y;
                    while (index < out.len) : (index += size_y) out[index] = input[y];
                }
            },
            .find_top_surface => |*s| {
                // Always inside of a y slice
                std.debug.assert(volume.size_y == 1);
                try s.upper_bound.sampleVolume(ctx, out, volume);
                var index: usize = 0;
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        out[index] = @floatFromInt(try s.findSurface(ctx, volume.blockX(x), volume.blockZ(z), out[index]));
                        index += 1;
                    }
                }
            },

            .noise => |s| {
                @memset(out, 0.0);
                s.noise.addToVolume(out, volume, s.xz_scale, s.y_scale, 1.0);
            },
            .shifted_xz => |s| {
                try s.shift_x.sampleVolume(ctx, out, volume);
                const shift_z = try ctx.acquire(volume);
                defer ctx.release(shift_z);
                try s.shift_z.sampleVolume(ctx, shift_z, volume);
                var index: usize = 0;
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    const base_z = @as(f64, @floatFromInt(volume.blockZ(z))) * s.noise.xz_scale;
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        const base_x = @as(f64, @floatFromInt(volume.blockX(x))) * s.noise.xz_scale;
                        var y: i32 = 0;
                        while (y < volume.size_y) : (y += 1) {
                            const noise_x = base_x + @as(f64, out[index]);
                            const noise_y = @as(f64, @floatFromInt(volume.blockY(y))) * s.noise.y_scale;
                            const noise_z = base_z + @as(f64, shift_z[index]);
                            out[index] = s.noise.noise.get(noise_x, noise_y, noise_z);
                            index += 1;
                        }
                    }
                }
            },
            .shifted_xyz => |s| {
                try s.shift_x.sampleVolume(ctx, out, volume);
                const shift_y = try ctx.acquire(volume);
                defer ctx.release(shift_y);
                try s.shift_y.sampleVolume(ctx, shift_y, volume);
                const shift_z = try ctx.acquire(volume);
                defer ctx.release(shift_z);
                try s.shift_z.sampleVolume(ctx, shift_z, volume);
                var index: usize = 0;
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    const base_z = @as(f64, @floatFromInt(volume.blockZ(z))) * s.noise.xz_scale;
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        const base_x = @as(f64, @floatFromInt(volume.blockX(x))) * s.noise.xz_scale;
                        var y: i32 = 0;
                        while (y < volume.size_y) : (y += 1) {
                            const noise_x = base_x + @as(f64, out[index]);
                            const noise_y = @as(f64, @floatFromInt(volume.blockY(y))) * s.noise.y_scale + @as(f64, shift_y[index]);
                            const noise_z = base_z + @as(f64, shift_z[index]);
                            out[index] = s.noise.noise.get(noise_x, noise_y, noise_z);
                            index += 1;
                        }
                    }
                }
            },
            .shift_b => |n| {
                // z, x, 0 instead of x, y, z
                const transposed: Volume = .{
                    .size_x = volume.size_z,
                    .size_y = volume.size_x,
                    .size_z = 1,
                    .min_x = volume.min_z,
                    .min_y = volume.min_x,
                    .min_z = 0,
                    .step_x = volume.step_z,
                    .step_y = volume.step_x,
                    .step_z = 1,
                };
                const buffer = try ctx.acquire(transposed);
                defer ctx.release(buffer);
                @memset(buffer, 0.0);
                n.addToVolume(buffer, transposed, 0.25, 0.25, 4.0);
                const size_y: usize = @intCast(volume.size_y);
                var z: i32 = 0;
                while (z < volume.size_z) : (z += 1) {
                    var x: i32 = 0;
                    while (x < volume.size_x) : (x += 1) {
                        @memset(out[volume.index(x, 0, z)..][0..size_y], buffer[transposed.index(z, x, 0)]);
                    }
                }
            },
            .gradient => |s| {
                const size_y: usize = @intCast(volume.size_y);
                switch (s.axis) {
                    .x => {
                        var x: i32 = 0;
                        while (x < volume.size_x) : (x += 1) {
                            const value = s.compute(volume.blockX(x));
                            var z: i32 = 0;
                            while (z < volume.size_z) : (z += 1) @memset(out[volume.index(x, 0, z)..][0..size_y], value);
                        }
                    },
                    .y => {
                        var y: usize = 0;
                        while (y < size_y) : (y += 1) {
                            const value = s.compute(volume.blockY(@intCast(y)));
                            var index = y;
                            while (index < out.len) : (index += size_y) out[index] = value;
                        }
                    },
                    .z => {
                        const layer = size_y * @as(usize, @intCast(volume.size_x));
                        var z: i32 = 0;
                        while (z < volume.size_z) : (z += 1) {
                            @memset(out[volume.index(0, 0, z)..][0..layer], s.compute(volume.blockZ(z)));
                        }
                    },
                }
            },
            .spline => |*s| {
                // Coordinates are sampled for the whole volume the first time a position needs them
                const VolumeInput = struct {
                    ctx: *Context,
                    volume: Volume,
                    buffers: []?[]f32,
                    index: usize = 0,

                    fn coordinate(input: *@This(), sampler: *const Sampler, index: usize) Error!f32 {
                        const buffer = input.buffers[index] orelse blk: {
                            const buffer = try input.ctx.acquire(input.volume);
                            input.buffers[index] = buffer;
                            try sampler.sampleVolume(input.ctx, buffer, input.volume);
                            break :blk buffer;
                        };
                        return buffer[input.index];
                    }
                };
                const buffers = try ctx.gpa.alloc(?[]f32, s.coordinate_count);
                defer ctx.gpa.free(buffers);
                @memset(buffers, null);
                defer for (buffers) |buffer| {
                    if (buffer) |b| ctx.release(b);
                };
                var input: VolumeInput = .{ .ctx = ctx, .volume = volume, .buffers = buffers };
                for (out, 0..) |*v, i| {
                    input.index = i;
                    v.* = try s.root.sample(&input);
                }
            },
        }
    }

    fn lerpOrEnd(alpha: f32, first: f32, second: f32) f32 {
        if (alpha == 0.0) return first;
        if (alpha == 1.0) return second;
        return math.lm.lerp(f32, first, second, alpha);
    }

    fn selectInterval(thresholds: []const f32, count: usize, input: f32) usize {
        for (thresholds, 0..) |threshold, i| {
            if (input < threshold) return i;
        }
        return count - 1;
    }

    /// Samples one position.
    pub fn sampleValue(self: *const Sampler, ctx: *Context, x: i32, y: i32, z: i32) Error!f32 {
        switch (self.*) {
            .constant => |value| return value,

            .abs => |input| return @abs(try input.sampleValue(ctx, x, y, z)),
            .square => |input| {
                const v = try input.sampleValue(ctx, x, y, z);
                return v * v;
            },
            .cube => |input| {
                const v = try input.sampleValue(ctx, x, y, z);
                return v * v * v;
            },
            .reciprocal => |input| return 1.0 / try input.sampleValue(ctx, x, y, z),
            .negate => |input| return -try input.sampleValue(ctx, x, y, z),
            .squeeze => |input| return squeezeValue(try input.sampleValue(ctx, x, y, z)),
            .sign => |input| return signum(try input.sampleValue(ctx, x, y, z)),
            .leaky_relu => |s| return leakyRelu(s.factor, try s.input.sampleValue(ctx, x, y, z)),

            .const_add => |s| return try s.input.sampleValue(ctx, x, y, z) + s.value,
            .const_sub => |s| return s.value - try s.input.sampleValue(ctx, x, y, z),
            .const_mul => |s| return try s.input.sampleValue(ctx, x, y, z) * s.value,
            .const_div => |s| return s.value / try s.input.sampleValue(ctx, x, y, z),
            .const_min => |s| return java.javaMin(f32, try s.input.sampleValue(ctx, x, y, z), s.value),
            .const_max => |s| return java.javaMax(f32, try s.input.sampleValue(ctx, x, y, z), s.value),
            .add => |s| return try s.left.sampleValue(ctx, x, y, z) + try s.right.sampleValue(ctx, x, y, z),
            .sub => |s| return try s.left.sampleValue(ctx, x, y, z) - try s.right.sampleValue(ctx, x, y, z),
            .mul => |s| {
                const left = try s.left.sampleValue(ctx, x, y, z);
                if (left == 0.0) return 0.0;
                return left * try s.right.sampleValue(ctx, x, y, z);
            },
            .div => |s| {
                const left = try s.left.sampleValue(ctx, x, y, z);
                if (left == 0.0) return 0.0;
                return left / try s.right.sampleValue(ctx, x, y, z);
            },
            .min => |s| {
                const left = try s.left.sampleValue(ctx, x, y, z);
                if (left <= s.bound) return left;
                return java.javaMin(f32, left, try s.right.sampleValue(ctx, x, y, z));
            },
            .max => |s| {
                const left = try s.left.sampleValue(ctx, x, y, z);
                if (left >= s.bound) return left;
                return java.javaMax(f32, left, try s.right.sampleValue(ctx, x, y, z));
            },

            .clamp => |s| return java.clamp(f32, try s.input.sampleValue(ctx, x, y, z), s.min, s.max),
            .lerp => |s| {
                const alpha = try s.alpha.sampleValue(ctx, x, y, z);
                if (alpha == 0.0) return s.first.sampleValue(ctx, x, y, z);
                if (alpha == 1.0) return s.second.sampleValue(ctx, x, y, z);
                const first = try s.first.sampleValue(ctx, x, y, z);
                return math.lm.lerp(f32, first, try s.second.sampleValue(ctx, x, y, z), alpha);
            },
            .lerp_const_first => |s| {
                const alpha = try s.alpha.sampleValue(ctx, x, y, z);
                if (alpha == 0.0) return s.first;
                if (alpha == 1.0) return s.second.sampleValue(ctx, x, y, z);
                return math.lm.lerp(f32, s.first, try s.second.sampleValue(ctx, x, y, z), alpha);
            },
            .lerp_const_second => |s| {
                const alpha = try s.alpha.sampleValue(ctx, x, y, z);
                if (alpha == 0.0) return s.first.sampleValue(ctx, x, y, z);
                if (alpha == 1.0) return s.second;
                return math.lm.lerp(f32, try s.first.sampleValue(ctx, x, y, z), s.second, alpha);
            },
            .range_choice => |s| {
                const input = try s.input.sampleValue(ctx, x, y, z);
                if (input >= s.min_inclusive and input < s.max_exclusive) return s.when_in_range.sampleValue(ctx, x, y, z);
                return s.when_out_of_range.sampleValue(ctx, x, y, z);
            },
            .range_choice_const => |s| {
                const input = try s.input.sampleValue(ctx, x, y, z);
                return if (input >= s.min_inclusive and input < s.max_exclusive) s.when_in_range else s.when_out_of_range;
            },
            .threshold => |s| {
                const input = try s.input.sampleValue(ctx, x, y, z);
                if (input < s.threshold) return s.if_below.sampleValue(ctx, x, y, z);
                return s.if_above.sampleValue(ctx, x, y, z);
            },
            .interval_select => |s| {
                const input = try s.input.sampleValue(ctx, x, y, z);
                return s.samplers[selectInterval(s.thresholds, s.samplers.len, input)].sampleValue(ctx, x, y, z);
            },

            .caching => |s| {
                {
                    const cell = try ctx.cell(s.id) orelse return s.input.sampleValue(ctx, x, y, z);
                    if (cell.value == cell.value and cell.key[0] == x and cell.key[1] == y and cell.key[2] == z) return cell.value;
                    if (cell.buffer) |buffer| {
                        if (cell.volume.indexOfBlock(x, y, z)) |index| return buffer[index];
                    }
                }
                const value = try s.input.sampleValue(ctx, x, y, z);
                const cell = (try ctx.cell(s.id)).?;
                cell.key = .{ x, y, z };
                cell.value = value;
                return value;
            },
            .interpolated => |*s| return s.sampleValue(ctx, x, y, z),
            .slice_x => |s| return s.input.sampleValue(ctx, s.coordinate, y, z),
            .slice_y => |s| return s.input.sampleValue(ctx, x, s.coordinate, z),
            .slice_z => |s| return s.input.sampleValue(ctx, x, y, s.coordinate),
            .slice_xz => |s| return s.input.sampleValue(ctx, s.x, y, s.z),
            .find_top_surface => |*s| {
                const upper_bound = try s.upper_bound.sampleValue(ctx, x, y, z);
                return @floatFromInt(try s.findSurface(ctx, x, z, upper_bound));
            },

            .noise => |s| return s.noise.get(
                @as(f64, @floatFromInt(x)) * s.xz_scale,
                @as(f64, @floatFromInt(y)) * s.y_scale,
                @as(f64, @floatFromInt(z)) * s.xz_scale,
            ),
            .shifted_xz => |s| {
                const noise_x = @as(f64, @floatFromInt(x)) * s.noise.xz_scale + @as(f64, try s.shift_x.sampleValue(ctx, x, y, z));
                const noise_y = @as(f64, @floatFromInt(y)) * s.noise.y_scale;
                const noise_z = @as(f64, @floatFromInt(z)) * s.noise.xz_scale + @as(f64, try s.shift_z.sampleValue(ctx, x, y, z));
                return s.noise.noise.get(noise_x, noise_y, noise_z);
            },
            .shifted_xyz => |s| {
                const noise_x = @as(f64, @floatFromInt(x)) * s.noise.xz_scale + @as(f64, try s.shift_x.sampleValue(ctx, x, y, z));
                const noise_y = @as(f64, @floatFromInt(y)) * s.noise.y_scale + @as(f64, try s.shift_y.sampleValue(ctx, x, y, z));
                const noise_z = @as(f64, @floatFromInt(z)) * s.noise.xz_scale + @as(f64, try s.shift_z.sampleValue(ctx, x, y, z));
                return s.noise.noise.get(noise_x, noise_y, noise_z);
            },
            .shift_b => |n| return n.get(@as(f64, @floatFromInt(z)) * 0.25, @as(f64, @floatFromInt(x)) * 0.25, 0.0) * 4.0,
            .gradient => |s| return s.compute(switch (s.axis) {
                .x => x,
                .y => y,
                .z => z,
            }),
            .spline => |*s| {
                const PointInput = struct {
                    ctx: *Context,
                    position: [3]i32,
                    /// NaN until sampled
                    values: []f32,

                    fn coordinate(input: *@This(), sampler: *const Sampler, index: usize) Error!f32 {
                        const cached = input.values[index];
                        if (cached == cached) return cached;
                        const value = try sampler.sampleValue(input.ctx, input.position[0], input.position[1], input.position[2]);
                        input.values[index] = value;
                        return value;
                    }
                };
                var stack: [16]f32 = undefined;
                const values = if (s.coordinate_count <= stack.len) stack[0..s.coordinate_count] else try ctx.gpa.alloc(f32, s.coordinate_count);
                defer if (s.coordinate_count > stack.len) ctx.gpa.free(values);
                @memset(values, std.math.nan(f32));
                var input: PointInput = .{ .ctx = ctx, .position = .{ x, y, z }, .values = values };
                return s.root.sample(&input);
            },
        }
    }
};

fn lerpInterpolated(s: *const Sampler.Interpolated, out: []f32, out_volume: Volume, cell_volume: Volume, cell: [3]i32, v: [8]f32) void {
    const cell_out_x = cell_volume.blockX(cell[0]) - out_volume.min_x;
    const cell_out_y = cell_volume.blockY(cell[1]) - out_volume.min_y;
    const cell_out_z = cell_volume.blockZ(cell[2]) - out_volume.min_z;
    const x0 = @max(0, -cell_out_x);
    const y0 = @max(0, -cell_out_y);
    const z0 = @max(0, -cell_out_z);
    const x1 = @min(s.cell_size_xz, out_volume.size_x - cell_out_x) - 1;
    const y1 = @min(s.cell_size_y, out_volume.size_y - cell_out_y) - 1;
    const z1 = @min(s.cell_size_xz, out_volume.size_z - cell_out_z) - 1;

    // v is 000, 100, 010, 110, 001, 101, 011, 111 (x, y, z)
    var z = z0;
    while (z <= z1) : (z += 1) {
        const alpha_z = @as(f32, @floatFromInt(z)) * s.cell_size_xz_inv;
        const v00 = math.lm.lerp(f32, v[0], v[4], alpha_z);
        const v01 = math.lm.lerp(f32, v[2], v[6], alpha_z);
        const v10 = math.lm.lerp(f32, v[1], v[5], alpha_z);
        const v11 = math.lm.lerp(f32, v[3], v[7], alpha_z);
        var x = x0;
        while (x <= x1) : (x += 1) {
            const alpha_x = @as(f32, @floatFromInt(x)) * s.cell_size_xz_inv;
            const bottom = math.lm.lerp(f32, v00, v10, alpha_x);
            const top = math.lm.lerp(f32, v01, v11, alpha_x);
            // Not a lerp along y: the step gets added block after block, the error with it
            const step = (top - bottom) * s.cell_size_y_inv;
            var value = bottom + step * @as(f32, @floatFromInt(y0));
            var index = out_volume.index(cell_out_x + x, cell_out_y + y0, cell_out_z + z);
            var y = y0;
            while (y <= y1) : (y += 1) {
                out[index] = value;
                index += 1;
                value += step;
            }
        }
    }
}

fn interpolatedBlockStep(s: *const Sampler.Interpolated, ctx: *Context, out: []f32, volume: Volume) Error!void {
    const min_cell_x = @divFloor(volume.min_x, s.cell_size_xz);
    const min_cell_y = @divFloor(volume.min_y, s.cell_size_y);
    const min_cell_z = @divFloor(volume.min_z, s.cell_size_xz);
    const count_x = @divFloor(volume.maxX(), s.cell_size_xz) - min_cell_x + 1;
    const count_y = @divFloor(volume.maxY(), s.cell_size_y) - min_cell_y + 1;
    const count_z = @divFloor(volume.maxZ(), s.cell_size_xz) - min_cell_z + 1;
    // The corners of the cells, one more than the cells unless the volume ends on a corner
    const cell_volume: Volume = .{
        .size_x = if (@mod(volume.maxX(), s.cell_size_xz) == 0) count_x else count_x + 1,
        .size_y = if (@mod(volume.maxY(), s.cell_size_y) == 0) count_y else count_y + 1,
        .size_z = if (@mod(volume.maxZ(), s.cell_size_xz) == 0) count_z else count_z + 1,
        .min_x = min_cell_x * s.cell_size_xz,
        .min_y = min_cell_y * s.cell_size_y,
        .min_z = min_cell_z * s.cell_size_xz,
        .step_x = s.cell_size_xz,
        .step_y = s.cell_size_y,
        .step_z = s.cell_size_xz,
    };
    const cells = try ctx.acquire(cell_volume);
    defer ctx.release(cells);
    try s.input.sampleVolume(ctx, cells, cell_volume);

    var cell_z: i32 = 0;
    while (cell_z < count_z) : (cell_z += 1) {
        const next_z = @min(cell_z + 1, cell_volume.size_z - 1);
        var cell_x: i32 = 0;
        while (cell_x < count_x) : (cell_x += 1) {
            const next_x = @min(cell_x + 1, cell_volume.size_x - 1);
            var v000 = cells[cell_volume.index(cell_x, 0, cell_z)];
            var v100 = cells[cell_volume.index(next_x, 0, cell_z)];
            var v001 = cells[cell_volume.index(cell_x, 0, next_z)];
            var v101 = cells[cell_volume.index(next_x, 0, next_z)];
            var cell_y: i32 = 0;
            while (cell_y < count_y) : (cell_y += 1) {
                const next_y = @min(cell_y + 1, cell_volume.size_y - 1);
                const v010 = cells[cell_volume.index(cell_x, next_y, cell_z)];
                const v110 = cells[cell_volume.index(next_x, next_y, cell_z)];
                const v011 = cells[cell_volume.index(cell_x, next_y, next_z)];
                const v111 = cells[cell_volume.index(next_x, next_y, next_z)];
                lerpInterpolated(s, out, volume, cell_volume, .{ cell_x, cell_y, cell_z }, .{ v000, v100, v010, v110, v001, v101, v011, v111 });
                v000 = v010;
                v100 = v110;
                v001 = v011;
                v101 = v111;
            }
        }
    }
}

fn interpolatedVolume(s: *const Sampler.Interpolated, ctx: *Context, out: []f32, volume: Volume) Error!void {
    // Already only the cells' corners (or a single position on that axis)
    const on_corners = (volume.step_x == s.cell_size_xz or volume.size_x == 1) and
        (volume.step_y == s.cell_size_y or volume.size_y == 1) and
        (volume.step_z == s.cell_size_xz or volume.size_z == 1) and
        @mod(volume.min_x, s.cell_size_xz) == 0 and
        @mod(volume.min_y, s.cell_size_y) == 0 and
        @mod(volume.min_z, s.cell_size_xz) == 0;
    if (on_corners) return s.input.sampleVolume(ctx, out, volume);

    if (volume.step_x == 1 and volume.step_y == 1 and volume.step_z == 1) return interpolatedBlockStep(s, ctx, out, volume);

    // Every block, then the ones asked for
    const block_volume: Volume = .{
        .size_x = volume.size_x * volume.step_x,
        .size_y = volume.size_y * volume.step_y,
        .size_z = volume.size_z * volume.step_z,
        .min_x = volume.min_x,
        .min_y = volume.min_y,
        .min_z = volume.min_z,
    };
    const blocks = try ctx.acquire(block_volume);
    defer ctx.release(blocks);
    try interpolatedBlockStep(s, ctx, blocks, block_volume);
    var z: i32 = 0;
    while (z < volume.size_z) : (z += 1) {
        var x: i32 = 0;
        while (x < volume.size_x) : (x += 1) {
            var y: i32 = 0;
            while (y < volume.size_y) : (y += 1) {
                out[volume.index(x, y, z)] = blocks[block_volume.index(x * volume.step_x, y * volume.step_y, z * volume.step_z)];
            }
        }
    }
}

fn interpolatedValue(s: *const Sampler.Interpolated, ctx: *Context, x: i32, y: i32, z: i32) Error!f32 {
    const x_in_cell = @mod(x, s.cell_size_xz);
    const y_in_cell = @mod(y, s.cell_size_y);
    const z_in_cell = @mod(z, s.cell_size_xz);
    if (x_in_cell == 0 and y_in_cell == 0 and z_in_cell == 0) return s.input.sampleValue(ctx, x, y, z);

    const volume: Volume = .{
        .size_x = 2,
        .size_y = 2,
        .size_z = 2,
        .min_x = x - x_in_cell,
        .min_y = y - y_in_cell,
        .min_z = z - z_in_cell,
        .step_x = s.cell_size_xz,
        .step_y = s.cell_size_y,
        .step_z = s.cell_size_xz,
    };
    var corners: [8]f32 = undefined;
    try s.input.sampleVolume(ctx, &corners, volume);
    return java.lerp3(
        @as(f32, @floatFromInt(x_in_cell)) / @as(f32, @floatFromInt(s.cell_size_xz)),
        @as(f32, @floatFromInt(y_in_cell)) / @as(f32, @floatFromInt(s.cell_size_y)),
        @as(f32, @floatFromInt(z_in_cell)) / @as(f32, @floatFromInt(s.cell_size_xz)),
        corners[volume.index(0, 0, 0)],
        corners[volume.index(1, 0, 0)],
        corners[volume.index(0, 1, 0)],
        corners[volume.index(1, 1, 0)],
        corners[volume.index(0, 0, 1)],
        corners[volume.index(1, 0, 1)],
        corners[volume.index(0, 1, 1)],
        corners[volume.index(1, 1, 1)],
    );
}

fn findSurfaceFrom(s: *const Sampler.FindTopSurface, ctx: *Context, x: i32, z: i32, upper_bound: f32) Error!i32 {
    const top_y = java.floor(upper_bound / @as(f32, @floatFromInt(s.cell_height))) *% s.cell_height;
    if (top_y <= s.lower_bound) return s.lower_bound;
    var probe_y = top_y;
    while (probe_y >= s.lower_bound) : (probe_y -= s.cell_height) {
        if (try s.density.sampleValue(ctx, x, probe_y, z) > 0.0) return probe_y;
    }
    return s.lower_bound;
}
