//! The few things worldgen needs to know about blocks.
const std = @import("std");
const block_states = @import("block_states");

pub const StateId = block_states.StateId;

/// The default state of a block, `null` if there's no such block.
pub fn find(name: []const u8) ?StateId {
    for (block_states.blocks) |*block| {
        if (std.mem.eql(u8, block.name, name)) return block.default_state;
    }
    return null;
}

fn known(comptime name: []const u8) *const block_states.Block {
    @setEvalBranchQuota(1_000_000);
    return comptime for (block_states.blocks) |*block| {
        if (std.mem.eql(u8, block.name, name)) break block;
    } else @compileError("no block named " ++ name);
}

pub const air = known("minecraft:air").default_state;
pub const lava = known("minecraft:lava").default_state;
pub const snow_block = known("minecraft:snow_block").default_state;
pub const packed_ice = known("minecraft:packed_ice").default_state;

fn isBlock(comptime name: []const u8, state: StateId) bool {
    const block = comptime known(name);
    return state >= block.first_state and state < block.first_state + block.state_count;
}

pub fn isAir(state: StateId) bool {
    return isBlock("minecraft:air", state) or isBlock("minecraft:cave_air", state) or isBlock("minecraft:void_air", state);
}

pub fn isWater(state: StateId) bool {
    return isBlock("minecraft:water", state);
}

/// Has a fluid state, only what terrain can have: no waterlogged blocks there.
pub fn isFluid(state: StateId) bool {
    return isBlock("minecraft:water", state) or isBlock("minecraft:lava", state);
}

pub fn isStoneBlock(state: StateId) bool {
    return isBlock("minecraft:stone", state);
}
