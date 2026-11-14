//! Vanilla's noises (net.minecraft.world.level.levelgen.synth), they have to match bit for bit:
//! a block is solid when its density is above 0, so the smallest difference moves terrain.
const std = @import("std");
const java = @import("java.zig");
const random = @import("random.zig");
const Volume = @import("Volume.zig");

const Allocator = std.mem.Allocator;

const Gradient = struct { x: f32, y: f32, z: f32 };
const gradients = [16]Gradient{
    .{ .x = 1, .y = 1, .z = 0 }, .{ .x = -1, .y = 1, .z = 0 }, .{ .x = 1, .y = -1, .z = 0 }, .{ .x = -1, .y = -1, .z = 0 },
    .{ .x = 1, .y = 0, .z = 1 }, .{ .x = -1, .y = 0, .z = 1 }, .{ .x = 1, .y = 0, .z = -1 }, .{ .x = -1, .y = 0, .z = -1 },
    .{ .x = 0, .y = 1, .z = 1 }, .{ .x = 0, .y = -1, .z = 1 }, .{ .x = 0, .y = 1, .z = -1 }, .{ .x = 0, .y = -1, .z = -1 },
    .{ .x = 1, .y = 1, .z = 0 }, .{ .x = 0, .y = -1, .z = 1 }, .{ .x = -1, .y = 1, .z = 0 }, .{ .x = 0, .y = -1, .z = -1 },
};

/// Keeps coordinates in the range where doubles still have enough precision (no far lands).
fn wrap(x: f64) f64 {
    const half_round_off = comptime std.math.nextAfter(f64, 1.6777216e7, 0);
    if (x >= -half_round_off and x < half_round_off) return x;
    return x - @floor(x / 3.3554432e7 + 0.5) * 3.3554432e7;
}

