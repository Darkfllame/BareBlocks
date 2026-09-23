const Region = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("../core.zig");
const world = @import("world.zig");
const DimensionProperties = @import("DimensionProperties.zig");

const Block = core.Block;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const logger = std.log.scoped(.@"core/region");

const region_side_length = 512;
const region_section_length = @divExact(region_side_length, Section.side_length);
const max_sections_per_regions = region_section_length * region_section_length;
const vanilla_per_section = @divExact(Section.side_length, 16);

/// Should be a u8
const SectionIndex = @Int(.unsigned, std.math.log2(max_sections_per_regions));

const RegionSectionPosition = packed struct(SectionIndex) {
    x: Unit,
    y: Unit,

    /// Should be a u4
    pub const Unit = @Int(.unsigned, std.math.log2(region_side_length));
};

fn verticalSectionsCount(dim: *const DimensionProperties) usize {
    const vanilla_count = @divExact(@as(usize, dim.buildRange()), 16);
    return @divFloor(vanilla_count + 1, vanilla_per_section);
}

fn getSectionAtRaw(self: *Region, dim: *const DimensionProperties, pos: core.BlockPosition) *Section {
    if (pos.x >= region_side_length or pos.z >= region_side_length) {
        logger.warn("Postion {f} inside region {*} outside of bounds, is this intentional ?", .{ pos, self });
    }

    const build_height = dim.buildRange();
    const vsc = verticalSectionsCount(dim);

    const rel_y = pos.y - dim.height.min;
    const x: usize = @intCast(@rem(pos.x, region_side_length));
    const z: usize = @intCast(@rem(pos.z, region_side_length));
    const index = x * region_section_length + z;

    assert(self.sections_mask.isSet(index));
    assert(rel_y >= 0);
    assert(rel_y < build_height);

    const section_index = self.section_indices[index] * vsc;
    const offset = @rem(@as(usize, @intCast(rel_y)), vsc);

    return &self.sections.items[section_index + offset];
}

// NOTE:
//  - Ideally, all loaded regions should be dumped to disk if the server is innactive,
//    that way they can be re-loaded in memory in the most optimal way.
//  - Regions shouldn't get marked unloaded before finishing serialization

sections_mask: std.StaticBitSet(max_sections_per_regions),
section_indices: [max_sections_per_regions]SectionIndex,
/// List of concatenated lists.
///
/// Size of sub-lists depend on the dimension's build height.
sections: std.ArrayList(Section),
/// Likely air.
default_state: *Block.State,

