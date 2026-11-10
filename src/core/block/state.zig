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

pub const PropertyType = enum {
    
};

pub const PropertiesValues = opaque {};

pub const StateHolder = struct {
    properties: []const Property.Compiled,
    data: *const PropertiesValues,
    siblings: [*]const *anyopaque,
};

pub const State = struct {
    /// A unique ID between all possible block states.
    state_id: Id,
    owner: *Block,
    holder: StateHolder,

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
        integer: struct {
            min: i32,
            max: i32,
            /// Ranged between 1 and 8.
            bits: u3,
        },
        @"enum": struct {
            fields: []const EnumField,
            /// Ranged between 1 and 8.
            bits: u3,
            /// This field cannot be accessed at runtime, but others can.
            type: type,
        },
    },

    pub const EnumField = struct { name: []const u8, value: i32 };

    pub const Compiled = struct {
        base: Property,
        /// Properties can only be 8 bits at most.
        ///
        /// Ranged between 1 and 8.
        bit_size: u3,
        /// u8's gives a 32 bytes addressing capability.
        bit_offset: u8,
        byte_mask: u8,


        pub fn valueFrom(comptime self: Compiled, value: anytype) Property.Value {
            return self.base.valueFrom(value);
        }

        pub fn get(self: Compiled, bytes: [*]const u8) u8 {

        }
    };

    pub const Value = union(enum) {
        boolean: bool,
        integer: i32,
        /// Unsigned but the backing integer used might be.
        @"enum": u32,
    };

    pub fn boolean(name: []const u8) Property {
        return .{ .name = name, .data = .boolean };
    }

    /// `bits` is asserted to be ranged from 1 to 8
    pub fn integer(name: []const u8, min: i32, max: i32, bits: u4) Property {
        assert(bits >= 1 and bits <= 8);
        return .{
            .name = name,
            .data = .{ .integer = .{
                .min = min,
                .max = max,
                .bits = @truncate(bits -% 1),
            } },
        };
    }

    pub fn @"enum"(comptime E: type, name: []const u8) Property {
        const info = @typeInfo(E).@"enum";
        return .{
            .name = name,
            .data = .{ .@"enum" = .{
                .fields = comptime blk: {
                    var fields: [info.field_names.len]EnumField = undefined;
                    for (&fields, info.field_names, info.field_values) |*out, fname, value| {
                        out.* = .{ .name = fname, .value = value };
                    }
                    const c_fields = fields;
                    break :blk &c_fields;
                },
                .bits = @bitSizeOf(info.tag_type) - 1,
                .type = E,
            } },
        };
    }

    pub fn valueFrom(comptime self: Property, value: anytype) error{BadValue}!Property.Value {
        const V = @TypeOf(value);
        const info = @typeInfo(V);
        switch (self.data) {
            .boolean => {
                if (info != .bool) @compileError("Expected bool, found: " ++ @typeName(V));
                return .{ .boolean = value };
            },
            .integer => |int| switch (info) {
                .comptime_int => {
                    if (value < int.min and value > int.max) @compileError(std.fmt.comptimePrint("IntegerProperty({q}) must be between {d} and {d}, got: {d}", .{
                        self.name, int.min, int.max, value,
                    }));
                    return .{ .integer = @intCast(value) };
                },
                .int => return .{ .integer = @intCast(value) },
                else => @compileError("Expected integer, found: " ++ @typeName(V)),
            },
            .@"enum" => |_enum| {
                const E = _enum.type;
                const val: E = if (info == .enum_literal)
                    value
                else if (V != E)
                    @compileError("Mismatch types: " ++ @typeName(V) ++ ", expected: " ++ @typeName(E))
                else
                    value;

                const enu = @typeInfo(E);
                if (enu.mode == .nonexhaustive) @compileError("Non-exhaustive enum");
                if (@bitSizeOf(enu.tag_type) > 32) @compileError("Bad enum type");
                const UTag = @Int(.unsigned, @bitSizeOf(enu.tag_type));
                return .{ .@"enum" = @as(UTag, @bitCast(@backingInt(val))) };
            },
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
