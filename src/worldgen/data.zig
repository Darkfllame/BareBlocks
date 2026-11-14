//! The worldgen data: noises, density functions, material rules and biomes.
//! Generated from the data generator's worldgen/ files by build/worldgen.zig, these are its types.
const std = @import("std");
const noise = @import("noise.zig");

const generated = @import("worldgen_data").Data(@This());

pub const noises: []const NamedNoise = &generated.noises;
/// Equal functions are the same entry, so comparing ids is comparing functions.
pub const functions: []const DensityFunction = &generated.functions;
pub const named_functions: []const NamedFunction = &generated.named_functions;
pub const splines: []const Spline = &generated.splines;
pub const rules: []const Rule = &generated.rules;
pub const conditions: []const Condition = &generated.conditions;
/// In the order of their network ids.
pub const biomes: []const Biome = &generated.biomes;
pub const noise_settings: []const NoiseSettings = &generated.noise_settings;
pub const overworld_biomes: []const BiomeParameters = &generated.overworld_biomes;

pub const FunctionId = u16;
pub const SplineId = u16;
pub const NoiseId = u8;
pub const RuleId = u16;
pub const ConditionId = u16;
pub const BiomeId = u8;

pub const NamedNoise = struct {
    id: []const u8,
    parameters: noise.Parameters,
};

pub const NamedFunction = struct {
    id: []const u8,
    function: FunctionId,
};

pub const Axis = enum { x, y, z };
pub const Tiling = enum { clamp_to_edge, repeat, mirrored_repeat };
pub const Unary = enum { abs, square, cube, sqrt, half_negative, quarter_negative, reciprocal, negate, squeeze, log, sign };
pub const Binary = enum { add, sub, mul, div, min, max };

/// A worldgen/density_function, like it is in the files (nothing's inlined or optimized yet).
pub const DensityFunction = union(enum) {
    constant: f32,
    /// Index into `named_functions`.
    reference: u16,
    unary: struct { op: Unary, input: FunctionId },
    binary: struct { op: Binary, left: FunctionId, right: FunctionId },
    clamp: struct { input: FunctionId, min: f32, max: f32 },
    lerp: struct { alpha: FunctionId, first: FunctionId, second: FunctionId },
    range_choice: struct {
        input: FunctionId,
        min_inclusive: f32,
        max_exclusive: f32,
        when_in_range: FunctionId,
        when_out_of_range: FunctionId,
    },
    /// `functions[i]` when the input is below `thresholds[i]`, the last one otherwise.
    interval_select: struct { input: FunctionId, thresholds: []const f32, functions: []const FunctionId },
    cache: FunctionId,
    interpolated: struct { input: FunctionId, cell_size_xz: i32, cell_size_y: i32 },
    slice: struct { axis: Axis, coordinate: i32, input: FunctionId },
    find_top_surface: struct { density: FunctionId, upper_bound: FunctionId, lower_bound: i32, cell_height: i32 },
    blend_density: FunctionId,
    blend_alpha,
    blend_offset,
    beardifier,
    noise: struct {
        noise: NoiseId,
        xz_scale: f64,
        y_scale: f64,
        shift_x: FunctionId,
        shift_y: FunctionId,
        shift_z: FunctionId,
    },
    shift_a: NoiseId,
    shift_b: NoiseId,
    shift: NoiseId,
    gradient: struct {
        axis: Axis,
        tiling: Tiling,
        from_coordinate: i32,
        to_coordinate: i32,
        from_value: f32,
        to_value: f32,
    },
    spline: SplineId,
    old_blended_noise: struct {
        xz_scale: f64,
        y_scale: f64,
        xz_factor: f64,
        y_factor: f64,
        smear_scale_multiplier: f64,
    },
    /// A type that isn't implemented, the name is the file's.
    unsupported: []const u8,
};

pub const Spline = union(enum) {
    constant: f32,
    multipoint: struct {
        coordinate: FunctionId,
        locations: []const f32,
        values: []const SplineId,
        derivatives: []const f32,
    },
};

pub const Anchor = union(enum) {
    absolute: i32,
    above_bottom: i32,
    below_top: i32,

    pub fn resolve(self: Anchor, min_y: i32, height: i32) i32 {
        return switch (self) {
            .absolute => |y| y,
            .above_bottom => |offset| min_y + offset,
            .below_top => |offset| height - 1 + min_y - offset,
        };
    }
};

/// A worldgen/material_rule, the block states are block names (their default state).
pub const Rule = union(enum) {
    block: []const u8,
    bandlands,
    sequence: []const RuleId,
    condition: struct { if_true: ConditionId, then_run: RuleId },
    ore_vein: struct {
        ore_block: []const u8,
        raw_ore_block: []const u8,
        filler_block: []const u8,
        raw_ore_chance: f32,
        density: FunctionId,
        richness: FunctionId,
        filler_gap: FunctionId,
    },
};

/// A worldgen/material_condition
pub const Condition = union(enum) {
    biome: []const BiomeId,
    noise_threshold: struct { noise: NoiseId, min: f64, max: f64, is_3d: bool },
    vertical_gradient: struct { random_name: []const u8, true_at_and_below: Anchor, false_at_and_above: Anchor },
    y_above: struct { anchor: Anchor, surface_depth_multiplier: i32, add_stone_depth: bool },
    water: struct { offset: i32, surface_depth_multiplier: i32, add_stone_depth: bool },
    stone_depth: struct {
        offset: i32,
        add_surface_depth: bool,
        secondary_depth_range: i32,
        surface_type: enum { floor, ceiling },
    },
    not: ConditionId,
    temperature,
    steep,
    hole,
    above_preliminary_surface,
};

pub const Biome = struct {
    id: []const u8,
    temperature: f32,
    /// The `frozen` temperature modifier.
    frozen: bool,
};

/// A worldgen/noise_settings
pub const NoiseSettings = struct {
    id: []const u8,
    min_y: i32,
    height: i32,
    sea_level: i32,
    default_block: []const u8,
    default_fluid: []const u8,
    legacy_random_source: bool,
    temperature: FunctionId,
    vegetation: FunctionId,
    continents: FunctionId,
    erosion: FunctionId,
    depth: FunctionId,
    ridges: FunctionId,
    chunk_surface_level: FunctionId,
    final_density: FunctionId,
    material_rule: RuleId,
};

/// Where a biome generates: `{ min, max }` of temperature, humidity, continentalness, erosion,
/// depth, weirdness and the offset, all times 10000.
pub const BiomeParameters = struct {
    biome: BiomeId,
    parameters: [7][2]i32,
};

pub fn noiseByName(id: []const u8) ?NoiseId {
    for (noises, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return @intCast(i);
    }
    return null;
}

pub fn settingsByName(id: []const u8) ?*const NoiseSettings {
    for (noise_settings) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

test "generated data" {
    try std.testing.expect(noiseByName("minecraft:temperature") != null);
    const overworld = settingsByName("minecraft:overworld").?;
    try std.testing.expectEqual(-64, overworld.min_y);
    try std.testing.expectEqual(384, overworld.height);
    try std.testing.expectEqual(63, overworld.sea_level);
    try std.testing.expectEqualStrings("minecraft:stone", overworld.default_block);
    try std.testing.expectEqual(7594, overworld_biomes.len);
    // Nothing the overworld uses is missing
    for (named_functions) |named| {
        if (!std.mem.startsWith(u8, named.id, "minecraft:overworld/")) continue;
        try std.testing.expect(functions[named.function] != .unsupported);
    }
}