/// `PerlinNoise`, and `SmearedPerlinNoise` (the old terrain noise) when `smear` is set.
pub const Perlin = struct {
    perms: [256]u8,
    offset_x: f64,
    offset_y: f64,
    offset_z: f64,
    /// `fudgeYScale`, y gets snapped to multiples of it.
    smear: ?f64 = null,

    pub fn init(rand: *random.Xoroshiro) Perlin {
        var self: Perlin = undefined;
        self.smear = null;
        self.offset_x = rand.nextDouble() * 256.0;
        self.offset_y = rand.nextDouble() * 256.0;
        self.offset_z = rand.nextDouble() * 256.0;
        for (&self.perms, 0..) |*p, i| p.* = @intCast(i);
        for (0..256) |i| {
            const offset = rand.nextInt(@intCast(256 - i));
            std.mem.swap(u8, &self.perms[i], &self.perms[i + offset]);
        }
        return self;
    }

    fn permute(self: *const Perlin, x: i32) i32 {
        return self.perms[@as(u8, @truncate(@as(u32, @bitCast(x))))];
    }

    fn grad(self: *const Perlin, x: i32) Gradient {
        return gradients[@intCast(self.permute(x) & 0xF)];
    }

    fn fudgeY(smear: f64, original_y: f64, relative_y: f64) f64 {
        const limit = if (original_y >= 0.0 and original_y < relative_y) original_y else relative_y;
        return @as(f64, @floatFromInt(java.floor(limit / smear + @as(f64, @as(f32, 1.0e-7))))) * smear;
    }

    pub fn get(self: *const Perlin, in_x: f64, in_y: f64, in_z: f64) f32 {
        const x = wrap(in_x) + self.offset_x;
        const y = wrap(in_y) + self.offset_y;
        const z = wrap(in_z) + self.offset_z;
        const floor_x = java.floor(x);
        const floor_y = java.floor(y);
        const floor_z = java.floor(z);
        const rx: f32 = @floatCast(x - @as(f64, @floatFromInt(floor_x)));
        const ry_double = y - @as(f64, @floatFromInt(floor_y));
        const rz: f32 = @floatCast(z - @as(f64, @floatFromInt(floor_z)));
        const original_ry: f32 = @floatCast(ry_double);
        const ry: f32 = if (self.smear) |smear| @floatCast(ry_double - fudgeY(smear, in_y, ry_double)) else original_ry;

        const x0 = self.permute(floor_x);
        const x1 = self.permute(floor_x +% 1);
        const xy00 = self.permute(x0 +% floor_y);
        const xy01 = self.permute(x0 +% floor_y +% 1);
        const xy10 = self.permute(x1 +% floor_y);
        const xy11 = self.permute(x1 +% floor_y +% 1);
        const d000 = dot(self.grad(xy00 +% floor_z), rx, ry, rz);
        const d100 = dot(self.grad(xy10 +% floor_z), rx - 1.0, ry, rz);
        const d010 = dot(self.grad(xy01 +% floor_z), rx, ry - 1.0, rz);
        const d110 = dot(self.grad(xy11 +% floor_z), rx - 1.0, ry - 1.0, rz);
        const d001 = dot(self.grad(xy00 +% floor_z +% 1), rx, ry, rz - 1.0);
        const d101 = dot(self.grad(xy10 +% floor_z +% 1), rx - 1.0, ry, rz - 1.0);
        const d011 = dot(self.grad(xy01 +% floor_z +% 1), rx, ry - 1.0, rz - 1.0);
        const d111 = dot(self.grad(xy11 +% floor_z +% 1), rx - 1.0, ry - 1.0, rz - 1.0);
        return java.lerp3(java.smoothstep(rx), java.smoothstep(original_ry), java.smoothstep(rz), d000, d100, d010, d110, d001, d101, d011, d111);
    }

    fn dot(g: Gradient, x: f32, y: f32, z: f32) f32 {
        return g.x * x + g.y * y + g.z * z;
    }

    fn dotXz(g: Gradient, x: f32, z: f32) f32 {
        return g.x * x + g.z * z;
    }

    /// Adds `amplitude * noise` of every position to `buffer`. Not the same rounding as `get`
    /// in every case (the y part of the dot products is added last), vanilla has both.
    pub fn addToVolume(self: *const Perlin, buffer: []f32, volume: Volume, xz_scale: f64, y_scale: f64, amplitude: f32) void {
        var d_xz: [8]f32 = @splat(0.0);
        var g_y: [8]f32 = @splat(0.0);
        var index: usize = 0;
        var index_z: i32 = 0;
        while (index_z < volume.size_z) : (index_z += 1) {
            const z = wrap(@as(f64, @floatFromInt(volume.blockZ(index_z))) * xz_scale) + self.offset_z;
            const floor_z = java.floor(z);
            const rz: f32 = @floatCast(z - @as(f64, @floatFromInt(floor_z)));
            const alpha_z = java.smoothstep(rz);
            var index_x: i32 = 0;
            while (index_x < volume.size_x) : (index_x += 1) {
                const x = wrap(@as(f64, @floatFromInt(volume.blockX(index_x))) * xz_scale) + self.offset_x;
                const floor_x = java.floor(x);
                const rx: f32 = @floatCast(x - @as(f64, @floatFromInt(floor_x)));
                const x0 = self.permute(floor_x);
                const x1 = self.permute(floor_x +% 1);
                const alpha_x = java.smoothstep(rx);
                var last_floor_y: ?i32 = null;
                var index_y: i32 = 0;
                while (index_y < volume.size_y) : (index_y += 1) {
                    const original_y = @as(f64, @floatFromInt(volume.blockY(index_y))) * y_scale;
                    const y = wrap(original_y) + self.offset_y;
                    const floor_y = java.floor(y);
                    const ry_double = y - @as(f64, @floatFromInt(floor_y));
                    const alpha_y = java.smoothstep(@floatCast(ry_double));
                    if (last_floor_y != floor_y) {
                        const xy00 = self.permute(x0 +% floor_y);
                        const xy01 = self.permute(x0 +% floor_y +% 1);
                        const xy10 = self.permute(x1 +% floor_y);
                        const xy11 = self.permute(x1 +% floor_y +% 1);
                        const corners = [8]Gradient{
                            self.grad(xy00 +% floor_z),      self.grad(xy10 +% floor_z),
                            self.grad(xy01 +% floor_z),      self.grad(xy11 +% floor_z),
                            self.grad(xy00 +% floor_z +% 1), self.grad(xy10 +% floor_z +% 1),
                            self.grad(xy01 +% floor_z +% 1), self.grad(xy11 +% floor_z +% 1),
                        };
                        for (corners, &d_xz, &g_y, 0..) |g, *d, *gy, corner| {
                            d.* = dotXz(g, if (corner & 1 == 0) rx else rx - 1.0, if (corner & 4 == 0) rz else rz - 1.0);
                            gy.* = g.y;
                        }
                        last_floor_y = floor_y;
                    }
                    const ry: f32 = if (self.smear) |smear| @floatCast(ry_double - fudgeY(smear, original_y, ry_double)) else @floatCast(ry_double);
                    buffer[index] += amplitude * java.lerp3(
                        alpha_x,
                        alpha_y,
                        alpha_z,
                        d_xz[0] + g_y[0] * ry,
                        d_xz[1] + g_y[1] * ry,
                        d_xz[2] + g_y[2] * (ry - 1.0),
                        d_xz[3] + g_y[3] * (ry - 1.0),
                        d_xz[4] + g_y[4] * ry,
                        d_xz[5] + g_y[5] * ry,
                        d_xz[6] + g_y[6] * (ry - 1.0),
                        d_xz[7] + g_y[7] * (ry - 1.0),
                    );
                    index += 1;
                }
            }
        }
    }
};

