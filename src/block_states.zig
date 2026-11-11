//! Every block and block state, the data itself is generated from blocks.json by build/gen_data.zig.
const std = @import("std");
const bsd = @import("block_states_data");
const data = bsd.Data(Property, Block);

const assert = std.debug.assert;

/// Global block state id, same as the protocol's.
pub const StateId = u32;
/// Mojang's names for the properties (BlockStateProperties' fields), e.g. `.horizontal_facing`, `.age_7`.
pub const PropertyId = bsd.PropertyId;

pub const properties: []const Property = &data.properties;
/// Sorted by `first_state`.
pub const blocks: []const Block = &data.blocks;
/// Packed value indices of each state, see `Layout`.
pub const state_bits: []const u16 = &bsd.state_bits;
/// Index into `blocks` of each state.
pub const state_blocks: []const u16 = &bsd.state_blocks;

pub const Property = struct {
    name: []const u8,
    kind: Kind,
    /// In vanilla order. A state's value for this property is stored as an index into this.
    values: []const []const u8,

    pub const Kind = enum { boolean, integer, enumeration };
};

pub fn property(id: PropertyId) *const Property {
    return &properties[@backingInt(id)];
}

pub const Block = struct {
    name: []const u8,
    first_state: StateId,
    state_count: u32,
    default_state: StateId,
    /// Sorted by name, which is also the order state ids are computed in (last one changes the fastest).
    properties: []const Layout,

    pub fn find(self: *const Block, name: []const u8) ?*const Layout {
        for (self.properties) |*l| {
            if (std.mem.eql(u8, property(l.property).name, name)) return l;
        }
        return null;
    }

    /// `null` if this block doesn't have the property.
    pub fn layout(self: *const Block, id: PropertyId) ?*const Layout {
        for (self.properties) |*l| {
            if (l.property == id) return l;
        }
        return null;
    }
};

/// Where a property sits in a block's states.
pub const Layout = struct {
    property: PropertyId,
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
        assert(value_index < property(self.property).values.len);
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
                for (0..property(layout.property).values.len) |value_index| {
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

test PropertyId {
    const stairs = for (blocks) |*block| {
        if (std.mem.eql(u8, block.name, "minecraft:oak_stairs")) break block;
    } else return error.TestUnexpectedResult;

    // Same name, different properties
    try std.testing.expect(stairs.layout(.horizontal_facing) != null);
    try std.testing.expect(stairs.layout(.facing) == null);
    try std.testing.expectEqual(stairs.find("facing"), stairs.layout(.horizontal_facing));

    try std.testing.expectEqualStrings("facing", property(.horizontal_facing).name);
    try std.testing.expectEqual(4, property(.horizontal_facing).values.len);
    try std.testing.expectEqual(6, property(.facing).values.len);
    try std.testing.expectEqual(8, property(.age_7).values.len);
    try std.testing.expectEqualStrings("single", property(.chest_type).values[0]);
}