/// A 32x32 blocks section of the world.
///
/// YES vanilla sections are only 16x16 but 32x32 is more memory efficient in my case.
/// Instead of wasting 4 bits per block index, I only waste 1, for practically no lost
/// in byte compared to a 16x16 section size
pub const Section = struct {
    fn deinitBranch(branch: OctreeBranch, gpa: Allocator, depth: u8) void {
        switch (branch) {
            .branches => |branches| {
                assert(depth < max_octree_depth); // Octree too deep

                for (branches) |b| {
                    deinitBranch(b, gpa, depth + 1);
                }
                gpa.destroy(branches);
            },
            .leaf => {},
            .raw => |r| {
                const raw_side_len = @as(PaletteSize, side_length) >> @intCast(depth);
                const raw_len = @as(usize, raw_side_len) * raw_side_len * raw_side_len;

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_len); // bad length
                    break :blk r;
                } else r[0..raw_len];
                gpa.free(ptr);
            },
        }
    }

    fn subBranch(
        branches: *[8]OctreeBranch,
        depth: *u8,
        x: *SectionBlockPosition.Unit,
        y: *SectionBlockPosition.Unit,
        z: *SectionBlockPosition.Unit,
    ) *OctreeBranch {
        assert(depth.* < max_octree_depth); // Octree too deep
        const next_idx = ((y.* & 1) << 2) |
            ((z.* & 1) << 1) |
            (x.* & 1);
        depth.* += 1;
        x.* >>= 1;
        y.* >>= 1;
        z.* >>= 1;
        return &branches[next_idx];
    }

    fn rawIndex(
        raw_side_len: PaletteSize,
        x: SectionBlockPosition.Unit,
        y: SectionBlockPosition.Unit,
        z: SectionBlockPosition.Unit,
    ) BlockIndex {
        return @intCast(@as(PaletteSize, y) * raw_side_len * raw_side_len +
            @as(PaletteSize, z) * raw_side_len +
            @as(PaletteSize, x));
    }

    data: OctreeBranch,
    palette: BlockPalette,

    pub const side_length = 32;
    pub const total_blocks = side_length * side_length * side_length;
    pub const max_octree_depth = std.math.log2(side_length);

    pub fn initFill(gpa: Allocator, empty_state: *Block.State) Allocator.Error!Section {
        var self = Section{
            .data = .{ .leaf = 0 },
            .palette = .{
                .states = &[0]?*Block.State{},
                .states_cap = 0,
                .states_len = 0,
            },
        };
        const id = try self.palette.newId(gpa, empty_state);
        assert(id == 0);
        return self;
    }

    pub fn deinit(self: *Section, gpa: Allocator) void {
        for (self.palette.states[0..self.palette.states_len]) |mst| {
            if (mst) |state| {
                state.release(gpa);
            }
        }
        gpa.free(self.palette.states[0..self.palette.states_cap]);
        deinitBranch(self.data, gpa, 0);
    }

    pub const PaletteSize = @Int(.unsigned, std.math.log2_int_ceil(u16, total_blocks + 1));
    pub const BlockIndex = @Int(.unsigned, std.math.log2(total_blocks));
    pub const RawData = if (utils.is_safe) []BlockIndex else [*]BlockIndex;
    pub const SectionBlockPosition = packed struct {
        x: Unit,
        y: Unit,
        z: Unit,

        pub const Unit = @Int(.unsigned, max_octree_depth);
        pub const Shift = std.math.Log2Int(SectionBlockPosition.Unit);
    };

    /// The idea is that chunks further away from players probably don't need to be fully
    /// detailed and can instead be stored on disk instead for better memory usage.
    ///
    /// Mostly full sections can be replaced with a single `leaf` branch.
    ///
    /// Parts of the world with a lot of different blocks is rarer, making them less
    /// memory efficient and faster to read and write is better. Especially if it changes
    /// a lot (i.e: near a player)
    pub const OctreeBranch = union(enum) {
        branches: *[8]OctreeBranch,
        /// A value of `null` means this leaf node is empty.
        leaf: BlockIndex,
        /// On safe compile modes (debug and release safe) this is a slice.
        /// and its length is checked to match estimations.
        ///
        /// On other modes, this is a simple pointer-to-many and its length is
        /// determined by the depth of this branch.
        raw: RawData,
    };

    pub const BlockPalette = struct {
        states: [*]?*Block.State,
        states_cap: PaletteSize,
        states_len: PaletteSize,

        pub const max_unused_states = 16;

        pub const empty = BlockPalette{
            .states = &[0]?*Block.State{},
            .states_cap = 0,
            .states_len = 0,
        };

        pub fn countUsedStates(self: BlockPalette) usize {
            var count: usize = 0;
            for (self.states[0..self.states_len]) |s| {
                count += @intFromBool(s != null);
            }
            return count;
        }

        pub fn copyInto(self: BlockPalette, gpa: Allocator, out: *BlockPalette) Allocator.Error!void {
            const states_slice = try gpa.alloc(?*Block.State, self.countUsedStates());
            var index: usize = 0;
            for (self.states[0..self.states_len]) |state| {
                if (state) |st| {
                    states_slice[index] = st.acquire();
                    index += 1;

                    if (index == states_slice.len) break; // reached end
                }
            }
            out.* = .{
                .states = states_slice.ptr,
                .states_cap = @intCast(states_slice.len),
                .states_len = @intCast(states_slice.len),
            };
        }

        pub fn getAt(self: BlockPalette, i: BlockIndex) *Block.State {
            return self.states[0..self.states_len][i].?;
        }

        pub fn setAt(self: BlockPalette, i: BlockIndex, state: *Block.State) void {
            const slice = self.states[0..self.states_len];
            if (utils.is_safe and slice[i] != null) @panic("Cannot overwrite state");
            slice[i] = state;
        }

        pub fn findOrNewId(self: *BlockPalette, gpa: Allocator, state: *Block.State) Allocator.Error!struct { BlockIndex, bool } {
            for (self.states[0..self.states_len], 0..) |may_st, i| {
                if (may_st == state) return .{ @as(BlockIndex, @intCast(i)), false };
            }

            return .{ try self.newId(gpa, state), true };
        }

        pub fn newId(self: *BlockPalette, gpa: Allocator, state: *Block.State) Allocator.Error!BlockIndex {
            var free_space: ?BlockIndex = null;
            for (self.states[0..self.states_len], 0..) |*st_p, i| {
                if (st_p.* == state) @panic("Invalid call to newId");
                if (st_p.* == null and free_space == null) {
                    free_space = @intCast(i);
                    continue;
                }
            }

            if (free_space) |idx| {
                self.states[idx] = state.acquire();
                return idx;
            }

            blk: {
                if (self.states_cap > self.states_len) break :blk;

                const new_cap = self.states_cap + max_unused_states;

                if (gpa.resize(self.states[0..self.states_cap], new_cap)) {
                    self.states_cap = new_cap;
                    break :blk;
                }

                const new_sl = try gpa.alloc(?*Block.State, new_cap);
                @memmove(new_sl[0..self.states_len], self.states[0..self.states_len]);
                gpa.free(self.states[0..self.states_cap]);
                self.states = new_sl.ptr;
                self.states_cap = new_cap;
            }

            const idx: BlockIndex = @intCast(self.states_len);
            self.states[idx] = state.acquire();
            self.states_len += 1;
            return idx;
        }

        pub fn removeId(self: *BlockPalette, id: BlockIndex, gpa: Allocator) void {
            if (id == self.states_len - 1) return self.removeIdShort(id, gpa);
            const slice = self.states[0..self.states_len];
            slice[id].?.release(gpa);
            slice[id] = null;
            var i: usize = self.states_len - 1;
            while (true) {
                const st = slice[i];
                i, const ov = @subWithOverflow(i, 1);
                if (st != null or ov == 1) break;
            }
        }

        pub fn removeIdShort(self: *BlockPalette, id: BlockIndex, gpa: Allocator) void {
            assert(id == self.states_len - 1);
            self.states[id].?.release(gpa);
            self.states_len -= 1;
        }
    };

    pub fn getBlock(self: *Section, pos: SectionBlockPosition) *Block.State {
        var depth: u8 = 0;
        var x, var y, var z = .{ pos.x, pos.y, pos.z };
        const pal_idx = sw: switch (self.data) {
            .branches => |b| continue :sw subBranch(b, &depth, &x, &y, &z).*,
            .leaf => |l| l,
            .raw => |r| {
                const raw_side_len = @as(PaletteSize, side_length) >> @intCast(depth);
                const raw_len = raw_side_len * raw_side_len * raw_side_len;

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_len); // bad length
                    break :blk r;
                } else r[0..raw_len];

                break :sw ptr[rawIndex(raw_side_len, x, y, z)];
            },
        };
        return self.palette.getAt(pal_idx);
    }

    pub fn setBlock(self: *Section, pos: SectionBlockPosition, gpa: Allocator, state: *Block.State) Allocator.Error!void {
        const state_id, const is_new_id = try self.palette.findOrNewId(gpa, state);
        errdefer if (is_new_id) self.palette.removeId(state_id, gpa);

        var depth: u8 = 0;
        var x, var y, var z = .{ pos.x, pos.y, pos.z };
        var br: *OctreeBranch = &self.data;
        sw: switch (br.*) {
            .branches => |b| {
                br = subBranch(b, &depth, &x, &y, &z);
                continue :sw br.*;
            },
            .leaf => |l| {
                if (self.palette.getAt(l) == state) {
                    assert(state_id == l);
                    return; // already set
                }
                switch (depth) {
                    0 => {
                        const nodes = try gpa.create([8]OctreeBranch);
                        @memset(nodes, br.*);
                        br.* = .{ .branches = nodes };
                        continue :sw br.*;
                    },
                    1...max_octree_depth - 2 => {
                        const raw_side_len = @as(PaletteSize, side_length) >> @intCast(depth);
                        const raw_len = raw_side_len * raw_side_len * raw_side_len;

                        const raw = try gpa.alloc(BlockIndex, raw_len);
                        @memset(raw, l);
                        raw[rawIndex(raw_side_len, x, y, z)] = state_id;

                        br.* = .{ .raw = if (utils.is_safe) raw else raw.ptr };
                    },
                    max_octree_depth - 1 => {
                        const nodes = try gpa.create([8]OctreeBranch);
                        @memset(nodes, br.*);
                        const idx = ((x & 1) << 2) | ((y & 1) << 1) | (z & 1);
                        nodes[idx].leaf = state_id;
                        br.* = .{ .branches = nodes };
                    },
                    max_octree_depth => {
                        br.leaf = state_id;
                    },
                    else => unreachable,
                }
            },
            .raw => |r| {
                const raw_side_len = @as(PaletteSize, side_length) >> @intCast(depth);
                const raw_len = raw_side_len * raw_side_len * raw_side_len;

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_len); // bad length
                    break :blk r;
                } else r[0..raw_len];

                ptr[rawIndex(raw_side_len, x, y, z)] = state_id;
            },
        }
    }
};

