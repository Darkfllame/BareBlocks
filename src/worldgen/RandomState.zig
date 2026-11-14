//! Everything a world's generation gets from its seed (vanilla's `RandomState` and `MaterialSystem`):
//! the noises, the compiled density functions and the randoms of the material rules.
//!
//! All of it is made by `create`, generating chunks only reads it.
const RandomState = @This();
const std = @import("std");
const blocks = @import("blocks.zig");
const climate = @import("climate.zig");
const data = @import("data.zig");
const density = @import("density.zig");
const noise = @import("noise.zig");
const random = @import("random.zig");
const Compiler = @import("compiler.zig");

const Allocator = std.mem.Allocator;
const Sampler = density.Sampler;
const StateId = blocks.StateId;

pub const Error = Compiler.Error || error{UnknownBlock};

arena: std.heap.ArenaAllocator,
seed: i64,
settings: *const data.NoiseSettings,
/// `RandomState.random`
positional: random.Positional,
compiler: Compiler,

temperature: *const Sampler,
vegetation: *const Sampler,
continents: *const Sampler,
erosion: *const Sampler,
depth: *const Sampler,
ridges: *const Sampler,
chunk_surface_level: *const Sampler,
final_density: *const Sampler,

biomes: climate.ParameterList,
zoom_seed: i64,

default_block: StateId,
default_fluid: StateId,
/// What `data.rules` are in block states, by rule.
rules: []const Rule,
/// The random of `vertical_gradient` conditions, by condition.
gradient_randoms: []const ?random.Positional,
ore_random: random.Positional,

surface_noise: *const noise.Noise,
surface_secondary_noise: *const noise.Noise,
clay_bands_offset_noise: *const noise.Noise,
badlands_pillar_noise: *const noise.Noise,
badlands_pillar_roof_noise: *const noise.Noise,
badlands_surface_noise: *const noise.Noise,
iceberg_pillar_noise: *const noise.Noise,
iceberg_pillar_roof_noise: *const noise.Noise,
iceberg_surface_noise: *const noise.Noise,
/// The terracotta of badlands by y, repeats.
clay_bands: [192]StateId,

/// Biomes' temperature noises, the same for every seed.
temperature_noise: noise.Simplex,
frozen_temperature_noise: [3]noise.Simplex,
biome_info_noise: noise.Simplex,

pub const Rule = union(enum) {
    none,
    block: StateId,
    ore_vein: struct {
        ore_block: StateId,
        raw_ore_block: StateId,
        filler_block: StateId,
        density: *const Sampler,
        richness: *const Sampler,
        filler_gap: *const Sampler,
    },
};

fn block(name: []const u8) error{UnknownBlock}!StateId {
    return blocks.find(name) orelse error.UnknownBlock;
}

pub fn create(gpa: Allocator, seed: i64, settings: *const data.NoiseSettings) Error!*RandomState {
    const self = try gpa.create(RandomState);
    errdefer gpa.destroy(self);
    self.arena = .init(gpa);
    errdefer self.arena.deinit();
    const arena = self.arena.allocator();

    // Only the overworld's for now, the others use the legacy random
    std.debug.assert(!settings.legacy_random_source);
    var world_random: random.Xoroshiro = .init(@bitCast(seed));
    self.seed = seed;
    self.settings = settings;
    self.positional = random.forkPositional(&world_random);
    self.compiler = try .init(arena, self.positional);

    self.temperature = try self.compiler.getSampler(settings.temperature);
    self.vegetation = try self.compiler.getSampler(settings.vegetation);
    self.continents = try self.compiler.getSampler(settings.continents);
    self.erosion = try self.compiler.getSampler(settings.erosion);
    self.depth = try self.compiler.getSampler(settings.depth);
    self.ridges = try self.compiler.getSampler(settings.ridges);
    self.chunk_surface_level = try self.compiler.getSampler(settings.chunk_surface_level);
    self.final_density = try self.compiler.getSampler(settings.final_density);

    self.biomes = try .init(arena, data.overworld_biomes);
    self.zoom_seed = climate.obfuscateSeed(seed);

    self.default_block = try block(settings.default_block);
    self.default_fluid = try block(settings.default_fluid);

    const rules = try arena.alloc(Rule, data.rules.len);
    for (rules, data.rules) |*out, rule| {
        out.* = switch (rule) {
            .block => |name| .{ .block = try block(name) },
            .ore_vein => |vein| .{ .ore_vein = .{
                .ore_block = try block(vein.ore_block),
                .raw_ore_block = try block(vein.raw_ore_block),
                .filler_block = try block(vein.filler_block),
                .density = try self.compiler.getSampler(vein.density),
                .richness = try self.compiler.getSampler(vein.richness),
                .filler_gap = try self.compiler.getSampler(vein.filler_gap),
            } },
            .bandlands, .sequence, .condition => .none,
        };
    }
    self.rules = rules;

    const gradient_randoms = try arena.alloc(?random.Positional, data.conditions.len);
    for (gradient_randoms, data.conditions) |*out, condition| {
        out.* = switch (condition) {
            .vertical_gradient => |gradient| self.randomFactory(gradient.random_name),
            .noise_threshold => |threshold| blk: {
                _ = try self.compiler.getNoise(threshold.noise);
                break :blk null;
            },
            else => null,
        };
    }
    self.gradient_randoms = gradient_randoms;
    self.ore_random = self.randomFactory("minecraft:ore");

    self.surface_noise = try self.namedNoise("minecraft:surface");
    self.surface_secondary_noise = try self.namedNoise("minecraft:surface_secondary");
    self.clay_bands_offset_noise = try self.namedNoise("minecraft:clay_bands_offset");
    self.badlands_pillar_noise = try self.namedNoise("minecraft:badlands_pillar");
    self.badlands_pillar_roof_noise = try self.namedNoise("minecraft:badlands_pillar_roof");
    self.badlands_surface_noise = try self.namedNoise("minecraft:badlands_surface");
    self.iceberg_pillar_noise = try self.namedNoise("minecraft:iceberg_pillar");
    self.iceberg_pillar_roof_noise = try self.namedNoise("minecraft:iceberg_pillar_roof");
    self.iceberg_surface_noise = try self.namedNoise("minecraft:iceberg_surface");

    var bands_random = self.positional.fromHashOf("minecraft:clay_bands");
    self.clay_bands = try generateBands(&bands_random);

    var legacy: random.Legacy = .init(1234);
    self.temperature_noise = .init(&legacy);
    legacy = .init(3456);
    for (&self.frozen_temperature_noise) |*n| n.* = .init(&legacy);
    legacy = .init(2345);
    self.biome_info_noise = .init(&legacy);

    return self;
}

