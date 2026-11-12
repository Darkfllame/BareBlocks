//! A chunk being generated: its blocks, biomes and surface heights.
const Chunk = @This();
const std = @import("std");
const blocks = @import("blocks.zig");
const data = @import("data.zig");

const Allocator = std.mem.Allocator;
const StateId = blocks.StateId;

x: i32,
z: i32,
min_y: i32,
height: i32,
/// `y + (x + z * 16) * height`, like a `Volume` of the chunk.
states: []StateId,
/// One per 4x4x4 blocks, `y + (x + z * 4) * (height / 4)`.
biomes: []data.BiomeId,
/// The y above the highest block that isn't air (`WORLD_SURFACE_WG` + 1), `x + z * 16`.
surface: [256]i32,

pub fn init(gpa: Allocator, x: i32, z: i32, min_y: i32, height: i32) Allocator.Error!Chunk {
    const states = try gpa.alloc(StateId, @intCast(16 * 16 * height));
    errdefer gpa.free(states);
    const biomes = try gpa.alloc(data.BiomeId, @intCast(4 * 4 * @divExact(height, 4)));
    @memset(states, blocks.air);
    @memset(biomes, 0);
    return .{ .x = x, .z = z, .min_y = min_y, .height = height, .states = states, .biomes = biomes, .surface = @splat(min_y) };
}

pub fn deinit(self: *Chunk, gpa: Allocator) void {
    gpa.free(self.states);
    gpa.free(self.biomes);
    self.* = undefined;
}

fn index(self: *const Chunk, x: i32, y: i32, z: i32) usize {
    return @intCast((y - self.min_y) + (x + z * 16) * self.height);
}

/// Local x and z, world y. Air outside of the build height.
pub fn get(self: *const Chunk, x: i32, y: i32, z: i32) StateId {
    if (y < self.min_y or y >= self.min_y + self.height) return blocks.air;
    return self.states[self.index(x, y, z)];
}

/// Local x and z, world y. Keeps `surface` up to date like vanilla's heightmap.
pub fn set(self: *Chunk, x: i32, y: i32, z: i32, state: StateId) void {
    if (y < self.min_y or y >= self.min_y + self.height) return;
    self.states[self.index(x, y, z)] = state;

    const first_available = &self.surface[@intCast(x + z * 16)];
    if (y <= first_available.* - 2) return;
    if (!blocks.isAir(state)) {
        if (y >= first_available.*) first_available.* = y + 1;
    } else if (first_available.* - 1 == y) {
        var below = y - 1;
        first_available.* = while (below >= self.min_y) : (below -= 1) {
            if (!blocks.isAir(self.states[self.index(x, below, z)])) break below + 1;
        } else self.min_y;
    }
}

/// The y of the top of the highest 16 blocks tall section that isn't only air, `null` if they all are.
pub fn highestFilledSectionTop(self: *const Chunk) ?i32 {
    var top = self.min_y + self.height - 1;
    while (top >= self.min_y) : (top -= 16) {
        var z: i32 = 0;
        while (z < 16) : (z += 1) {
            var x: i32 = 0;
            while (x < 16) : (x += 1) {
                const column = self.states[self.index(x, top - 15, z)..][0..16];
                for (column) |state| {
                    if (!blocks.isAir(state)) return top;
                }
            }
        }
    }
    return null;
}

pub fn biomeIndex(self: *const Chunk, quart_x: i32, quart_y: i32, quart_z: i32) usize {
    const quart_height = @divExact(self.height, 4);
    return @intCast((quart_y - (self.min_y >> 2)) + ((quart_x & 3) + (quart_z & 3) * 4) * quart_height);
}

/// World quart coordinates (blocks / 4), y is clamped to the chunk like vanilla does.
pub fn biome(self: *const Chunk, quart_x: i32, quart_y: i32, quart_z: i32) data.BiomeId {
    const min = self.min_y >> 2;
    const clamped = std.math.clamp(quart_y, min, min + @divExact(self.height, 4) - 1);
    return self.biomes[self.biomeIndex(quart_x, clamped, quart_z)];
}
