const Region = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("../core.zig");
const Block = @import("../Block.zig");
const world = @import("world.zig");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

/// A 32x32 blocks section of the world
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

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_side_len); // bad length
                    break :blk r;
                } else r[0..raw_side_len];
                gpa.free(ptr);
            },
        }
    }

    data: OctreeBranch,
    palette: BlockPalette,

    pub const side_length = 32;
    pub const total_blocks = side_length * side_length * side_length;
    pub const max_octree_depth = std.math.log2(side_length);

    pub fn initEmpty(gpa: Allocator, empty_state: *Block.State) Allocator.Error!Section {
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

    /// Same as `deinit()` but doesn't call `release()` on palette entries.
    pub fn deinitNoRelease(self: *Section, gpa: Allocator) void {
        gpa.free(self.palette.states[0..self.palette.states_cap]);
        deinitBranch(self.data, gpa, 0);
    }

    pub fn deinit(self: *Section, gpa: Allocator) void {
        for (self.palette.states[0..self.palette.states_len]) |mst| {
            if (mst) |state| {
                state.release(gpa);
            }
        }
        self.deinitNoRelease(gpa);
    }

    pub const PaletteSize = @Int(.unsigned, std.math.log2_int_ceil(u16, total_blocks + 1));
    pub const BlockIndex = @Int(.unsigned, std.math.log2(total_blocks));
    pub const RawData = if (utils.is_safe) []BlockIndex else [*]BlockIndex;
    pub const SectionPosition = packed struct {
        x: Unit,
        y: Unit,
        z: Unit,

        pub const Unit = @Int(.unsigned, max_octree_depth);
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
                self.states[idx] = state;
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
            self.states[idx] = state;
            self.states_len += 1;
            return idx;
        }

        pub fn removeId(self: *BlockPalette, id: BlockIndex) void {
            const slice = self.states[0..self.states_len];
            slice[id] = null;
            var i: usize = self.states_len - 1;
            while (true) {
                const st = slice[i];
                i, const ov = @subWithOverflow(i, 1);
                if (st != null or ov == 1) break;
            }
        }

        pub fn removeIdShort(self: *BlockPalette, id: BlockIndex) void {
            assert(id == self.states_len - 1);
            self.states_len -= 1;
        }
    };

    pub fn getBlock(self: *Section, pos: SectionPosition) *Block.State {
        var depth: u8 = 0;
        var x, var y, var z = .{ pos.x, pos.y, pos.z };
        const pal_idx = sw: switch (self.data) {
            .branches => |b| {
                assert(depth < max_octree_depth); // Octree too deep
                const next_idx = ((x & 1) << 2) | ((y & 1) << 1) | (z & 1);
                depth += 1;
                x >>= 1;
                y >>= 1;
                z >>= 1;
                continue :sw b[next_idx];
            },
            .leaf => |l| l,
            .raw => |r| {
                const raw_side_len = @as(PaletteSize, side_length) >> @intCast(depth);

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_side_len); // bad length
                    break :blk r;
                } else r;

                break :sw ptr[
                    @as(BlockIndex, x) * raw_side_len * raw_side_len +
                        @as(BlockIndex, y) * raw_side_len +
                        @as(BlockIndex, z)
                ];
            },
        };
        return self.palette.getAt(pal_idx);
    }

    pub fn setBlock(self: *Section, pos: SectionPosition, gpa: Allocator, state: *Block.State) Allocator.Error!void {
        const state_id, const is_new_id = try self.palette.findOrNewId(gpa, state);
        errdefer if (is_new_id) self.palette.removeId(state_id);

        var depth: u8 = 0;
        var x, var y, var z = .{ pos.x, pos.y, pos.z };
        var br: *OctreeBranch = &self.data;
        sw: switch (br.*) {
            .branches => |b| {
                assert(depth < max_octree_depth); // Octree too deep
                const next_idx = ((x & 1) << 2) | ((y & 1) << 1) | (z & 1);
                depth += 1;
                x >>= 1;
                y >>= 1;
                z >>= 1;
                br = &b[next_idx];
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

                        const raw = try gpa.alloc(BlockIndex, raw_side_len);
                        @memset(raw, l);
                        raw[
                            @as(BlockIndex, x) * raw_side_len * raw_side_len +
                                @as(BlockIndex, y) * raw_side_len +
                                @as(BlockIndex, z)
                        ] = state_id;

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

                const ptr = if (utils.is_safe) blk: {
                    assert(r.len == raw_side_len); // bad length
                    break :blk r;
                } else r[0..raw_side_len];

                ptr[
                    @as(BlockIndex, x) * raw_side_len * raw_side_len +
                        @as(BlockIndex, y) * raw_side_len +
                        @as(BlockIndex, z)
                ] = state_id;
            },
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Section {
    const gpa = std.testing.allocator;

    var states = Block.State.dummyIota(3, 0);

    var sec = try Section.initEmpty(gpa, &states[0]);
    defer sec.deinitNoRelease(gpa);

    try sec.setBlock(.{
        .x = 0,
        .y = 0,
        .z = 0,
    }, gpa, &states[0]);
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

    try std.testing.expectEqual(&states[0], sec.getBlock(.{
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
}