/// `SimplexNoise` without offsets, only its 2d sampling: what biomes' temperatures use.
pub const Simplex = struct {
    perms: [256]u8,

    const sqrt_3 = @sqrt(3.0);
    const f2 = 0.5 * (sqrt_3 - 1.0);
    const g2 = (3.0 - sqrt_3) / 6.0;

    pub fn init(rand: *random.Legacy) Simplex {
        var self: Simplex = undefined;
        // The offsets, they're multiplied by 0
        for (0..3) |_| _ = rand.nextDouble();
        for (&self.perms, 0..) |*p, i| p.* = @intCast(i);
        for (0..256) |i| {
            const offset: usize = @intCast(rand.nextInt(@intCast(256 - i)));
            std.mem.swap(u8, &self.perms[i], &self.perms[i + offset]);
        }
        return self;
    }

    fn permute(self: *const Simplex, x: i32) i32 {
        return self.perms[@as(u8, @truncate(@as(u32, @bitCast(x))))];
    }

    fn corner(index: i32, x: f64, y: f64) f64 {
        var t = 0.5 - x * x - y * y - 0.0 * 0.0;
        if (t < 0.0) return 0.0;
        t *= t;
        const g = gradients[@intCast(index)];
        return t * t * (@as(f64, g.x) * x + @as(f64, g.y) * y + @as(f64, g.z) * 0.0);
    }

    pub fn get(self: *const Simplex, xin: f64, yin: f64) f32 {
        const s = (xin + yin) * f2;
        const i = java.floor(xin + s);
        const j = java.floor(yin + s);
        const t = @as(f64, @floatFromInt(i +% j)) * g2;
        const x0 = xin - (@as(f64, @floatFromInt(i)) - t);
        const y0 = yin - (@as(f64, @floatFromInt(j)) - t);
        const i_1: i32 = if (x0 > y0) 1 else 0;
        const j_1: i32 = 1 - i_1;
        const x1 = x0 - @as(f64, @floatFromInt(i_1)) + g2;
        const y1 = y0 - @as(f64, @floatFromInt(j_1)) + g2;
        const x2 = x0 - 1.0 + 2.0 * g2;
        const y2 = y0 - 1.0 + 2.0 * g2;
        const ii = i & 0xFF;
        const jj = j & 0xFF;
        const gi0 = @rem(self.permute(ii + self.permute(jj)), 12);
        const gi1 = @rem(self.permute(ii + i_1 + self.permute(jj + j_1)), 12);
        const gi2 = @rem(self.permute(ii + 1 + self.permute(jj + 1)), 12);
        return @floatCast(70.0 * (corner(gi0, x0, y0) + corner(gi1, x1, y1) + corner(gi2, x2, y2)));
    }
};

