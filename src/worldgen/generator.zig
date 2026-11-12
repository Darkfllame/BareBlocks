//! Generates chunks: biomes first, then the terrain (vanilla's `NoiseBasedChunkGenerator`).
//!
//! No aquifers yet (everything under the sea level that isn't solid is water, lava under -54),
//! no carvers, structures or features.
const std = @import("std");
const blocks = @import("blocks.zig");
const climate = @import("climate.zig");
const data = @import("data.zig");
const density = @import("density.zig");
const surface = @import("surface.zig");
const Chunk = @import("Chunk.zig");
const RandomState = @import("RandomState.zig");
const Volume = @import("Volume.zig");

const Allocator = std.mem.Allocator;

/// The chunks around the one being generated, `[z + 1][x + 1]` from it. Only their biomes are read:
/// the biome of a block can come from the chunk next to it.
pub const Neighbors = [3][3]*const Chunk;

/// Fills `chunk.biomes`, see `climate.ParameterList.Search`.
pub fn generateBiomes(state: *const RandomState, gpa: Allocator, chunk: *Chunk, search: *climate.ParameterList.Search) Allocator.Error!void {
    var ctx: density.Context = .init(gpa, true);
    defer ctx.deinit();

    const volume: Volume = .{
        .size_x = 4,
        .size_y = @divExact(chunk.height, 4),
        .size_z = 4,
        .min_x = chunk.x * 16,
        .min_y = chunk.min_y,
        .min_z = chunk.z * 16,
        .step_x = 4,
        .step_y = 4,
        .step_z = 4,
    };
    var buffers: [6][]f32 = undefined;
    var acquired: usize = 0;
    defer for (buffers[0..acquired]) |b| ctx.release(b);
    for (&buffers, [_]*const density.Sampler{ state.temperature, state.vegetation, state.continents, state.erosion, state.depth, state.ridges }) |*buffer, sampler| {
        buffer.* = try ctx.acquire(volume);
        acquired += 1;
        try sampler.sampleVolume(&ctx, buffer.*, volume);
    }

    // Section by section, the order matters for `search`
    var section_y = chunk.min_y >> 4;
    while (section_y < (chunk.min_y + chunk.height) >> 4) : (section_y += 1) {
        var x: i32 = 0;
        while (x < 4) : (x += 1) {
            var y: i32 = 0;
            while (y < 4) : (y += 1) {
                var z: i32 = 0;
                while (z < 4) : (z += 1) {
                    const quart_y = section_y * 4 + y;
                    const i = volume.index(x, quart_y - (chunk.min_y >> 2), z);
                    const target = climate.target(buffers[0][i], buffers[1][i], buffers[2][i], buffers[3][i], buffers[4][i], buffers[5][i]);
                    chunk.biomes[chunk.biomeIndex(x, quart_y, z)] = state.biomes.find(target, search);
                }
            }
        }
    }
}

/// Fills `chunk.states`, the chunk and the ones around it need their biomes.
pub fn buildTerrain(state: *const RandomState, gpa: Allocator, chunk: *Chunk, neighbors: Neighbors) Allocator.Error!void {
    var ctx: density.Context = .init(gpa, true);
    defer ctx.deinit();

    try fill(state, &ctx, chunk);
    try surface.build(state, &ctx, gpa, chunk, neighbors);
}

/// The shape of the terrain: the default block where the density is above 0 (`doFill`).
pub fn fill(state: *const RandomState, ctx: *density.Context, chunk: *Chunk) Allocator.Error!void {
    const volume: Volume = .{ .size_x = 16, .size_y = chunk.height, .size_z = 16, .min_x = chunk.x * 16, .min_y = chunk.min_y, .min_z = chunk.z * 16 };
    const densities = try ctx.acquire(volume);
    defer ctx.release(densities);
    try state.final_density.sampleVolume(ctx, densities, volume);

    const sea_level = state.settings.sea_level;
    const lava_level = @min(-54, sea_level);
    var z: i32 = 0;
    while (z < 16) : (z += 1) {
        var x: i32 = 0;
        while (x < 16) : (x += 1) {
            var y = chunk.height - 1;
            while (y >= 0) : (y -= 1) {
                const block_y = chunk.min_y + y;
                const block = if (densities[volume.index(x, y, z)] > 0.0)
                    state.default_block
                else if (block_y < lava_level)
                    blocks.lava
                else if (block_y < sea_level)
                    state.default_fluid
                else
                    continue;
                chunk.set(x, block_y, z, block);
            }
        }
    }
}

test "same chunks as vanilla" {
    const gpa = std.testing.allocator;
    const state = try RandomState.create(gpa, 12345, data.settingsByName("minecraft:overworld").?);
    defer state.destroy();

    // crc32 of the block states and of the biomes a 26.3 server generates with seed 12345 (without
    // aquifers), for an ocean, eroded badlands (pillars) and a frozen ocean (icebergs)
    const cases = [_]struct { x: i32, z: i32, states: u32, biomes: u32 }{
        .{ .x = 0, .z = 0, .states = 0x5b4e807c, .biomes = 0xff470ee0 },
        .{ .x = -312, .z = -276, .states = 0x412984c1, .biomes = 0x499a7457 },
        .{ .x = 60, .z = 48, .states = 0xee10e4c1, .biomes = 0xd974a851 },
    };
    for (cases) |case| {
        var chunks: [9]Chunk = undefined;
        var initialized: usize = 0;
        defer for (chunks[0..initialized]) |*chunk| chunk.deinit(gpa);

        // A search of its own for each chunk: vanilla's is per thread, the biomes can't depend on it
        var neighbors: Neighbors = undefined;
        for (&chunks, 0..) |*chunk, i| {
            const dx: i32 = @intCast(i % 3);
            const dz: i32 = @intCast(i / 3);
            chunk.* = try .init(gpa, case.x + dx - 1, case.z + dz - 1, state.settings.min_y, state.settings.height);
            initialized += 1;
            var search: climate.ParameterList.Search = .{};
            try generateBiomes(state, gpa, chunk, &search);
            neighbors[i / 3][i % 3] = chunk;
        }
        const chunk = &chunks[4];
        try buildTerrain(state, gpa, chunk, neighbors);

        try std.testing.expectEqual(case.biomes, std.hash.Crc32.hash(chunk.biomes));
        var crc: std.hash.Crc32 = .init();
        for (chunk.states) |s| crc.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, s)));
        try std.testing.expectEqual(case.states, crc.final());
    }
}
