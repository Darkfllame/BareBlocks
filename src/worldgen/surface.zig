//! Replaces the stone of a filled chunk with what the material rules say (vanilla's `MaterialSystem`):
//! grass, dirt, sand, deepslate, bedrock, the ore veins...
const std = @import("std");
const math = @import("math");
const blocks = @import("blocks.zig");
const climate = @import("climate.zig");
const data = @import("data.zig");
const density = @import("density.zig");
const java = @import("java.zig");
const generator = @import("generator.zig");
const noise = @import("noise.zig");
const Chunk = @import("Chunk.zig");
const RandomState = @import("RandomState.zig");
const Volume = @import("Volume.zig");

const Allocator = std.mem.Allocator;
const StateId = blocks.StateId;

const min_int = std.math.minInt(i32);
/// `DimensionType.WAY_BELOW_MIN_Y`: no stone under the block.
const way_below_min_y = -2032 << 4;

fn biomeId(comptime name: []const u8) data.BiomeId {
    @setEvalBranchQuota(100_000);
    return comptime for (data.biomes, 0..) |biome, i| {
        if (std.mem.eql(u8, biome.id, name)) break @intCast(i);
    } else @compileError("no biome named " ++ name);
}

/// What the rules can ask about the block they're deciding (`MaterialRuleContext`).
const Context = struct {
    state: *const RandomState,
    ctx: *density.Context,
    chunk: *Chunk,
    neighbors: generator.Neighbors,
    /// Where the ore veins are sampled: the chunk up to its highest blocks.
    volume: Volume,
    veins: []Vein,
    /// The chunk's `chunk_surface_level`, sampled the first time a rule needs it.
    preliminary_surface: ?[256]f32 = null,

    block_x: i32 = 0,
    block_z: i32 = 0,
    gradient_x: i32 = 0,
    gradient_z: i32 = 0,
    surface_depth: i32 = 0,
    surface_secondary: ?f64 = null,
    min_surface_level: ?i32 = null,
    /// 2d noises of the column, by noise.
    noises_2d: []?f64,

    block_y: i32 = 0,
    water_height: i32 = min_int,
    stone_depth_below: i32 = 0,
    stone_depth_above: i32 = 0,
    biome: ?data.BiomeId = null,
    /// 3d noises of the block, by noise.
    noises_3d: []?f64,

    /// The densities of an ore vein rule over `volume`.
    const Vein = struct {
        rule: data.RuleId,
        density: []f32,
        richness: []f32,
    };

    fn updateXZ(self: *Context, block_x: i32, block_z: i32, gradient_x: i32, gradient_z: i32) void {
        self.block_x = block_x;
        self.block_z = block_z;
        self.gradient_x = gradient_x;
        self.gradient_z = gradient_z;
        self.surface_secondary = null;
        self.min_surface_level = null;
        @memset(self.noises_2d, null);
        @memset(self.noises_3d, null);
        self.biome = null;

        const noise_value: f64 = self.state.surface_noise.get(@floatFromInt(block_x), 0.0, @floatFromInt(block_z));
        var rand = self.state.positional.at(block_x, 0, block_z);
        self.surface_depth = java.toInt(noise_value * 2.75 + 3.0 + rand.nextDouble() * 0.25);
    }

    fn updateY(self: *Context, stone_depth_above: i32, stone_depth_below: i32, water_height: i32, block_y: i32) void {
        self.biome = null;
        @memset(self.noises_3d, null);
        self.block_y = block_y;
        self.water_height = water_height;
        self.stone_depth_below = stone_depth_below;
        self.stone_depth_above = stone_depth_above;
    }

    fn getBiome(self: *Context) data.BiomeId {
        if (self.biome == null) self.biome = biomeAt(self.state, self.chunk, self.neighbors, self.block_x, self.block_y, self.block_z);
        return self.biome.?;
    }

    fn surfaceSecondary(self: *Context) f64 {
        if (self.surface_secondary == null) {
            self.surface_secondary = self.state.surface_secondary_noise.get(@floatFromInt(self.block_x), 0.0, @floatFromInt(self.block_z));
        }
        return self.surface_secondary.?;
    }

    fn minSurfaceLevel(self: *Context) Allocator.Error!i32 {
        if (self.min_surface_level == null) {
            if (self.preliminary_surface == null) {
                self.preliminary_surface = @as([256]f32, undefined);
                const volume: Volume = .{ .size_x = 16, .size_y = 1, .size_z = 16, .min_x = self.volume.min_x, .min_y = 0, .min_z = self.volume.min_z };
                try self.state.chunk_surface_level.sampleVolume(self.ctx, &self.preliminary_surface.?, volume);
            }
            const level = self.preliminary_surface.?[@intCast((self.block_x - self.volume.min_x) + (self.block_z - self.volume.min_z) * 16)];
            self.min_surface_level = java.floor(level) +% self.surface_depth - 8;
        }
        return self.min_surface_level.?;
    }

    fn noiseValue(self: *Context, id: data.NoiseId, is_3d: bool) f64 {
        const cache = if (is_3d) &self.noises_3d[id] else &self.noises_2d[id];
        if (cache.* == null) {
            const y: f64 = if (is_3d) @floatFromInt(self.block_y) else 0.0;
            cache.* = self.state.getNoise(id).get(@floatFromInt(self.block_x), y, @floatFromInt(self.block_z));
        }
        return cache.*.?;
    }

    fn anchor(self: *const Context, a: data.Anchor) i32 {
        return a.resolve(self.chunk.min_y, self.chunk.height);
    }

    fn testCondition(self: *Context, id: data.ConditionId) Allocator.Error!bool {
        switch (data.conditions[id]) {
            .biome => |biomes| return std.mem.indexOfScalar(data.BiomeId, biomes, self.getBiome()) != null,
            .noise_threshold => |c| {
                const value = self.noiseValue(c.noise, c.is_3d);
                return value >= c.min and value <= c.max;
            },
            .vertical_gradient => |c| {
                const true_at_and_below = self.anchor(c.true_at_and_below);
                const false_at_and_above = self.anchor(c.false_at_and_above);
                if (self.block_y <= true_at_and_below) return true;
                if (self.block_y >= false_at_and_above) return false;
                const from: f64 = @floatFromInt(true_at_and_below);
                const to: f64 = @floatFromInt(false_at_and_above);
                const probability = math.lm.lerp(f64, 1.0, 0.0, (@as(f64, @floatFromInt(self.block_y)) - from) / (to - from));
                var rand = self.state.gradient_randoms[id].?.at(self.block_x, self.block_y, self.block_z);
                return @as(f64, rand.nextFloat()) < probability;
            },
            .y_above => |c| {
                const y = self.block_y + if (c.add_stone_depth) self.stone_depth_above else 0;
                return y >= self.anchor(c.anchor) + self.surface_depth * c.surface_depth_multiplier;
            },
            .water => |c| {
                if (self.water_height == min_int) return true;
                const y = self.block_y + if (c.add_stone_depth) self.stone_depth_above else 0;
                return y >= self.water_height + c.offset + self.surface_depth * c.surface_depth_multiplier;
            },
            .stone_depth => |c| {
                const stone_depth = if (c.surface_type == .ceiling) self.stone_depth_below else self.stone_depth_above;
                const surface_depth = if (c.add_surface_depth) self.surface_depth else 0;
                const secondary = if (c.secondary_depth_range == 0)
                    0
                else
                    java.toInt(math.lm.lerp(f64, 0.0, @floatFromInt(c.secondary_depth_range), (self.surfaceSecondary() - -1.0) / (1.0 - -1.0)));
                return stone_depth <= 1 + c.offset + surface_depth + secondary;
            },
            .not => |inverted| return !try self.testCondition(inverted),
            .temperature => return !(self.state.biomeTemperature(self.getBiome(), self.block_x, self.block_y, self.block_z) >= 0.15),
            .steep => return self.gradient_x <= -4 or self.gradient_z >= 4,
            .hole => return self.surface_depth <= 0,
            .above_preliminary_surface => return self.block_y >= try self.minSurfaceLevel(),
        }
    }

    /// The block a rule gives for the current block, `null` if it has nothing to say.
    fn applyRule(self: *Context, id: data.RuleId) Allocator.Error!?StateId {
        switch (data.rules[id]) {
            .block => return self.state.rules[id].block,
            .bandlands => return self.band(),
            .sequence => |sequence| {
                for (sequence) |rule| {
                    if (try self.applyRule(rule)) |state| return state;
                }
                return null;
            },
            .condition => |c| {
                if (!try self.testCondition(c.if_true)) return null;
                return self.applyRule(c.then_run);
            },
            .ore_vein => |vein| {
                const rule = self.state.rules[id].ore_vein;
                const prefilled = for (self.veins) |*v| {
                    if (v.rule == id) break v;
                } else unreachable;
                const index = self.volume.indexOfBlock(self.block_x, self.block_y, self.block_z);

                const vein_density = if (index) |i| prefilled.density[i] else try rule.density.sampleValue(self.ctx, self.block_x, self.block_y, self.block_z);
                if (vein_density <= 0.0) return null;
                var rand = self.state.ore_random.at(self.block_x, self.block_y, self.block_z);
                if (rand.nextFloat() > vein_density) return null;

                const richness = if (index) |i| prefilled.richness[i] else try rule.richness.sampleValue(self.ctx, self.block_x, self.block_y, self.block_z);
                if (rand.nextFloat() < richness and try rule.filler_gap.sampleValue(self.ctx, self.block_x, self.block_y, self.block_z) < 0.0) {
                    return if (rand.nextFloat() < vein.raw_ore_chance) rule.raw_ore_block else rule.ore_block;
                }
                return rule.filler_block;
            },
        }
    }

    /// The terracotta of badlands at the current block.
    fn band(self: *Context) StateId {
        const bands = &self.state.clay_bands;
        const offset_noise = self.state.clay_bands_offset_noise.get(@floatFromInt(self.block_x), 0.0, @floatFromInt(self.block_z)) * 4.0;
        // Math.round
        const offset = java.toInt(@floor(@as(f64, offset_noise) + 0.5));
        const len: i32 = @intCast(bands.len);
        return bands[@intCast(@rem(self.block_y + offset + len, len))];
    }

    /// The ore vein rules sample their densities once for the whole chunk, in the order vanilla
    /// compiles the rules.
    fn prepareVeins(self: *Context, gpa: Allocator, veins: *std.ArrayList(Vein), id: data.RuleId) Allocator.Error!void {
        switch (data.rules[id]) {
            .block, .bandlands => {},
            .sequence => |sequence| for (sequence) |rule| try self.prepareVeins(gpa, veins, rule),
            .condition => |c| try self.prepareVeins(gpa, veins, c.then_run),
            .ore_vein => {
                const rule = self.state.rules[id].ore_vein;
                const vein_density = try gpa.alloc(f32, self.volume.size());
                errdefer gpa.free(vein_density);
                try rule.density.sampleVolume(self.ctx, vein_density, self.volume);
                const richness = try gpa.alloc(f32, self.volume.size());
                errdefer gpa.free(richness);
                try rule.richness.sampleVolume(self.ctx, richness, self.volume);
                try veins.append(gpa, .{ .rule = id, .density = vein_density, .richness = richness });
            },
        }
    }
};