/// `NoiseStack`: layers of perlin noise added together.
pub const Noise = struct {
    layers: []const Layer,

    pub const Layer = struct {
        noise: Perlin,
        frequency: f64,
        amplitude: f32,
    };

    pub fn get(self: Noise, x: f64, y: f64, z: f64) f32 {
        var value: f32 = 0.0;
        for (self.layers) |*layer| {
            value += layer.amplitude * layer.noise.get(x * layer.frequency, y * layer.frequency, z * layer.frequency);
        }
        return value;
    }

    pub fn addToVolume(self: Noise, buffer: []f32, volume: Volume, xz_scale: f64, y_scale: f64, amplitude: f32) void {
        for (self.layers) |*layer| {
            layer.noise.addToVolume(buffer, volume, xz_scale * layer.frequency, y_scale * layer.frequency, amplitude * layer.amplitude);
        }
    }
};

/// A worldgen/noise file (`NormalNoise.Parameters`).
pub const Parameters = struct {
    base_amplitude: f64 = 1.0,
    base_octave: i32,
    octave_count: u32 = 1,
    normalize: Normalization = .enabled,
    /// Empty if every octave is 1.0
    amplitude_modifiers: []const f64 = &.{},

    pub const Normalization = enum { disabled, enabled, legacy };
    pub const max_octaves = 32;

    const perlin_deviation = 0.2702247831245211;
    const target_deviation = 0.3333333333333333;
    const second_frequency = 1.0181268882175227;

    const Octave = struct { index: i32, frequency: f64, amplitude: f64 };

    fn modifier(self: Parameters, i: usize) f64 {
        return if (self.amplitude_modifiers.len == 0) 1.0 else self.amplitude_modifiers[i];
    }

    fn octaves(self: Parameters, buf: *[max_octaves]Octave) []Octave {
        var frequency = std.math.ldexp(@as(f64, 1.0), self.base_octave);
        var amplitude = self.base_amplitude;
        if (self.normalize != .disabled) {
            const count: i32 = @intCast(self.octave_count);
            amplitude *= std.math.ldexp(@as(f64, 1.0), count - 1) / (std.math.ldexp(@as(f64, 1.0), count) - 1.0);
        }
        var len: usize = 0;
        for (0..self.octave_count) |i| {
            const mod = self.modifier(i);
            if (mod != 0.0) {
                buf[len] = .{ .index = self.base_octave + @as(i32, @intCast(i)), .frequency = frequency, .amplitude = amplitude * mod };
                len += 1;
            }
            frequency *= 2.0;
            amplitude *= 0.5;
        }
        return buf[0..len];
    }

    fn normalizationFactor(self: Parameters, octs: []const Octave) f64 {
        var target_amplitude: f64 = 0.0;
        for (octs) |o| target_amplitude += @abs(o.amplitude);

        var variance: f64 = 0.0;
        for (octs) |o| {
            const deviation = perlin_deviation * @abs(o.amplitude);
            variance += deviation * deviation;
        }
        const input_deviation = @sqrt(variance);
        const factor = if (input_deviation == 0.0) 0.0 else (target_amplitude * target_deviation) / (input_deviation * @sqrt(2.0));
        if (self.normalize != .legacy or factor == 0.0) return factor;

        // The factor older versions had, only depends on how far apart the first and last octaves are
        var min_octave: i32 = std.math.maxInt(i32);
        var max_octave: i32 = std.math.minInt(i32);
        for (0..self.octave_count) |i| {
            if (self.modifier(i) == 0.0) continue;
            min_octave = @min(min_octave, @as(i32, @intCast(i)));
            max_octave = @max(max_octave, @as(i32, @intCast(i)));
        }
        const expected_deviation = 0.1 * (1.0 + 1.0 / @as(f64, @floatFromInt(max_octave - min_octave + 1)));
        return self.base_amplitude * 0.5 * target_deviation / expected_deviation;
    }

    /// The most the noise can be (`NormalNoise.range` is from minus this to this).
    pub fn maxValue(self: Parameters) f32 {
        var buf: [max_octaves]Octave = undefined;
        const octs = self.octaves(&buf);
        var target_amplitude: f64 = 0.0;
        for (octs) |o| target_amplitude += @abs(o.amplitude);
        if (self.normalize == .legacy) {
            // Scaled by how much the legacy factor is off from the normal one
            const legacy = self.normalizationFactor(octs);
            var normal = self;
            normal.normalize = .enabled;
            const factor = normal.normalizationFactor(octs);
            if (factor != 0.0) target_amplitude *= legacy / factor;
        }
        return @floatCast(target_amplitude * target_deviation * 6.0);
    }

    /// `NormalNoise.create`, two perlin noises per octave.
    pub fn create(self: Parameters, arena: Allocator, rand: *random.Xoroshiro) Allocator.Error!Noise {
        const first_random = random.forkPositional(rand);
        const second_random = random.forkPositional(rand);

        var buf: [max_octaves]Octave = undefined;
        const octs = self.octaves(&buf);
        const factor = self.normalizationFactor(octs);

        const layers = try arena.alloc(Noise.Layer, octs.len * 2);
        for (octs, 0..) |octave, i| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "octave_{d}", .{octave.index}) catch unreachable;
            var first = first_random.fromHashOf(name);
            var second = second_random.fromHashOf(name);
            const amplitude: f32 = @floatCast(factor * octave.amplitude);
            layers[i * 2] = .{ .noise = .init(&first), .frequency = octave.frequency, .amplitude = amplitude };
            layers[i * 2 + 1] = .{ .noise = .init(&second), .frequency = octave.frequency * second_frequency, .amplitude = amplitude };
        }
        return .{ .layers = layers };
    }
};

