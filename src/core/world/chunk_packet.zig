//! Encodes a chunk like vanilla's `ClientboundLevelChunkWithLightPacket`, everything after the
//! chunk's coordinates: heightmaps, sections, block entities and light.
const std = @import("std");
const registries = @import("registries");
const block_states = @import("block_states");
const worldgen = @import("worldgen");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const StateId = block_states.StateId;

/// Ids of vanilla's `Heightmap.Types`, only the ones the client gets.
const HeightmapType = enum(u8) {
    world_surface = 1,
    motion_blocking = 4,
    motion_blocking_no_leaves = 5,
};

/// Blocks of a block tag, by block id.
fn blockTag(comptime name: []const u8) [block_states.blocks.len]bool {
    @setEvalBranchQuota(1_000_000);
    comptime {
        var set: [block_states.blocks.len]bool = @splat(false);
        for (registries.tags) |registry| {
            if (!std.mem.eql(u8, registry.registry, "minecraft:block")) continue;
            for (registry.tags) |tag| {
                if (!std.mem.eql(u8, tag.name, name)) continue;
                for (tag.entries) |block| set[block] = true;
                return set;
            }
        }
        @compileError("no block tag named " ++ name);
    }
}

const blocks_motion = blockTag("minecraft:blocks_motion_in_heightmap");
const blocks_motion_no_leaves = blockTag("minecraft:blocks_motion_in_heightmap_no_leaves");

fn countsFor(kind: HeightmapType, state: StateId) bool {
    return switch (kind) {
        .world_surface => !worldgen.blocks.isAir(state),
        .motion_blocking => blocks_motion[block_states.state_blocks[state]] or worldgen.blocks.isFluid(state),
        .motion_blocking_no_leaves => blocks_motion_no_leaves[block_states.state_blocks[state]] or worldgen.blocks.isFluid(state),
    };
}

fn varInt(w: *Io.Writer, value: usize) Io.Writer.Error!void {
    var remaining: u32 = @intCast(value);
    while (true) {
        const byte: u8 = @truncate(remaining & 0x7F);
        remaining >>= 7;
        if (remaining == 0) return w.writeByte(byte);
        try w.writeByte(byte | 0x80);
    }
}

fn ceilLog2(count: usize) u6 {
    return if (count <= 1) 0 else @intCast(std.math.log2_int_ceil(usize, count));
}

/// Vanilla's `SimpleBitStorage`: as many values of `bits` bits as fit in each long, none over two.
fn writeBitStorage(w: *Io.Writer, bits: u6, values: []const u32) Io.Writer.Error!void {
    const per_long = 64 / @as(usize, bits);
    var i: usize = 0;
    while (i < values.len) : (i += per_long) {
        var long: u64 = 0;
        for (values[i..@min(i + per_long, values.len)], 0..) |value, n| {
            long |= @as(u64, value) << @intCast(n * bits);
        }
        try w.writeInt(u64, long, .big);
    }
}

fn bitStorageLongs(bits: u6, count: usize) usize {
    return std.math.divCeil(usize, count, 64 / @as(usize, bits)) catch unreachable;
}

/// A `PalettedContainer`. `linear_bits` are the sizes a palette can have before the values are
/// written as they are, with `global_bits` each (vanilla's `Strategy`).
fn writeContainer(w: *Io.Writer, values: []u32, comptime linear_bits: []const u6, global_bits: u6) Io.Writer.Error!void {
    const max_palette = 1 << linear_bits[linear_bits.len - 1];
    var palette: [max_palette]u32 = undefined;
    var palette_len: usize = 0;
    const fits = for (values) |value| {
        if (std.mem.indexOfScalar(u32, palette[0..palette_len], value) != null) continue;
        if (palette_len == max_palette) break false;
        palette[palette_len] = value;
        palette_len += 1;
    } else true;

    if (!fits) {
        try w.writeByte(global_bits);
        return writeBitStorage(w, global_bits, values);
    }
    if (palette_len == 1) {
        try w.writeByte(0);
        return varInt(w, palette[0]);
    }
    const bits = for (linear_bits) |bits| {
        if (palette_len <= @as(usize, 1) << bits) break bits;
    } else unreachable;
    try w.writeByte(bits);
    try varInt(w, palette_len);
    for (palette[0..palette_len]) |value| try varInt(w, value);
    for (values) |*value| value.* = @intCast(std.mem.indexOfScalar(u32, palette[0..palette_len], value.*).?);
    try writeBitStorage(w, bits, values);
}

fn writeHeightmaps(w: *Io.Writer, chunk: *const worldgen.Chunk) Io.Writer.Error!void {
    const kinds = comptime std.enums.values(HeightmapType);
    const bits = ceilLog2(@intCast(chunk.height + 1));

    try varInt(w, kinds.len);
    for (kinds) |kind| {
        // The first y without anything that counts above it, from the bottom of the world
        var heights: [256]u32 = undefined;
        for (&heights, 0..) |*h, i| {
            const x: i32 = @intCast(i % 16);
            const z: i32 = @intCast(i / 16);
            var y = chunk.min_y + chunk.height - 1;
            h.* = while (y >= chunk.min_y) : (y -= 1) {
                if (countsFor(kind, chunk.get(x, y, z))) break @intCast(y + 1 - chunk.min_y);
            } else 0;
        }
        try varInt(w, @backingInt(kind));
        try varInt(w, bitStorageLongs(bits, heights.len));
        try writeBitStorage(w, bits, &heights);
    }
}

