//! Every block and block state, the data itself is generated from blocks.json by build/gen_data.zig.
const std = @import("std");
const data = @import("block_states_data").Data(Property, Block);

const assert = std.debug.assert;

/// Global block state id, same as the protocol's.
pub const StateId = u32;

pub const properties: []const Property = &data.properties;
/// Sorted by `first_state`.
pub const blocks: []const Block = &data.blocks;
/// Packed value indices of each state, see `Layout`.
pub const state_bits: []const u16 = &@import("block_states_data").state_bits;
/// Index into `blocks` of each state.
pub const state_blocks: []const u16 = &@import("block_states_data").state_blocks;

pub const Property = struct {
    name: []const u8,
    kind: Kind,
    /// In vanilla order. A state's value for this property is stored as an index into this.
    values: []const []const u8,

    pub const Kind = enum { boolean, integer, enumeration };
};

pub const Block = struct {
    name: []const u8,
    first_state: StateId,
    state_count: u32,
    default_state: StateId,
    /// Sorted by name, which is also the order state ids are computed in (last one changes the fastest).
    properties: []const Layout,

    pub fn find(self: *const Block, name: []const u8) ?*const Layout {
        for (self.properties) |*layout| {
            if (std.mem.eql(u8, properties[layout.property].name, name)) return layout;
        }
        return null;
    }
};

/// Where a property sits in a block's states.
pub const Layout = struct {
    /// Index into `properties`.
    property: u8,
    /// Position of the value index inside of `state_bits`.
    bit_offset: u4,
    bit_size: u3,
    /// How much the state id moves when the value index goes up by 1.
    stride: u32,

    /// Returns the value index of this property for `id`.
    pub fn get(self: Layout, id: StateId) u8 {
        const mask = (@as(u16, 1) << self.bit_size) - 1;
        return @intCast((state_bits[id] >> self.bit_offset) & mask);
    }

    /// Returns the state with this property set to `value_index`, other properties are kept.
    pub fn with(self: Layout, id: StateId, value_index: u8) StateId {
        assert(value_index < properties[self.property].values.len);
        const old: i64 = self.get(id);
        return @intCast(@as(i64, id) + (@as(i64, value_index) - old) * self.stride);
    }
};

pub fn blockOf(id: StateId) *const Block {
    return &blocks[state_blocks[id]];
}

test "every property of every state" {
    for (blocks, 0..) |*block, block_index| {
        try std.testing.expect(block.default_state >= block.first_state);
        try std.testing.expect(block.default_state < block.first_state + block.state_count);

        for (block.first_state..block.first_state + block.state_count) |i| {
            const id: StateId = @intCast(i);
            try std.testing.expectEqual(block, blockOf(id));
            try std.testing.expectEqual(block_index, state_blocks[id]);

            for (block.properties) |layout| {
                for (0..properties[layout.property].values.len) |value_index| {
                    const new = layout.with(id, @intCast(value_index));
                    try std.testing.expect(new >= block.first_state and new < block.first_state + block.state_count);
                    try std.testing.expectEqual(value_index, layout.get(new));
                    // Others are kept
                    for (block.properties) |other| {
                        if (other.property == layout.property) continue;
                        try std.testing.expectEqual(other.get(id), other.get(new));
                    }
                }
            }
        }
    }
}
