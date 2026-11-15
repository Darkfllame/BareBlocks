// TODO: Rewrite

const Region = @This();
const std = @import("std");
const utils = @import("utils");
const block_states = @import("block_states");
const core = @import("../core.zig");
const DimensionProperties = @import("DimensionProperties.zig");

const Allocator = std.mem.Allocator;
const BlockStateId = block_states.StateId;

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
default_state: BlockStateId,

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

    pub fn initFill(gpa: Allocator, empty_state: BlockStateId) Allocator.Error!Section {
        var self = Section{
            .data = .{ .leaf = 0 },
            .palette = .empty,
        };
        const id = try self.palette.newId(gpa, empty_state);
        assert(id == 0);
        return self;
    }

    pub fn deinit(self: *Section, gpa: Allocator) void {
        gpa.free(self.palette.states[0..self.palette.states_cap]);
        deinitBranch(self.data, gpa, 0);
    }

    pub const PaletteSize = @Int(.unsigned, std.math.log2_int_ceil(u16, total_blocks + 1));
    pub const BlockIndex = @Int(.unsigned, std.math.log2(total_blocks));
    pub const RawData = if (utils.is_safe) []BlockIndex else [*]BlockIndex;
    pub const SectionBlockPosition = packed struct {
        x: Unit,
        z: Unit,
        y: Unit,

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
        const Alt = struct {
            depth: u8,
            palette: *const BlockPalette,
            branch: *const OctreeBranch,

            pub fn format(self: Alt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                var space = [_][]const u8{"    "};
                try writer.writeSplatAll(&space, self.depth);

                switch (self.branch.*) {
                    .branches => |branches| {
                        try writer.writeAll("{ .branches = .{\n");
                        for (branches, 0..) |*br, i| {
                            try writer.print(".({d}, {d}, {d}) = {f}\n", .{
                                i & 1, // x
                                (i >> 2) & 1, // y
                                (i >> 1) & 1, // z
                                Alt{
                                    .depth = self.depth + 1,
                                    .palette = self.palette,
                                    .branch = br,
                                },
                            });
                        }
                        try writer.writeAll("}}");
                    },
                    .leaf => |leaf| {
                        const state_id = self.palette.getAt(leaf);
                        try writer.print("{{ .leaf = {d}({qf}) }}", .{
                            state_id,
                            utils.Identifier.alt(utils.Identifier.validate(block_states.blockOf(state_id).name) catch unreachable, .full),
                        });
                    },
                    .raw => |r| {
                        _ = r; // autofix
                        const raw_side_len = @as(PaletteSize, side_length) >> @intCast(self.depth);
                        const raw_len = raw_side_len * raw_side_len * raw_side_len;

                        try writer.print("{{ .raw = ({d} entries) }}", .{raw_len});

                        // const ptr = if (utils.is_safe) blk: {
                        //     assert(r.len == raw_len); // bad length
                        //     break :blk r;
                        // } else r[0..raw_len];

                        // for (0..raw_len) |i| {
                        //     const x = i % raw_side_len;
                        //     const z = (i % (raw_side_len * raw_side_len)) / raw_side_len;
                        //     const y = i / (raw_side_len * raw_side_len);

                        // }
                    },
                }
            }
        };

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
        fn newIdNoDupe(self: *BlockPalette, gpa: Allocator, state: BlockStateId) Allocator.Error!BlockIndex {
            var it = self.mask.iterator(.{ .kind = .unset });
            if (it.next()) |idx| blk: {
                if (idx >= self.states_len) break :blk;

                self.mask.set(idx);
                self.states[idx] = state;
                return @intCast(idx);
            }

            if (self.states_cap <= self.states_len) {
                const new_cap = self.states_cap + max_unused_states;

                if (gpa.resize(self.states[0..self.states_cap], new_cap)) {
                    self.states_cap = new_cap;
                } else {
                    const new_sl = try gpa.alloc(BlockStateId, new_cap);
                    @memmove(new_sl[0..self.states_len], self.states[0..self.states_len]);
                    gpa.free(self.states[0..self.states_cap]);
                    self.states = new_sl.ptr;
                    self.states_cap = new_cap;
                }
            }

            const idx: BlockIndex = @intCast(self.states_len);
            self.mask.set(idx);
            self.states[idx] = state;
            self.states_len += 1;
            return idx;
        }

        mask: std.bit_set.Array(usize, total_blocks),
        states: [*]BlockStateId,
        states_cap: PaletteSize,
        states_len: PaletteSize,

        pub const max_unused_states = 16;

        pub const empty = BlockPalette{
            .mask = .empty,
            .states = &[0]BlockStateId{},
            .states_cap = 0,
            .states_len = 0,
        };

        pub fn countUsedStates(self: BlockPalette) usize {
            return self.mask.count();
        }

        pub fn copyInto(self: BlockPalette, gpa: Allocator, out: *BlockPalette) Allocator.Error!void {
            const states_slice = try gpa.alloc(BlockStateId, self.countUsedStates());
            var states_array = std.ArrayList(BlockStateId).initBuffer(states_slice);

            var masks = std.bit_set.Array(usize, total_blocks).empty;
            masks.setRangeValue(.{
                .start = 0,
                .end = states_slice.len,
            }, true);

            var it = self.mask.iterator(.{});
            while (it.next()) |idx| {
                states_array.appendAssumeCapacity(self.states[idx]);
            }

            out.* = .{
                .mask = masks,
                .states = states_slice.ptr,
                .states_cap = @intCast(states_slice.len),
                .states_len = @intCast(states_slice.len),
            };
        }

        pub fn getAt(self: BlockPalette, i: BlockIndex) BlockStateId {
            assert(self.mask.isSet(i));
            return self.states[0..self.states_len][i];
        }

        pub fn setAt(self: BlockPalette, i: BlockIndex, state: BlockStateId) void {
            const slice = self.states[0..self.states_len];
            if (utils.is_safe and self.mask.isSet(i)) @panic("Cannot overwrite state");
            slice[i] = state;
        }

        pub fn findOrNewId(self: *BlockPalette, gpa: Allocator, state: BlockStateId) Allocator.Error!struct { BlockIndex, bool } {
            var it = self.mask.iterator(.{});
            while (it.next()) |idx| {
                if (self.states[idx] == state) return .{ @as(BlockIndex, @intCast(idx)), false };
            }

            return .{ try self.newIdNoDupe(gpa, state), true };
        }

        pub fn newId(self: *BlockPalette, gpa: Allocator, state: BlockStateId) Allocator.Error!BlockIndex {
            var it = self.mask.iterator(.{});
            while (it.next()) |idx| {
                if (self.states[idx] == state) @panic("Invalid call to newId");
            }

            return self.newIdNoDupe(gpa, state);
        }

        pub fn removeId(self: *BlockPalette, id: BlockIndex) void {
            if (utils.is_safe and !self.mask.isSet(id)) std.debug.panic("Index #{d} in palette wasn't valid for removal", .{id});
            self.mask.unset(id);
        }
    };

    pub fn getBlock(self: *Section, pos: SectionBlockPosition) BlockStateId {
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

    pub fn setBlock(self: *Section, pos: SectionBlockPosition, gpa: Allocator, state: BlockStateId) Allocator.Error!void {
        const state_id, const is_new_id = try self.palette.findOrNewId(gpa, state);
        errdefer if (is_new_id) self.palette.removeId(state_id);

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

    // TODO: .optimize() functions. Should calculate the needed memory for each variants depending on
    // TODO: the current variant.

    pub fn format(self: *const Section, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("(Palette: {d} entries, Data: {f})", .{ self.palette.countUsedStates(), OctreeBranch.Alt{
            .depth = 0,
            .palette = &self.palette,
            .branch = &self.data,
        } });
    }
};

pub fn initEmpty(self: *Region, default: BlockStateId) void {
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
}

pub fn getBlock(self: *Region, dim: *const DimensionProperties, pos: core.BlockPosition) BlockStateId {
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
    state: BlockStateId,
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

    const air = comptime block_states.findBlock(.vanilla("air")).?;
    const grass = comptime block_states.findBlock(.vanilla("grass_block")).?;
    const dirt = comptime block_states.findBlock(.vanilla("dirt")).?;
    const stone = comptime block_states.findBlock(.vanilla("stone")).?;

    var sec = try Section.initFill(gpa, air.default_state);
    defer sec.deinit(gpa);
    errdefer std.testing.failPrint("{f}\n", .{sec});

    try sec.setBlock(.{
        .x = 0,
        .y = 0,
        .z = 0,
    }, gpa, stone.default_state);
    try sec.setBlock(.{
        .x = 1,
        .y = 0,
        .z = 0,
    }, gpa, dirt.default_state);
    try sec.setBlock(.{
        .x = 0,
        .y = 1,
        .z = 0,
    }, gpa, grass.default_state);

    try std.testing.expectEqual(stone.default_state, sec.getBlock(.{
        .x = 0,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectEqual(dirt.default_state, sec.getBlock(.{
        .x = 1,
        .y = 0,
        .z = 0,
    }));
    try std.testing.expectEqual(grass.default_state, sec.getBlock(.{
        .x = 0,
        .y = 1,
        .z = 0,
    }));
    try std.testing.expectEqual(air.default_state, sec.getBlock(.{
        .x = 0,
        .y = 0,
        .z = 1,
    }));
}

test Region {
    const gpa = std.testing.allocator;

    const air = comptime block_states.findBlock(.vanilla("air")).?;
    const grass = comptime block_states.findBlock(.vanilla("grass_block")).?;
    const dirt = comptime block_states.findBlock(.vanilla("dirt")).?;
    const stone = comptime block_states.findBlock(.vanilla("stone")).?;

    var region: Region = undefined;
    region.initEmpty(air.default_state);
    defer region.deinit(&.overworld, gpa);

    try region.setBlock(&.overworld, gpa, .{
        .x = 0,
        .y = 64,
        .z = 0,
    }, stone.default_state);
    try region.setBlock(&.overworld, gpa, .{
        .x = 0,
        .y = 65,
        .z = 0,
    }, grass.default_state);
    try region.setBlock(&.overworld, gpa, .{
        .x = 1,
        .y = 64,
        .z = 0,
    }, dirt.default_state);

    try std.testing.expectEqual(stone.default_state, region.getBlock(&.overworld, .{
        .x = 0,
        .y = 64,
        .z = 0,
    }));
    try std.testing.expectEqual(grass.default_state, region.getBlock(&.overworld, .{
        .x = 0,
        .y = 65,
        .z = 0,
    }));
    try std.testing.expectEqual(dirt.default_state, region.getBlock(&.overworld, .{
        .x = 1,
        .y = 64,
        .z = 0,
    }));
}
