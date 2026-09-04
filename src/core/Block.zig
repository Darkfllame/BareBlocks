const Block = @This();
const std = @import("std");
const core = @import("core.zig");

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
    // using a rwlock instead of mutex might be more efficient considering the fact we'll probably read the state
    // in parralel more often than modify it.
    rw: Io.RwLock,
    ref_count: usize,
    state_id: State.Id,
    vtable: *const VTable,

    pub const VTable = struct {
        equal: *const fn (*State, *State) bool,
        free: *const fn (*State, Allocator) void,
    };

    pub const Id = enum(u32) { _ };

    pub fn acquire(self: *State, io: Io) void {
        self.lockUncancelable(io);
        defer self.unlock(io);

        assert(self.ref_count != 0);

        self.ref_count += 1;
    }
    pub fn release(self: *State, io: Io, allocator: Allocator) void {
        self.lockUncancelable(io);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.vtable.free(self, allocator);
            return; // last instance so no need to unlock
        }
        self.unlock(io);
    }

    pub fn lock(self: *State, io: Io) Io.Cancelable!void {
        return self.rw.lock(io);
    }
    pub fn lockShared(self: *State, io: Io) Io.Cancelable!void {
        return self.rw.lockShared(io);
    }
    pub fn tryLock(self: *State, io: Io) bool {
        return self.rw.tryLock(io);
    }
    pub fn tryLockShared(self: *State, io: Io) bool {
        return self.rw.tryLockShared(io);
    }
    pub fn lockUncancelable(self: *State, io: Io) void {
        return self.rw.lockUncancelable(io);
    }
    pub fn lockSharedUncancelable(self: *State, io: Io) void {
        return self.rw.lockSharedUncancelable(io);
    }
    pub fn unlock(self: *State, io: Io) void {
        return self.rw.unlock(io);
    }
    pub fn unlockShared(self: *State, io: Io) void {
        return self.rw.unlockShared(io);
    }

    pub fn eql(self: *State, other: *State, io: Io) bool {
        self.lockSharedUncancelable(io);
        defer self.unlockShared(io);

        other.lockSharedUncancelable(io);
        defer other.unlockShared(io);

        if (self == other) return true;
        if (self.state_id != other.state_id) return false;

        return self.vtable.equal(self, other);
    }
};
