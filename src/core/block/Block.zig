const Block = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("../core.zig");
const state = @import("state.zig");

const RefCount = core.RefCount;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const update_shape_order: []const core.Direction = &.{ .west, .east, .north, .south, .down, .up };

properties: Properties,
block_id: Id,
vtable: *const VTable,

pub const State = state.State;

pub const Id = enum(u32) { _ };

pub const VTable = struct {};

pub const Properties = struct {
    flags: Flags = .{},
    map_color: void = {},
    sound_type: void = {},
    light_emission: void = {},
    explosion_resistance: f32 = 0,
    destroy_time: f32 = 0,
    friction: f32 = 0,
    speed_factor: f32 = 0,
    jump_factor: f32 = 0,
    id: void = {},
    drops: void = {},
    description_id: void = {},
    push_reaction: void = {},
    instrument: void = {},
    is_valid_spawn: void = {},
    is_suffocating: void = {},
    is_view_blocking: void = {},
    post_process: void = {},
    emissive_rendering: void = {},
    required_features: void = {},
    offset_function: void = {},

    pub const Flags = packed struct {
        has_collision: bool = false,
        requires_correct_tool: bool = false,
        is_random_ticking: bool = false,
        can_occlude: bool = false,
        is_air: bool = false,
        ignited_by_lava: bool = false,
        force_solid_on: bool = false,
        spawn_terrain_particles: bool = false,
        replaceable: bool = false,
        dynamic_shape: bool = false,
    };
};