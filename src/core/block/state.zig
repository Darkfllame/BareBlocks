const std = @import("std");
const Block = @import("Block.zig");
const core = @import("../core.zig");
const RefCount = core.RefCount;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const assert = std.debug.assert;

// TODO: Block states in vanilla are all pre-computed at startup.
// TODO: Figure out a way to do lazy-loading on them. Some cache structure might be required. (weak refs inside the cache)
// NOTE: the 'neighbours' field into net.minecraft.world.level.block.state.StateHolder contains these
// NOTE: pre-loaded states. So "setting" a property just results in taking a different state from these.
// NOTE: They are addressed as neighbours[propertyIndex][valueIndex].

pub const PropertyValue = union(enum) {
    boolean: bool,
    integer: i32,
    /// Unsigned but the backing integer used might be.
    @"enum": u32,

    pub fn from(value: anytype) PropertyValue {
        const V = @TypeOf(value);
        const info = @typeInfo(V);
        return sw: switch (info) {
            .bool => .{ .boolean = value },
            .comptime_int, .int => .{ .int = @intCast(value) },
            .@"enum" => |enu| {
                if (enu.mode == .nonexhaustive) @compileError("Non-exhaustive enum");
                if (@bitSizeOf(enu.tag_type) > 32) @compileError("Bad enum type");
                const UTag = @Int(.unsigned, @bitSizeOf(enu.tag_type));
                break :sw .{ .@"enum" = @as(UTag, @bitCast(@backingInt(value))) };
            },
            inline else => |_, tag| @compileError("Unknown type: " ++ @typeName(V) ++ " (" ++ @tagName(tag) ++ ")"),
        };
    }
};

pub const StateHolder = struct {
    owner: union {
        block: *Block.State,
        /// TODO: Implement fluids.
        fluid: *anyopaque,
    },
    /// Available properties
    property_keys: []const Property,
    vtable: *const VTable,

    pub const VTable = struct {
        setProperty: *const fn (self: *StateHolder, property_index: usize, value: PropertyValue) *anyopaque,
    };
};

pub const State = struct {
    /// A unique ID between all possible block states.
    state_id: Id,
    owner: *Block,

    pub const Id = enum(u32) { _ };

    pub inline fn dummyIota(comptime N: u32, comptime start: u32) [N]State {
        comptime {
            @setEvalBranchQuota(N);

            var arr: [N]State = undefined;
            for (0..N) |i| {
                arr[i].state_id = @fromBackingInt(@intCast(start + i));
            }
            return arr;
        }
    }

    pub fn dummy(id: Block.Id) State {
        return dummyIota(1, @backingInt(id))[0];
    }

    pub fn eql(self: *const State, other: *const State) bool {
        return self == other;
    }
};

pub const Property = struct {
    name: []const u8,
    data: union(enum) {
        boolean,
        integer,
        /// Value cannot be accessed at runtime, only the tag can i think
        @"enum": type,
    },

    pub const Value = union(enum) {
        boolean: bool,
        integer: i32,
        /// Unsigned but the backing integer used might be.
        @"enum": u32,
    };

    pub fn valueFrom(comptime self: Property, value: anytype) PropertyValue {
        const V = @TypeOf(value);
        const info = @typeInfo(V);
        switch (self.data) {
            .boolean => {
                if (info != .bool) @compileError("No boolean");
                return .{ .boolean = value };
            },
            // TODO, ts pissing me of
        }
    }
};