fn writeSections(w: *Io.Writer, chunk: *const worldgen.Chunk) Io.Writer.Error!void {
    const state_bits = ceilLog2(block_states.state_blocks.len);
    const biome_bits = ceilLog2(worldgen.data.biomes.len);

    var section_y = chunk.min_y >> 4;
    while (section_y < (chunk.min_y + chunk.height) >> 4) : (section_y += 1) {
        var states: [4096]u32 = undefined;
        var non_empty: u16 = 0;
        var fluids: u16 = 0;
        for (&states, 0..) |*state, i| {
            state.* = chunk.get(@intCast(i & 15), section_y * 16 + @as(i32, @intCast(i >> 8)), @intCast((i >> 4) & 15));
            if (!worldgen.blocks.isAir(state.*)) non_empty += 1;
            if (worldgen.blocks.isFluid(state.*)) fluids += 1;
        }
        try w.writeInt(u16, non_empty, .big);
        try w.writeInt(u16, fluids, .big);
        try writeContainer(w, &states, &.{ 4, 5, 6, 7, 8 }, state_bits);

        var biomes: [64]u32 = undefined;
        for (&biomes, 0..) |*biome, i| {
            biome.* = chunk.biome(chunk.x * 4 + @as(i32, @intCast(i & 3)), section_y * 4 + @as(i32, @intCast(i >> 4)), chunk.z * 4 + @as(i32, @intCast((i >> 2) & 3)));
        }
        try writeContainer(w, &biomes, &.{ 1, 2, 3 }, biome_bits);
    }
}

/// No light engine yet: the sky lights everything.
fn writeLight(w: *Io.Writer, chunk: *const worldgen.Chunk) Io.Writer.Error!void {
    // One section under and one over the world
    const sections: usize = @intCast(@divExact(chunk.height, 16) + 2);
    const all = (@as(u64, 1) << @intCast(sections)) - 1;

    // Sky, block, empty sky and empty block masks: the bytes of a `java.util.BitSet`, lowest first
    // and without the zeros at the end
    for ([_]u64{ all, 0, 0, all }) |mask| {
        const len = std.math.divCeil(usize, 64 - @clz(mask), 8) catch unreachable;
        try varInt(w, len);
        try w.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u64, mask))[0..len]);
    }
    try varInt(w, sections);
    for (0..sections) |_| {
        try varInt(w, 2048);
        try w.splatByteAll(0xFF, 2048);
    }
    try varInt(w, 0);
}

/// The chunk needs its blocks. Caller owns the bytes.
pub fn encode(gpa: Allocator, chunk: *const worldgen.Chunk) Allocator.Error![]u8 {
    var sections: Io.Writer.Allocating = .init(gpa);
    defer sections.deinit();
    writeSections(&sections.writer, chunk) catch return error.OutOfMemory;

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    (blk: {
        writeHeightmaps(w, chunk) catch |e| break :blk e;
        varInt(w, sections.written().len) catch |e| break :blk e;
        w.writeAll(sections.written()) catch |e| break :blk e;
        // No block entities
        varInt(w, 0) catch |e| break :blk e;
        writeLight(w, chunk) catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test writeBitStorage {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // 5 bits: 12 values in a long, the 13th starts the next one
    var values: [13]u32 = @splat(0);
    values[0] = 1;
    values[1] = 2;
    values[12] = 31;
    try writeBitStorage(&w, 5, &values);
    try std.testing.expectEqual(2, bitStorageLongs(5, values.len));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0x41, 0, 0, 0, 0, 0, 0, 0, 31 }, w.buffered());
}

test writeContainer {
    var buf: [4096]u8 = undefined;

    // One value: no bits, only the value
    var w: Io.Writer = .fixed(&buf);
    var same: [4096]u32 = @splat(9);
    try writeContainer(&w, &same, &.{ 4, 5, 6, 7, 8 }, 15);
    try std.testing.expectEqualSlices(u8, &.{ 0, 9 }, w.buffered());

    // Two values: block states are never under 4 bits
    w = .fixed(&buf);
    var two: [4096]u32 = @splat(9);
    two[1] = 300;
    try writeContainer(&w, &two, &.{ 4, 5, 6, 7, 8 }, 15);
    const written = w.buffered();
    try std.testing.expectEqual(1 + 1 + 1 + 2 + 256 * 8, written.len);
    try std.testing.expectEqualSlices(u8, &.{ 4, 2, 9, 0xAC, 0x02 }, written[0..5]);
    try std.testing.expectEqual(0x10, written[5 + 7]);
}