pub fn initEmpty(self: *Region, default: *Block.State) void {
    self.* = .{
        .sections_mask = .empty,
        .section_indices = undefined,
        .sections = .empty,
        .default_state = default,
    };
}

pub fn deinit(self: *Region, dim: *const DimensionProperties, gpa: Allocator) void {
    const vsc = verticalSectionsCount(dim);

    const sections = self.sections.items;
    var it = self.sections_mask.iterator(.{});
    while (it.next()) |idx| {
        const index = self.section_indices[idx] * vsc;
        for (sections[index..][0..vsc]) |*sec| {
            sec.deinit(gpa);
        }
    }
    self.sections.deinit(gpa);
    self.default_state.release(gpa);
}

pub fn getBlock(self: *Region, dim: *const DimensionProperties, pos: core.BlockPosition) *Block.State {
    const sec_pos = core.BlockPosition{
        .x = @rem(pos.x, region_side_length),
        .y = pos.y,
        .z = @rem(pos.z, region_side_length),
    };

    const index = @as(usize, @intCast(sec_pos.x)) * region_section_length + @as(usize, @intCast(sec_pos.z));

    if (!self.sections_mask.isSet(index)) return self.default_state;

    const block_pos = Section.SectionBlockPosition{
        // This is so ugly OH MY DAYS
        .x = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "x"))), @bitCast(sec_pos.x)) % Section.side_length),
        .y = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "y"))), @bitCast(sec_pos.y)) % Section.side_length),
        .z = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "z"))), @bitCast(sec_pos.z)) % Section.side_length),
    };

    const section = self.getSectionAtRaw(dim, sec_pos);

    return section.getBlock(block_pos);
}