/// The biome of a block: its quart's, or one next to it (`BiomeManager.getBiome`).
pub fn biomeAt(state: *const RandomState, chunk: *const Chunk, neighbors: generator.Neighbors, x: i32, y: i32, z: i32) data.BiomeId {
    const quart = climate.zoom(state.zoom_seed, x, y, z);
    const dx = (quart[0] >> 2) - chunk.x;
    const dz = (quart[2] >> 2) - chunk.z;
    return neighbors[@intCast(dz + 1)][@intCast(dx + 1)].biome(quart[0], quart[1], quart[2]);
}

fn isStone(state: StateId) bool {
    return !blocks.isAir(state) and !blocks.isFluid(state);
}

fn height(chunk: *const Chunk, x: i32, z: i32) i32 {
    return chunk.surface[@intCast(x + z * 16)] - 1;
}

pub fn build(state: *const RandomState, ctx: *density.Context, gpa: Allocator, chunk: *Chunk, neighbors: generator.Neighbors) Allocator.Error!void {
    const min_y = chunk.min_y;
    const max_y = chunk.min_y + chunk.height - 1;
    const min_block_x = chunk.x * 16;
    const min_block_z = chunk.z * 16;

    const max_block_y = chunk.highestFilledSectionTop() orelse min_y - 1;
    const noises = try gpa.alloc(?f64, data.noises.len * 2);
    defer gpa.free(noises);
    var veins: std.ArrayList(Context.Vein) = .empty;
    defer {
        for (veins.items) |vein| {
            gpa.free(vein.density);
            gpa.free(vein.richness);
        }
        veins.deinit(gpa);
    }
    var context: Context = .{
        .state = state,
        .ctx = ctx,
        .chunk = chunk,
        .neighbors = neighbors,
        .volume = .{
            .size_x = 16,
            .size_y = @max(max_block_y - min_y + 1, 1),
            .size_z = 16,
            .min_x = min_block_x,
            .min_y = min_y,
            .min_z = min_block_z,
        },
        .veins = &.{},
        .noises_2d = noises[0..data.noises.len],
        .noises_3d = noises[data.noises.len..],
    };
    const root = state.settings.material_rule;
    try context.prepareVeins(gpa, &veins, root);
    context.veins = veins.items;

    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            const block_x = min_block_x + x;
            const block_z = min_block_z + z;
            const starting_height = height(chunk, x, z) + 1;
            const surface_biome = biomeAt(state, chunk, neighbors, block_x, starting_height, block_z);
            if (surface_biome == biomeId("minecraft:eroded_badlands")) erodedBadlandsExtension(state, chunk, x, z, starting_height);

            const column_height = height(chunk, x, z) + 1;
            context.updateXZ(
                block_x,
                block_z,
                height(chunk, @min(x + 1, 15), z) - height(chunk, @max(x - 1, 0), z),
                height(chunk, x, @min(z + 1, 15)) - height(chunk, x, @max(z - 1, 0)),
            );
            var stone_above_depth: i32 = 0;
            var water_height: i32 = min_int;
            var next_ceiling_stone_y: i32 = std.math.maxInt(i32);
            var y = column_height;
            while (y >= min_y) : (y -= 1) {
                const old = chunk.get(x, y, z);
                if (blocks.isAir(old)) {
                    stone_above_depth = 0;
                    water_height = min_int;
                    continue;
                }
                if (blocks.isFluid(old)) {
                    if (water_height == min_int) water_height = y + 1;
                    continue;
                }
                if (next_ceiling_stone_y >= y) {
                    next_ceiling_stone_y = way_below_min_y;
                    var lookahead = y - 1;
                    while (lookahead >= min_y - 1) : (lookahead -= 1) {
                        if (isStone(chunk.get(x, lookahead, z))) continue;
                        next_ceiling_stone_y = lookahead + 1;
                        break;
                    }
                }
                stone_above_depth += 1;
                context.updateY(stone_above_depth, y - next_ceiling_stone_y + 1, water_height, y);
                if (y > max_y) continue;
                if (try context.applyRule(root)) |new| chunk.set(x, y, z, new);
            }

            if (surface_biome == biomeId("minecraft:frozen_ocean") or surface_biome == biomeId("minecraft:deep_frozen_ocean")) {
                try frozenOceanExtension(state, chunk, try context.minSurfaceLevel(), surface_biome, x, z, starting_height);
            }
        }
    }
}