/// `Noises.instantiate`: the noise's random comes from the hash of its id.
pub fn instantiate(arena: Allocator, positional: random.Positional, id: []const u8, parameters: Parameters) Allocator.Error!Noise {
    var rand = positional.fromHashOf(id);
    return parameters.create(arena, &rand);
}

test "same as vanilla" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var seed: random.Xoroshiro = .init(12345);
    const positional = random.forkPositional(&seed);

    const points = [_][3]f64{
        .{ 0, 0, 0 },
        .{ 1.5, 2.25, -3.125 },
        .{ 1000.1, -64, -20000.7 },
        .{ -123456.789, 77.7, 98765.4321 },
        .{ 3.0e7, 5, -4.0e7 },
    };
    // Float bits of `RandomState.getOrCreateNoise(...).get(x, y, z)` with seed 12345
    const cases = [_]struct { []const u8, Parameters, [points.len]u32 }{
        .{
            "minecraft:temperature",
            .{ .amplitude_modifiers = &.{ 1.5, 0.0, 1.0, 0.0, 0.0, 0.0 }, .base_amplitude = 1.2453007926713473, .base_octave = -10, .octave_count = 6 },
            .{ 0xbcca9ff2, 0xbcce1fa6, 0xbe6fd4c7, 0x3f2c8f00, 0xbe8ff789 },
        },
        .{
            "minecraft:surface",
            .{ .base_amplitude = 0.9381732587751008, .base_octave = -6, .octave_count = 3 },
            .{ 0x3df36c66, 0x3cf5d0a6, 0x3dde91b4, 0x3eb5e766, 0xbe4fb346 },
        },
    };
    for (cases) |case| {
        const noise = try instantiate(arena.allocator(), positional, case[0], case[1]);
        for (points, case[2]) |p, expected| {
            try std.testing.expectEqual(expected, @as(u32, @bitCast(noise.get(p[0], p[1], p[2]))));
        }

        // Both paths give the same values here
        const volume: Volume = .{ .size_x = 3, .size_y = 7, .size_z = 2, .min_x = -1000, .min_y = -64, .min_z = 5000, .step_x = 4, .step_y = 8, .step_z = 4 };
        var buffer: [3 * 7 * 2]f32 = @splat(0.0);
        noise.addToVolume(&buffer, volume, 1.0, 0.5, 1.0);
        var z: i32 = 0;
        while (z < volume.size_z) : (z += 1) {
            var x: i32 = 0;
            while (x < volume.size_x) : (x += 1) {
                var y: i32 = 0;
                while (y < volume.size_y) : (y += 1) {
                    const value = noise.get(@floatFromInt(volume.blockX(x)), @as(f64, @floatFromInt(volume.blockY(y))) * 0.5, @floatFromInt(volume.blockZ(z)));
                    try std.testing.expectEqual(value, buffer[volume.index(x, y, z)]);
                }
            }
        }
    }
}
