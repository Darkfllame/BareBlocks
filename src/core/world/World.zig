//! The overworld. Chunks are generated the first time they're needed and kept in memory, already
//! encoded for the network.
const World = @This();
const std = @import("std");
const zio = @import("zio");
const worldgen = @import("worldgen");
const chunk_packet = @import("chunk_packet.zig");

const Allocator = std.mem.Allocator;
const Chunk = worldgen.Chunk;

pub const Error = worldgen.RandomState.Error;
pub const GetError = Allocator.Error || std.Io.Cancelable;

allocator: Allocator,
generation: *worldgen.RandomState,
mutex: zio.Mutex,
chunks: std.AutoHashMapUnmanaged(Position, *Entry),
biome_search: worldgen.climate.ParameterList.Search,

pub const Position = struct { x: i32, z: i32 };

const Entry = struct {
    /// Only its biomes once it's encoded.
    chunk: Chunk,
    /// What `net.packets.level_chunk_with_light_s2c` has after the coordinates.
    encoded: ?[]u8 = null,
    /// The first y without blocks above it, of the chunk's first column.
    surface: i32 = 0,
};

pub fn init(allocator: Allocator, seed: i64) Error!World {
    return .{
        .allocator = allocator,
        .generation = try .create(allocator, seed, worldgen.data.settingsByName("minecraft:overworld").?),
        .mutex = .init,
        .chunks = .empty,
        .biome_search = .{},
    };
}

pub fn deinit(self: *World) void {
    var it = self.chunks.valueIterator();
    while (it.next()) |entry| {
        entry.*.chunk.deinit(self.allocator);
        if (entry.*.encoded) |bytes| self.allocator.free(bytes);
        self.allocator.destroy(entry.*);
    }
    self.chunks.deinit(self.allocator);
    self.generation.destroy();
    self.* = undefined;
}

/// The chunk with its biomes, `mutex` must be locked.
fn biomes(self: *World, pos: Position) Allocator.Error!*Entry {
    const gop = try self.chunks.getOrPut(self.allocator, pos);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.chunks.remove(pos);

    const entry = try self.allocator.create(Entry);
    errdefer self.allocator.destroy(entry);
    const settings = self.generation.settings;
    entry.* = .{ .chunk = try .init(self.allocator, pos.x, pos.z, settings.min_y, settings.height) };
    errdefer entry.chunk.deinit(self.allocator);
    try worldgen.generator.generateBiomes(self.generation, self.allocator, &entry.chunk, &self.biome_search);

    gop.value_ptr.* = entry;
    return entry;
}

fn generated(self: *World, pos: Position) GetError!*const Entry {
    try self.mutex.lock();
    defer self.mutex.unlock();

    const entry = try self.biomes(pos);
    if (entry.encoded != null) return entry;

    // The biome of a block can come from the chunk next to it
    var neighbors: worldgen.generator.Neighbors = undefined;
    for (&neighbors, 0..) |*row, dz| {
        for (row, 0..) |*neighbor, dx| {
            const neighbor_pos: Position = .{ .x = pos.x + @as(i32, @intCast(dx)) - 1, .z = pos.z + @as(i32, @intCast(dz)) - 1 };
            neighbor.* = &(try self.biomes(neighbor_pos)).chunk;
        }
    }
    try worldgen.generator.buildTerrain(self.generation, self.allocator, &entry.chunk, neighbors);
    defer entry.chunk.freeStates(self.allocator);

    entry.encoded = try chunk_packet.encode(self.allocator, &entry.chunk);
    entry.surface = entry.chunk.surface[0];
    return entry;
}

/// The chunk like `net.packets.level_chunk_with_light_s2c` wants it, generated if it wasn't yet.
/// Stays valid as long as the world.
pub fn encodedChunk(self: *World, pos: Position) GetError![]u8 {
    return (try self.generated(pos)).encoded.?;
}

/// The y of the first block without anything above it at the chunk's x = 0, z = 0.
pub fn surfaceAt(self: *World, pos: Position) GetError!i32 {
    return (try self.generated(pos)).surface;
}