pub fn setBlock(
    self: *Region,
    dim: *const DimensionProperties,
    gpa: Allocator,
    pos: core.BlockPosition,
    state: *Block.State,
) Allocator.Error!void {
    const sec_pos = core.BlockPosition{
        .x = @rem(pos.x, region_side_length),
        .y = pos.y,
        .z = @rem(pos.z, region_side_length),
    };

    const block_pos = Section.SectionBlockPosition{
        // This is so ugly OH MY DAYS
        .x = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "x"))), @bitCast(sec_pos.x)) % Section.side_length),
        .y = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "y"))), @bitCast(sec_pos.y)) % Section.side_length),
        .z = @intCast(@as(@Int(.unsigned, @bitSizeOf(@FieldType(core.BlockPosition, "z"))), @bitCast(sec_pos.z)) % Section.side_length),
    };

    const index = @as(usize, @intCast(sec_pos.x)) * region_section_length + @as(usize, @intCast(sec_pos.z));

    const section = if (!self.sections_mask.isSet(index)) blk: {
        const build_height = dim.buildRange();
        const vsc = verticalSectionsCount(dim);

        var i: usize = 0;
        const old_len = self.sections.items.len;
        const new_sec = try self.sections.addManyAsSlice(gpa, vsc);
        errdefer {
            for (0..i) |idx| new_sec[idx].deinit(gpa);
            self.sections.items.len -= vsc;
        }

        for (new_sec, 0..) |*section, j| {
            errdefer i = j;
            section.* = try Section.initFill(gpa, state);
        }

        self.sections_mask.set(index);
        self.section_indices[index] = @intCast(@divExact(old_len, vsc));

        const rel_y = sec_pos.y - dim.height.min;
        assert(rel_y >= 0);
        assert(rel_y < build_height);

        const offset = @rem(@as(usize, @intCast(rel_y)), vsc);

        break :blk &new_sec[offset];
    } else self.getSectionAtRaw(dim, sec_pos);

    try section.setBlock(block_pos, gpa, state);
}