/// The stone pillars of eroded badlands.
fn erodedBadlandsExtension(state: *const RandomState, chunk: *Chunk, x: i32, z: i32, column_height: i32) void {
    const block_x: f64 = @floatFromInt(chunk.x * 16 + x);
    const block_z: f64 = @floatFromInt(chunk.z * 16 + z);
    const pillar_buffer = java.javaMin(
        f64,
        @abs(@as(f64, state.badlands_surface_noise.get(block_x, 0.0, block_z)) * 8.25),
        state.badlands_pillar_noise.get(block_x * 0.2, 0.0, block_z * 0.2) * 15.0,
    );
    if (pillar_buffer <= 0.0) return;

    const pillar_floor = @abs(@as(f64, state.badlands_pillar_roof_noise.get(block_x * 0.75, 0.0, block_z * 0.75)) * 1.5);
    const extension_top = 64.0 + java.javaMin(f64, pillar_buffer * pillar_buffer * 2.5, @ceil(pillar_floor * 50.0) + 24.0);
    const start_y = java.floor(extension_top);
    if (column_height > start_y) return;

    var y = start_y;
    while (y >= chunk.min_y) : (y -= 1) {
        const old = chunk.get(x, y, z);
        if (blocks.isStoneBlock(old)) break;
        if (blocks.isWater(old)) return;
    }
    y = start_y;
    while (y >= chunk.min_y and blocks.isAir(chunk.get(x, y, z))) : (y -= 1) chunk.set(x, y, z, state.default_block);
}