pub fn destroy(self: *RandomState) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    gpa.destroy(self);
}

/// `RandomState.getOrCreateRandomFactory`
fn randomFactory(self: *const RandomState, name: []const u8) random.Positional {
    var rand = self.positional.fromHashOf(name);
    return random.forkPositional(&rand);
}

fn namedNoise(self: *RandomState, id: []const u8) Allocator.Error!*const noise.Noise {
    return self.compiler.getNoise(data.noiseByName(id).?);
}

/// A noise of a material condition, `create` made all of them.
pub fn getNoise(self: *const RandomState, id: data.NoiseId) *const noise.Noise {
    return &self.compiler.noises[id].?;
}

fn makeBands(rand: *random.Xoroshiro, bands: *[192]StateId, base_width: u32, state: StateId) void {
    const count = rand.nextIntBetweenInclusive(6, 15);
    for (0..@intCast(count)) |_| {
        const width = base_width + rand.nextInt(3);
        const start = rand.nextInt(bands.len);
        var p: u32 = 0;
        while (start + p < bands.len and p < width) : (p += 1) bands[start + p] = state;
    }
}

/// `MaterialSystem.generateBands`
fn generateBands(rand: *random.Xoroshiro) error{UnknownBlock}![192]StateId {
    var bands: [192]StateId = @splat(try block("minecraft:terracotta"));
    const light_gray = try block("minecraft:light_gray_terracotta");

    var i: u32 = 0;
    while (i < bands.len) : (i += 1) {
        i += rand.nextInt(5) + 1;
        if (i < bands.len) bands[i] = try block("minecraft:orange_terracotta");
    }
    makeBands(rand, &bands, 1, try block("minecraft:yellow_terracotta"));
    makeBands(rand, &bands, 2, try block("minecraft:brown_terracotta"));
    makeBands(rand, &bands, 1, try block("minecraft:red_terracotta"));

    const white_count = rand.nextIntBetweenInclusive(9, 15);
    var start: u32 = 0;
    i = 0;
    while (i < @as(u32, @intCast(white_count)) and start < bands.len) : ({
        i += 1;
        start += rand.nextInt(16) + 4;
    }) {
        bands[start] = try block("minecraft:white_terracotta");
        if (start > 1 and rand.nextBoolean()) bands[start - 1] = light_gray;
        if (start + 1 < bands.len and rand.nextBoolean()) bands[start + 1] = light_gray;
    }
    return bands;
}

/// A biome's temperature at a block (`Biome.getHeightAdjustedTemperature`).
pub fn biomeTemperature(self: *const RandomState, biome: data.BiomeId, x: i32, y: i32, z: i32) f32 {
    const info = data.biomes[biome];
    var temperature = info.temperature;
    if (info.frozen) frozen: {
        const fx: f64 = @floatFromInt(x);
        const fz: f64 = @floatFromInt(z);
        var large: f32 = 0.0;
        for (self.frozen_temperature_noise, [_]f64{ 1.0, 0.5, 0.25 }, [_]f32{ 0.14285715, 0.2857143, 0.5714286 }) |n, frequency, amplitude| {
            large += amplitude * n.get(fx * 0.05 * frequency, fz * 0.05 * frequency);
        }
        const ice_patches = @as(f64, large * 7.0) + @as(f64, self.biome_info_noise.get(fx * 0.2, fz * 0.2));
        if (!(ice_patches < 0.3)) break :frozen;
        if (@as(f64, self.biome_info_noise.get(fx * 0.09, fz * 0.09)) < 0.8) temperature = 0.2;
    }

    const snow_level = self.settings.sea_level + 17;
    if (y > snow_level) {
        const v = self.temperature_noise.get(@as(f32, @floatFromInt(x)) / 8.0, @as(f32, @floatFromInt(z)) / 8.0) * 8.0;
        return temperature - (v + @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(snow_level))) * 0.05 / 40.0;
    }
    return temperature;
}