test {
    std.testing.refAllDecls(@This());
}

test Section {
    const gpa = std.testing.allocator;

    var states = Block.State.dummyIota(4, 0);

    var sec = try Section.initFill(gpa, &states[0]);
    defer sec.deinit(gpa);

    try sec.setBlock(.{
        .x = 0,
        .y = 0,
        .z = 0,
    }, gpa, &states[3]);
    try sec.setBlock(.{
        .x = 1,
        .y = 0,
        .z = 0,
    }, gpa, &states[1]);
    try sec.setBlock(.{
        .x = 0,
        .y = 1,
        .z = 0,
    }, gpa, &states[2]);

    try std.testing.expectEqual(&states[3], sec.getBlock(.{
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectEqual(&states[1], sec.getBlock(.{
        .x = 1,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectEqual(&states[2], sec.getBlock(.{
        .x = 0,
        .y = 1,
        .z = 0,
    }));
    try std.testing.expectEqual(&states[0], sec.getBlock(.{
        .x = 0,
        .y = 0,
        .z = 1,
    }));
}

test Region {
    const gpa = std.testing.allocator;

    var states = Block.State.dummyIota(4, 0);

    var region: Region = undefined;
    region.initEmpty(&states[0]);
    defer region.deinit(&.overworld, gpa);

    try region.setBlock(&.overworld, gpa, .{
        .x = 0,
        .y = 64,
        .z = 0,
    }, &states[1]);
    try region.setBlock(&.overworld, gpa, .{
        .x = 0,
        .y = 65,
        .z = 0,
    }, &states[2]);
    try region.setBlock(&.overworld, gpa, .{
        .x = 1,
        .y = 64,
        .z = 0,
    }, &states[3]);

    try std.testing.expectEqual(&states[1], region.getBlock(&.overworld, .{
        .x = 0,
        .y = 64,
        .z = 0,
    }));
    try std.testing.expectEqual(&states[2], region.getBlock(&.overworld, .{
        .x = 0,
        .y = 65,
        .z = 0,
    }));
    try std.testing.expectEqual(&states[3], region.getBlock(&.overworld, .{
        .x = 1,
        .y = 64,
        .z = 0,
    }));
}