/// The icebergs of frozen oceans.
fn frozenOceanExtension(state: *const RandomState, chunk: *Chunk, min_surface_level: i32, biome: data.BiomeId, x: i32, z: i32, column_height: i32) Allocator.Error!void {
    const sea_level = state.settings.sea_level;
    const world_x = chunk.x * 16 + x;
    const world_z = chunk.z * 16 + z;
    const block_x: f64 = @floatFromInt(world_x);
    const block_z: f64 = @floatFromInt(world_z);
    const iceberg = java.javaMin(
        f64,
        @abs(@as(f64, state.iceberg_surface_noise.get(block_x, 0.0, block_z)) * 8.25),
        state.iceberg_pillar_noise.get(block_x * 1.28, 0.0, block_z * 1.28) * 15.0,
    );
    if (iceberg <= 1.8) return;

    const iceberg_roof = @abs(@as(f64, state.iceberg_pillar_roof_noise.get(block_x * 1.17, 0.0, block_z * 1.17)) * 1.5);
    var top = java.javaMin(f64, iceberg * iceberg * 1.2, @ceil(iceberg_roof * 40.0) + 14.0);
    // Melts a bit where it's warm
    if (state.biomeTemperature(biome, world_x, sea_level, world_z) > 0.1) top -= 2.0;
    if (top <= 2.0) return;

    const extension_bottom = @as(f64, @floatFromInt(sea_level)) - top - 7.0;
    top += @floatFromInt(sea_level);
    const top_y = java.toInt(top);
    const bottom_y = java.toInt(extension_bottom);

    var rand = state.positional.at(world_x, 0, world_z);
    const max_snow_depth = 2 + rand.nextInt(4);
    const min_snow_height = sea_level + 18 + @as(i32, @intCast(rand.nextInt(10)));
    var snow_depth: u32 = 0;
    var y = @max(column_height, top_y + 1);
    while (y >= min_surface_level) : (y -= 1) {
        const old = chunk.get(x, y, z);
        const in_air = blocks.isAir(old) and y < top_y and rand.nextDouble() > 0.01;
        if (!in_air) {
            if (!blocks.isWater(old) or y <= bottom_y or y >= sea_level or !(rand.nextDouble() > 0.15)) continue;
        }
        if (snow_depth <= max_snow_depth and y > min_snow_height) {
            chunk.set(x, y, z, blocks.snow_block);
            snow_depth += 1;
        } else {
            chunk.set(x, y, z, blocks.packed_ice);
        }
    }
}
