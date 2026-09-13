const Block = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("core.zig");
const RefCount = @import("RefCount.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const update_shape_order: []const core.Direction = &.{ .west, .east, .north, .south, .down, .up };

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

pub const State = struct {
    const dummy_vtable = VTable{
        .equal = dummyEqual,
        .free = dummyFree,
    };

    fn dummyEqual(a: *const State, b: *const State) bool {
        _ = a;
        _ = b;
        return true;
    }

    fn dummyFree(state: *State, gpa: Allocator) void {
        _ = state;
        _ = gpa;
    }

    ref_count: RefCount,
    state_id: State.Id,
    vtable: *const VTable,

    pub const VTable = struct {
        equal: *const fn (*const State, *const State) bool,
        free: *const fn (*State, Allocator) void,
    };

    pub const Id = enum(u32) { _ };

    pub inline fn dummyIota(comptime N: u32, comptime start: u32) [N]State {
        comptime {
            @setEvalBranchQuota(N);
            
            var arr: [N]State = @splat(.{
                .ref_count = .{},
                .state_id = undefined,
                .vtable = &dummy_vtable,
            });
            for (0..N) |i| {
                arr[i].state_id = @enumFromInt(start + i);
            }
            return arr;
        }
    }

    pub fn dummy(id: Id) State {
        return dummyIota(1, @intFromEnum(id))[0];
    }

    /// Should be called when a thread pass the point
    pub fn acquire(self: *State) *State {
        self.ref_count.acquireExtra(@returnAddress());
        return self;
    }

    pub fn release(self: *State, allocator: Allocator) void {
        if (self.ref_count.release()) {
            self.vtable.free(self, allocator);
        }
    }

    /// Does not acquire `self` or `other`.
    pub fn eql(self: *State, other: *State) bool {
        if (self == other) return true;
        if (self.state_id != other.state_id) return false;

        return self.vtable.equal(self, other);
    }
};
