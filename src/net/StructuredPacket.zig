const StructuredPacket = @This();
const std = @import("std");
const utils = @import("utils");
const TextComponent = utils.TextComponent;
const UUID = utils.UUID;
const Identifier = utils.Identifier;
const GameProfile = utils.GameProfile;

const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const json = std.json;
const NBT = utils.NBT;

const logger = std.log.scoped(.packet);

fn IntWithRange(comptime I: type) type {
    return struct {
        pub fn format(_: @This(), writer: *Writer) Writer.Error!void {
            return writer.print("{s}[{d}..{d}]", .{
                @typeName(I), std.math.minInt(I), std.math.maxInt(I),
            });
        }
    };
}

fn noRead(_: Allocator, _: *Reader, _: anytype, _: *anyopaque) Type.ReadError!void {
    @compileError("Cannot read this type");
}

fn noWrite(_: Allocator, _: *Writer, _: *anyopaque) Type.WriteError!void {
    @compileError("Cannot write this type");
}

name: []const u8 = "<unnamed>",
fields: []const Field = &.{},

pub const sound_event = StructuredPacket{
    .name = "SoundEvent",
    .fields = &.{
        .{ .name = "name", .type = .identifier },
        .{ .name = "fixed_range", .type = .{ .optional = .prefixed(.bool) } },
    },
};

pub const chat_type = StructuredPacket{
    .name = "ChatType",
    .fields = &.{
        .{ .name = "chat", .type = .chat_decoration },
        .{ .name = "narration", .type = .chat_decoration },
    },
};

pub const chat_decoration = StructuredPacket{
    .name = "ChatDecoration",
    .fields = &.{
        .{ .name = "translation", .type = .{ .string = 0x7FFF } },
        .{ .name = "parameters", .type = .{ .array = .prefixed(.{
            .@"enum" = .of(ChatDecorationParameter, .var_int),
        }) } },
        .{ .name = "style", .type = .nbt },
    },
};

pub const ChatDecorationParameter = enum { sender, target, content };

pub const TeleportFlags = enum {
    rel_x,
    rel_y,
    rel_z,
    rel_yaw,
    rel_pitch,
    rel_velocity_x,
    rel_velocity_y,
    rel_velocity_z,
    /// Rotate velocity according to the change in rotation,
    /// before applying the velocity change in this packet.
    /// Combining this with absolute rotation works as expected;
    /// the difference in rotation is still used.
    ///
    /// I honest to god do not know what this bs means.
    rot_velocity,
};

pub const BlockPosition = packed struct(u64) {
    x: u26,
    z: u26,
    y: u12,

    pub fn format(self: BlockPosition, writer: *Writer) Writer.Error!void {
        return writer.print("{{ {d}, {d}, {d}}}", .{ self.x, self.y, self.z });
    }
};

pub const Field = struct {
    name: [:0]const u8,
    type: Type,
};

pub const IdSet = union(enum) { tag: Identifier, ids: []u32 };

pub const Type = union(enum) {
    custom: struct {
        type: type,
        /// `out` is `*<.type>`
        readFn: fn (arena: Allocator, reader: *Reader, parent: anytype, out: anytype) ReadError!void,
        /// `val` is `<.type>`
        writeFn: fn (arena: Allocator, writer: *Writer, val: anytype) WriteError!void,
    },
    structured: StructuredPacket,
    bool,
    /// The value is whether the value is
    /// signed/unsigned.
    byte: std.builtin.Signedness,
    /// The value is whether the value is
    /// signed/unsigned.
    short: std.builtin.Signedness,
    int,
    long,
    float,
    double,
    /// The value is the maximum number of
    /// UTF8 codepoints this string can comport.
    string: u15,
    json: ?type,
    identifier,
    var_int,
    var_long,
    entity_metadata,
    slot,
    hashed_slot,
    nbt: ?type,
    block_position,
    byte_angle,
    uuid,
    /// The value represents the size of the bitset in *bits*
    /// or `null` to make it dynamic.
    bitset: ?usize,
    optional: Optional,
    array: Array,
    /// `.sub ` should only be an enum type.
    ///
    /// See [Zig's enum documentation](https://ziglang.org/documentation/0.15.2/#enum).
    @"enum": IntBacked,
    /// The resulting zig type will be a `std.EnumSet(<value>)`.
    ///
    /// If you want to introduce a mask gap, you may use a `_unused<X>` where `<X>` is
    /// whatever number, or any other mean to discard it.
    ///
    /// `.sub ` should only be an enum type.
    ///
    /// See [Zig's enum documentation](https://ziglang.org/documentation/0.15.2/#enum).
    enum_set: IntBacked,
    /// `.sub ` should only be a packed struct.
    packed_struct: IntBacked,
    /// Resolves to `IdOr(<value>)`.
    id_or_x: *const Type,
    id_set,
    /// Resolves to `Either(<value>[0], <value>[1])`
    either: *const [2]Type,
    game_profile,

    pub const ibyte = Type{ .byte = .signed };
    pub const ubyte = Type{ .byte = .unsigned };
    pub const ishort = Type{ .short = .signed };
    pub const ushort = Type{ .short = .unsigned };
    pub const byte_array = Type{ .array = .prefixed(ubyte) };
    pub const sound_event = Type{ .structured = .sound_event };
    pub const chat_type = Type{ .structured = .chat_type };
    pub const chat_decoration = Type{ .structured = .chat_decoration };
    pub const teleport_flags = Type{ .enum_set = .of(TeleportFlags, .u32) };
    pub const max_string = Type{ .string = 0x7FFF };
    pub const nbt_text_component = Type{ .nbt = TextComponent };
    pub const json_text_component = Type{ .json = TextComponent };

    pub const TCSerialType = enum { nbt, json };
    pub const BackingInteger = enum {
        i8,
        u8,
        i16,
        u16,
        i32,
        i64,
        var_int,
        var_long,

        pub fn getProtoType(comptime self: BackingInteger) type {
            return switch (self) {
                .i8 => i8,
                .u8 => u8,
                .i16 => i16,
                .u16 => u16,
                .i32, .var_int => i32,
                .i64, .var_long => i64,
            };
        }

        pub fn format(self: BackingInteger, writer: *Writer) Writer.Error!void {
            return writer.writeAll(switch (self) {
                .var_int => "VarInt",
                .var_long => "VarLong",
                else => @tagName(self),
            });
        }
    };
    pub const IntCastType = enum {
        /// Will clamp the value between zero and `std.math.maxInt(usize)`.
        clamp,
        /// Will return `error.InvalidLength` on invalid values.
        @"error",
    };
    pub const Optional = struct {
        sub: *const Type,
        condition: union(enum) {
            prefixed,
            bool_field: []const u8,
            field_cmp: struct {
                name: []const u8,
                op: std.math.CompareOperator,
                value: *const anyopaque,
            },
            field_mask: struct {
                name: []const u8,
                value: comptime_int,
            },
        } = .prefixed,

        pub fn prefixed(comptime sub: Type) Optional {
            return .{ .sub = &sub };
        }
    };
    pub const Array = struct {
        sub: *const Type,
        /// `null` means it will be encoded as a VarInt.
        size: union(enum) {
            /// Read until end of stream.
            remaining,
            /// The value represents the max size of this array.
            prefixed: usize,
            /// Always this size
            fixed: usize,
        } = .{ .prefixed = std.math.maxInt(usize) },

        pub fn remaining(comptime sub: Type) Array {
            return .{ .sub = &sub, .size = .remaining };
        }

        pub fn prefixed(comptime sub: Type) Array {
            return .{ .sub = &sub };
        }

        pub fn prefixedMax(comptime sub: Type, comptime max_size: usize) Array {
            return .{ .sub = &sub, .size = .{ .prefixed = max_size } };
        }

        pub fn fixed(comptime sub: Type, comptime size: usize) Array {
            return .{ .sub = &sub, .size = .{ .fixed = size } };
        }
    };
    pub const IntBacked = struct {
        base: type,
        backing: BackingInteger,

        pub fn of(comptime Base: type, comptime backing: BackingInteger) IntBacked {
            return .{ .base = Base, .backing = backing };
        }
    };

    pub const ReadError = Identifier.ValidationError || Reader.TakeLeb128Error || Reader.ReadAllocError || error{
        InvalidUTF8,
        InvalidLength,
        InvalidJSON,
        InvalidEnumTag,
        InvalidNumber,
    };

    pub const WriteError = Allocator.Error || Writer.Error || NBT.WriteError || error{InvalidUTF8};

    pub fn getZigType(comptime self: Type) type {
        return switch (self) {
            .custom => |c| c.type,
            .structured => |desc| blk: {
                var names: [desc.fields.len][]const u8 = undefined;
                var types: [desc.fields.len]type = undefined;
                var attrs: [desc.fields.len]std.builtin.Type.StructField.Attributes = undefined;

                for (desc.fields, 0..) |field, i| {
                    names[i] = field.name;
                    types[i] = field.type.getZigType();
                    attrs[i] = .{};
                }

                break :blk @Struct(.auto, null, &names, &types, &attrs);
            },
            .bool => bool,
            .byte => |s| @Int(s, 8),
            .short => |s| @Int(s, 16),
            .int, .var_int => i32,
            .long, .var_long => i64,
            .float => f32,
            .double => f64,
            .string => []const u8,
            .json => |may_sub| if (may_sub) |sub| sub else json.Value,
            .identifier => Identifier,
            .entity_metadata => void, // TODO: Implement entity_metadata
            .slot => void, // TODO: Implement slot
            .hashed_slot => void, // TODO: Implement hashed_slot
            .nbt => |may_sub| if (may_sub) |sub| sub else NBT.Value,
            .block_position => BlockPosition,
            .byte_angle => u8,
            .uuid => UUID,
            .bitset => |may_bits| if (may_bits) |bits| blk: {
                assert(bits > 0);
                break :blk std.StaticBitSet(bits);
            } else std.DynamicBitSetUnmanaged,
            .optional => |o| ?o.sub.getZigType(),
            .array => |a| switch (a.size) {
                .fixed => |n| [n]a.sub.getZigType(),
                else => []a.sub.getZigType(),
            },
            .@"enum" => |ib| if (@typeInfo(ib.base) != .@"enum")
                @compileError("enum base-type must be an enum")
            else if (!intCanBeCasted(@typeInfo(ib.base).@"enum".tag_type, ib.backing.getProtoType()))
                @compileError(std.fmt.comptimePrint("Enum protocol integer cannot fit enum tag integer: {f} -/> {f}", .{
                    IntWithRange(@typeInfo(ib.base).@"enum".tag_type),
                    IntWithRange(ib.backing.getProtoType()),
                }))
            else
                ib.base,
            .enum_set => |ib| if (@typeInfo(ib.base) != .@"enum")
                @compileError("enum_set base-type must be an enum")
            else
                std.EnumSet(ib.base),
            .packed_struct => |ib| blk: {
                const info = @typeInfo(ib.base);
                if (info != .@"struct" or info.@"struct".layout != .@"packed")
                    @compileError("packed_struct base-type must be a packed struct");
                if (!intCanBeCasted(info.@"struct".backing_integer.?, ib.backing.getProtoType()))
                    @compileError("packed_struct backing integer is too small to contain base-type");
                break :blk ib.base;
            },
            .id_or_x => |sub| IdOr(sub.getZigType()),
            .id_set => IdSet,
            .either => |subs| Either(subs[0], subs[1]),
            .game_profile => GameProfile,
        };
    }

    fn jsonFmtString(comptime T: type) []const u8 {
        return switch (@typeInfo(T)) {
            .comptime_int, .comptime_float, .int, .float => "{d}",
            .@"struct", .@"union", .@"enum" => if (std.meta.hasMethod(T, "format")) "{f}" else "{any}",
            .pointer => |ptr| switch (ptr.size) {
                .one => jsonFmtString(ptr.child),
                .slice => "{any}",
                else => |tag| @compileError("Impossible to get formatting string for " ++
                    @tagName(tag) ++ " pointer"),
            },
            .optional => |opt| "?" ++ jsonFmtString(opt.child),
            else => "{any}",
        };
    }

    pub fn Formatted(comptime self: Type) type {
        return struct {
            value: self.getZigType(),

            pub fn format(fmtd: @This(), writer: *Writer) Writer.Error!void {
                const value = fmtd.value;
                switch (self) {
                    .custom => |c| try writer.print(
                        if (std.meta.hasMethod(c.type, "format")) "{f}" else "{any}",
                        .{value},
                    ),
                    .structured => |desc| {
                        try writer.writeAll(desc.name);
                        try writer.writeAll("{ ");
                        inline for (desc.fields, 0..) |field, i| {
                            try writer.print("{s}: {f}", .{
                                field.name,
                                field.type.formatted(@field(value, field.name)),
                            });
                            if (i + 1 < desc.fields.len) {
                                try writer.writeAll(", ");
                            }
                        }
                        try writer.writeAll(" }");
                    },
                    .bool => try writer.print("{any}", .{value}),

                    inline .byte,
                    .short,
                    .int,
                    .long,
                    .float,
                    .double,
                    .var_int,
                    .var_long,
                    => try writer.print("{d}", .{value}),

                    .string => try writer.print("\"{s}\"", .{value}),

                    .json => |may_sub| {
                        if (may_sub) |Sub| {
                            try writer.print(jsonFmtString(Sub), .{value});
                        } else {
                            try writer.print("\"{f}\"", .{json.fmt(
                                value,
                                .{ .whitespace = .indent_2 },
                            )});
                        }
                    },

                    .identifier, .uuid, .game_profile, .block_position => try value.format(writer),

                    .entity_metadata => try writer.writeAll("EntityMetadata"),

                    inline .slot,
                    .hashed_slot,
                    .nbt,
                    => |_, tag| try writer.print("<{s} Not Yet Implemented>", .{tag}),

                    .byte_angle => try writer.print("{d}", .{@as(f32, @floatFromInt(value)) * (360.0 / 255.0)}),
                    .bitset => |may_bits| if (may_bits) |bits| {
                        if (@hasField(@TypeOf(value), "masks")) {
                            const MaskInt = @TypeOf(value).MaskInt;
                            var remaining_bits: usize = bits;
                            inline for (value.masks) |m| {
                                try writer.print(std.fmt.comptimePrint("{{b:0>{d}}}", .{
                                    @min(remaining_bits, @bitSizeOf(MaskInt)),
                                }), .{m});
                                remaining_bits -= @bitSizeOf(MaskInt);
                            }
                        } else {
                            try writer.print(std.fmt.comptimePrint("{{b:0>{d}}}", .{bits}), .{
                                value.mask,
                            });
                        }
                    } else for (value.masks) |m| {
                        try writer.print("{b:0>64}", .{m});
                    },
                    .optional => |opt| try if (value) |val|
                        writer.print("{f}", .{opt.sub.formatted(val)})
                    else
                        writer.writeAll("null"),
                    .array => |arr| {
                        try writer.print("[{d}] {{ ", .{value.len});
                        for (value, 0..) |v, i| {
                            try arr.sub.formatted(v).format(writer);
                            if (i + 1 < value.len) {
                                try writer.writeAll(", ");
                            }
                        }
                        try writer.writeAll(" }");
                    },
                    .@"enum" => try writer.print(".{t}({d})", .{ value, @intFromEnum(value) }),
                    .enum_set => |ib| {
                        try writer.print("EnumSet({any}) {{ ", .{ib.base});
                        var it = value.iterator();
                        var do_comma: bool = false;
                        while (it.next()) |v| {
                            if (do_comma) try writer.writeAll(", ");
                            do_comma = true;
                            try if (std.meta.hasMethod(ib.base, "format"))
                                v.format(writer)
                            else
                                writer.print(".{t}", .{v});
                        }
                        try writer.writeAll(" }");
                    },
                    .packed_struct => |ib| try if (std.meta.hasMethod(ib.base, "format"))
                        value.format(writer)
                    else
                        writer.print("{any}", .{value}),
                    .id_or_x => |sub| try switch (value) {
                        .id => |id| writer.print("IdOr({f}).id{{{d}}}", .{
                            sub, id,
                        }),
                        .value => |val| writer.print("IdOr({f}).value{{{f}}}", .{
                            sub, sub.formatted(val),
                        }),
                    },
                    .id_set => switch (value) {
                        .tag => |tag| try writer.print("IdSet.tag{{{s}}}", .{tag.id}),
                        .ids => |ids| {
                            try writer.writeAll("IdSet.ids{ ");
                            for (ids, 0..) |id, i| {
                                try writer.print("{d}", .{id});
                                if (i + 1 < ids.len) {
                                    try writer.writeAll(", ");
                                }
                            }
                            try writer.writeAll(" }");
                        },
                    },
                    .either => |subs| switch (value) {
                        inline else => |v, tag| writer.print("XorY({f}, {f}).{t}{{{f}}}", .{
                            subs[0], subs[1], tag, subs[@intFromEnum(tag)].formatted(v),
                        }),
                    },
                }
            }
        };
    }

    pub inline fn formatted(comptime self: Type, value: self.getZigType()) self.Formatted() {
        return .{ .value = value };
    }

    pub fn limitedString(comptime max_size: u15) Type {
        return .{ .string = max_size };
    }

    pub fn prefixedOptional(comptime sub: Type) Type {
        return .{ .optional = .prefixed(sub) };
    }

    pub fn prefixedArray(comptime sub: Type) Type {
        return .{ .array = .prefixed(sub) };
    }

    pub fn prefixedMaxArray(comptime sub: Type, comptime max_size: usize) Type {
        return .{ .array = .prefixedMax(sub, max_size) };
    }

    pub fn fixedArray(comptime sub: Type, comptime size: usize) Type {
        return .{ .array = .fixed(sub, size) };
    }

    pub fn remainingArray(comptime sub: Type) Type {
        return .{ .array = .remaining(sub) };
    }

    /// Data given with `reader` MUST be all available without any rebasing.
    pub fn read(comptime self: Type, arena: Allocator, reader: *Reader, parent: anytype, ret: *self.getZigType()) ReadError!void {
        if (@typeInfo(@TypeOf(parent)) != .@"struct") @compileError("Parent argument must be a struct type");
        ret.* = sw: switch (self) {
            .custom => |c| {
                try c.readFn(arena, reader, parent, ret);
                break :sw ret.*;
            },
            .structured => |desc| {
                inline for (desc.fields) |field| {
                    try field.type.read(
                        arena,
                        reader,
                        if (@typeInfo(@TypeOf(parent)).@"struct".fields.len == 0)
                            ret.*
                        else
                            parent,
                        &@field(ret, field.name),
                    );
                }
                break :sw ret.*;
            },
            .bool => try reader.takeByte() != 0,
            .byte => @bitCast(try reader.takeByte()),
            .short => |s| try reader.takeInt(@Int(s, 16), .big),
            inline .int, .long, .float, .double => |_, tag| {
                const bits = switch (tag) {
                    .int, .float => 32,
                    .long, .double => 64,
                    else => unreachable,
                };
                const Int = @Int(.unsigned, bits);
                break :sw @bitCast(try reader.takeInt(Int, .big));
            },
            inline .var_int, .var_long => |_, tag| {
                const bits = switch (tag) {
                    .var_int => 32,
                    .var_long => 64,
                    else => unreachable,
                };
                const Int = @Int(.unsigned, bits);
                break :sw @bitCast(try readVarIntMax(reader, Int, std.math.maxInt(Int)));
            },
            .string => |may_max_cps| try readString(reader, may_max_cps),
            .json => |may_sub| {
                const Sub = may_sub orelse json.Value;
                const str = try readString(reader, null);
                const value = json.parseFromSliceLeaky(Sub, arena, str, .{
                    .allocate = .alloc_if_needed,
                }) catch |e| {
                    logger.err("Error parsing JSON value of {any}: {t}", .{ Sub, e });
                    return error.InvalidJSON;
                };
                break :sw value;
            },
            .identifier => {
                const str = try readString(reader, null);
                break :sw Identifier.validate(str) catch |e| {
                    logger.err("Invalid identifier: [{s}]", .{str});
                    return e;
                };
            },
            .entity_metadata => @compileError("Not Yet Implemented"),
            .slot => @compileError("Not Yet Implemented"),
            .hashed_slot => @compileError("Not Yet Implemented"),
            .nbt => |may_sub| try if (may_sub) |sub|
                sub.nbtRead(reader, arena)
            else
                NBT.readValueLeaky(reader, arena),
            .block_position => @bitCast(@byteSwap(try reader.takeInt(u64, .big))),
            .byte_angle => try reader.takeByte(),
            .uuid => .{ .value = try reader.takeInt(u128, .big) },
            .bitset => |may_bits| {
                comptime assert(@bitSizeOf(usize) == 64);
                if (may_bits) |bits| {
                    const BitSet = @TypeOf(ret.*);
                    ret.* = .initEmpty();
                    if (@hasField(BitSet, "masks")) {
                        const num_bytes = @divFloor(bits - 1, 8) + 1;
                        try reader.readSliceAll(@as([*]u8, @ptrCast(&ret.masks))[0..num_bytes]);
                    } else {
                        ret.mask = @truncate(try reader.takeInt(std.math.ByteAlignedInt(BitSet.MaskInt), .big));
                    }
                    break :sw ret.*;
                } else {
                    const num_longs = try readVarIntMax(reader, i32, std.math.maxInt(i32));
                    if (num_longs < 0) {
                        logger.err("Received negative bitset length", .{});
                        return error.InvalidLength;
                    }
                    if (num_longs == 0) break :sw .{};
                    const bits = @as(u32, @bitCast(num_longs)) * 64;
                    const bs = try std.DynamicBitSetUnmanaged.initEmpty(arena, bits);
                    try reader.readSliceAll(@ptrCast(bs.masks[0 .. num_longs / 64]));
                }
            },
            .optional => |opt| {
                const has_value = cond: switch (opt.condition) {
                    .prefixed => try reader.takeByte() != 0,
                    .bool_field => |name| @as(bool, @field(parent, name)),
                    .field_cmp => |cmp| {
                        const field = @field(parent, cmp.name);
                        const value_ptr = @as(*const @TypeOf(field), @ptrCast(@alignCast(cmp.value)));
                        if (std.meta.hasMethod(@TypeOf(field), "compare")) {
                            break :cond field.compare(cmp.op, value_ptr.*);
                        }
                        const ct_err_message = "field_cmp can only be used with integers, packed struct (only .eq) or " ++
                            "types implementing a 'compare(std.math.CompareOperator, Self)' method";
                        break :cond switch (@typeInfo(@TypeOf(field))) {
                            .int, .float => std.math.compare(field, cmp.op, cmp.value),
                            .@"struct" => |s| {
                                if (s.layout != .@"packed" and cmp.op != .eq)
                                    @compileError(ct_err_message);
                                break :cond field == value_ptr.*;
                            },
                            .@"enum" => std.math.compare(@intFromEnum(field), cmp.op, @intFromEnum(value_ptr.*)),
                            else => @compileError(ct_err_message),
                        };
                    },
                    .field_mask => |fm| (@field(parent, fm.name) & fm.value) == fm.value,
                };
                if (!has_value) break :sw null;
                var val: opt.sub.getZigType() = undefined;
                try opt.sub.read(arena, reader, parent, &val);
                break :sw val;
            },
            .array => |arr| {
                const Sub = arr.sub.getZigType();
                switch (arr.size) {
                    .remaining => switch (self) {
                        inline .byte, .short, .int, .long, .float, .double, .uuid => {
                            var alloc_w = try Writer.Allocating.initCapacity(
                                arena,
                                reader.buffer.end - reader.seek,
                            );
                            defer alloc_w.deinit();

                            reader.streamRemaining(&alloc_w.writer) catch |e| return switch (e) {
                                error.WriteFailed => error.OutOfMemory,
                                error.ReadFailed => error.ReadFailed,
                            };
                            if (@sizeOf(Sub) != 1) {
                                if (alloc_w.writer.end % @sizeOf(Sub) != 0) {
                                    return error.InvalidLength;
                                }
                                std.mem.byteSwapAllElements(Sub, @ptrCast(alloc_w.written()));
                            }

                            ret.* = @ptrCast(try alloc_w.toOwnedSlice());
                        },
                        else => {
                            var array = std.ArrayList(Sub).empty;
                            defer array.deinit(arena);

                            while (true) {
                                const elem = try array.addOne(arena);
                                arr.sub.read(arena, reader, parent, elem) catch |e| switch (e) {
                                    error.EndOfStream => break,
                                    else => |err| return err,
                                };
                            }

                            ret.* = try array.toOwnedSlice(arena);

                            break :sw ret.*;
                        },
                    },
                    .prefixed => {
                        const len = try readVarIntMax(reader, i32, std.math.maxInt(i32));
                        if (len < 0) {
                            logger.err("Array length is less than 0", .{});
                            return error.InvalidLength;
                        }
                        if (len == 0) break :sw &.{};
                        if (arr.sub != .custom and @sizeOf(Sub) == 1) {
                            const array = try arena.alloc(Sub, @intCast(len));
                            errdefer arena.free(array);

                            try reader.readSliceAll(@ptrCast(array));

                            break :sw array;
                        }

                        var array = try std.ArrayList(Sub)
                            .initCapacity(arena, @intCast(len));
                        defer array.deinit(arena);

                        for (0..array.capacity) |_| {
                            const val = array.addOneAssumeCapacity(arena);
                            errdefer _ = array.pop();
                            try arr.sub.read(arena, reader, parent, val);
                        }

                        break :sw try array.toOwnedSlice(arena);
                    },
                    .fixed => return switch (arr.sub.*) {
                        .byte => try reader.readSliceAll(ret),
                        .short, .int, .long, .float, .double => try reader.readSliceEndian(
                            Sub,
                            ret,
                            .big,
                        ),
                        else => for (ret) |*val| try arr.sub.read(arena, reader, parent, val),
                    },
                }
                comptime unreachable;
            },
            .@"enum" => |ib| {
                const ProtoInt = ib.backing.getProtoType();
                const enum_int = switch (ib.backing) {
                    .var_int, .var_long => try readVarIntMax(reader, ProtoInt, std.math.maxInt(ProtoInt)),
                    else => try reader.takeInt(ProtoInt, .big),
                };
                break :sw std.enums.fromInt(ib.base, enum_int) orelse {
                    logger.err("Invalid enum tag for {s}: {d}", .{
                        @typeName(ProtoInt), enum_int,
                    });
                    return error.InvalidEnumTag;
                };
            },
            .enum_set => |ib| {
                const info = @typeInfo(ib.base);
                if (info != .@"enum") @compileError("Invalid enum type: " ++ @tagName(info));
                const ES = std.EnumSet(ib.base);
                const BitSet = @FieldType(ES, "bits");
                if (@hasField(BitSet, "masks")) {
                    const num_bytes = @divFloor(ES.len - 1, 8) + 1;
                    try reader.readSliceAll(@as([*]u8, @ptrCast(&ret.bits.masks))[0..num_bytes]);
                } else {
                    ret.bits.mask = @truncate(try reader.takeInt(std.math.ByteAlignedInt(BitSet.MaskInt), .big));
                }
                break :sw ret.*;
            },
            .packed_struct => |ib| {
                const ProtoInt = ib.backing.getProtoType();
                const UProtoInt = @Int(.unsigned, @bitSizeOf(ProtoInt));
                const BackInt = @typeInfo(ib.base).@"struct".backing_integer.?;
                const val_int = switch (ib.backing) {
                    .var_int, .var_long => try readVarIntMax(reader, UProtoInt, std.math.maxInt(BackInt)),
                    else => try reader.takeInt(UProtoInt, .big),
                };
                break :sw @bitCast(@as(BackInt, @truncate(val_int)));
            },
            .id_or_x => |sub| {
                const id = try readVarIntMax(reader, i32, std.math.maxInt(i32));
                if (id < 0) {
                    logger.err("Id is less than 0: {d}", .{id});
                    return error.InvalidNumber;
                }
                if (id == 0) {
                    ret.* = .{ .value = undefined };
                    try sub.read(arena, reader, parent, &ret.value);
                    break :sw ret.*;
                }
                break :sw .{ .id = @bitCast(id -% 1) };
            },
            .id_set => {
                const _type = try readVarIntMax(reader, i32, std.math.maxInt(i32));
                if (_type < 0) {
                    logger.err("Invalid negative ID set type: {d}", .{_type});
                }
                if (_type == 0) {
                    const str = try readString(reader, null);
                    break :sw .{ .tag = Identifier.validate(str) catch |e| {
                        logger.err("Invalid identifier: [{s}]", .{str});
                        return e;
                    } };
                }

                const len: usize = @intCast(_type - 1);
                const ids = try arena.alloc(u32, len);
                errdefer arena.free(ids);

                for (ids, 0..) |*val, i| {
                    const id = try readVarIntMax(reader, i32, std.math.maxInt(i32));
                    if (id < 0) {
                        logger.err("Invalid negative ID in id_set[{d}]: {d}", .{
                            i, id,
                        });
                    }
                    val.* = @bitCast(id);
                }

                break :sw .{ .ids = ids };
            },
            .either => |subs| {
                const which = try reader.takeByte();
                if (which == 0) {
                    ret.* = .{ .a = undefined };
                    try subs[0].read(arena, reader, parent, &ret.a);
                } else {
                    ret.* = .{ .b = undefined };
                    try subs[1].read(arena, reader, parent, &ret.b);
                }
                break :sw ret.*;
            },
            .game_profile => {
                const uuid = UUID{ .value = try reader.takeInt(u128, .big) };
                const username = try readString(reader, 16);
                for (username) |c| {
                    if (c <= 32 or c >= 127) return error.InvalidCharacter;
                }
                const prop_count = readVarIntMax(reader, u8, 16) catch {
                    logger.err("GameProfile.properties.len exceeded 16 elements", .{});
                    return error.Overflow;
                };

                const props = try arena.alloc(GameProfile.Property, prop_count);
                for (props) |*pout| {
                    const name = try readString(reader, 64);
                    const value = try readString(reader, 0x7FFF);
                    const sig = if (try reader.takeByte() != 0)
                        try readString(reader, 1024)
                    else
                        null;

                    pout.lengths = .{
                        .name = @intCast(name.len),
                        .value = @intCast(value.len),
                        .signature = if (sig) |s| @intCast(s.len) else 0,
                    };
                    pout.name_ptr = name.ptr;
                    pout.value_ptr = value.ptr;
                    pout.signature_ptr = if (sig) |s| s.ptr else null;
                }

                break :sw .{
                    .uuid = uuid,
                    .lengths = .{
                        .username = @intCast(username.len),
                        .properties = @intCast(prop_count),
                    },
                    .username_ptr = username.ptr,
                    .properties_ptr = props.ptr,
                };
            },
        };
    }

    pub fn write(comptime self: Type, arena: Allocator, writer: *Writer, val: self.getZigType()) WriteError!void {
        switch (self) {
            .custom => |c| try c.writeFn(arena, writer, val),
            .structured => |desc| inline for (desc.fields) |field| {
                try field.type.write(arena, writer, @field(val, field.name));
            },
            .bool => try writer.writeByte(@intFromBool(val)),
            .byte => try writer.writeByte(@bitCast(val)),
            inline .short, .int, .long => try writer.writeInt(@TypeOf(val), val, .big),
            inline .float, .double => try writer.writeInt(
                @Int(.unsigned, @bitSizeOf(@TypeOf(val))),
                @bitCast(val),
                .big,
            ),
            .string => try writeString(writer, val),
            .json => {
                var alloc_w = Writer.Allocating.init(arena);
                json.fmt(val, .{})
                    .format(&alloc_w.writer) catch return error.OutOfMemory;

                try writeString(writer, alloc_w.written());
            },
            .identifier => try writeString(writer, val.id),
            inline .var_int, .var_long => try writeVarInt(writer, val),
            .entity_metadata => @compileError("Not Yet Implemented"),
            .slot => @compileError("Not Yet Implemented"),
            .hashed_slot => @compileError("Not Yet Implemented"),
            .nbt => |may_sub| try if (may_sub != null)
                val.nbtWrite(writer)
            else
                val.writeTo(writer),
            .block_position => try writer.writeInt(u64, @bitCast(val), .big),
            .byte_angle => try writer.writeByte(val),
            .uuid => try writer.writeInt(u128, val.value, .big),
            .bitset => |may_bits| blk: {
                if (may_bits) |bits| {
                    try writer.writeAll(@as([]const u8, @ptrCast(&val))[0 .. @divFloor(bits - 1, 8) + 1]);
                } else {
                    if (val.bit_length == 0) {
                        try writeVarInt(writer, @as(u1, 0));
                        break :blk;
                    }
                    const len = @divFloor(val.bit_length - 1, 64) + 1;
                    try writeVarInt(writer, len);
                    try writer.writeAll(@ptrCast(val.masks[0..len]));
                }
            },
            .optional => |opt| {
                if (val) |value| {
                    if (opt.condition == .prefixed) try writer.writeByte(1);
                    try opt.sub.write(arena, writer, value);
                } else try writer.writeByte(0);
            },
            .array => |arr| blk: {
                const Sub = arr.sub.getZigType();
                switch (arr.size) {
                    .prefixed => {
                        try writeVarInt(writer, val.len);
                        if (@sizeOf(Sub) == 1) {
                            try writer.writeAll(@ptrCast(val));
                            break :blk;
                        }
                    },
                    .fixed => if (@sizeOf(Sub) == 1) {
                        try writer.writeAll(@ptrCast(&val));
                        break :blk;
                    },
                    .remaining => if (@sizeOf(Sub) == 1) {
                        try writer.writeAll(@ptrCast(val));
                        break :blk;
                    },
                }
                for (val) |item| try arr.sub.write(arena, writer, item);
            },
            .@"enum" => |ib| switch (ib.backing) {
                .var_int, .var_long => try writeVarInt(writer, @intFromEnum(val)),
                else => try writer.writeInt(ib.backing.getProtoType(), @intFromEnum(val), .big),
            },
            .enum_set => |ib| {
                const ES = std.EnumSet(ib.base);
                const BitSet = @FieldType(ES, "bits");
                if (@hasField(BitSet, "masks")) {
                    const num_bytes = @divFloor(ES.len - 1, 8) + 1;
                    try writer.writeAll(@as([*]const u8, @ptrCast(&val.bits.masks))[0..num_bytes]);
                } else {
                    try writer.writeInt(std.math.ByteAlignedInt(BitSet.MaskInt), val.bits.mask, .big);
                }
            },
            .packed_struct => |ib| {
                const ProtoInt = ib.backing.getProtoType();
                const UProtoInt = @Int(.unsigned, @bitSizeOf(ProtoInt));
                const val_int: @typeInfo(ib.base).@"struct".backing_integer.? = @bitCast(val);
                const proto_val: UProtoInt = val_int;
                try writer.writeAll(@ptrCast(&proto_val));
            },
            .id_or_x => |sub| switch (val) {
                .id => |id| try writeVarInt(writer, id + 1),
                .value => |_val| {
                    try writer.writeByte(0);
                    try sub.write(arena, writer, _val);
                },
            },
            .id_set => {
                switch (val) {
                    .tag => |tag| {
                        try writer.writeByte(0);
                        try writeString(writer, tag.id);
                    },
                    .ids => |ids| {
                        try writer.writeByte(ids.len + 1);
                        for (ids) |id| try writeVarInt(writer, id);
                    },
                }
            },
            .either => |subs| switch (val) {
                .a => |v| {
                    try writer.writeByte(0);
                    try subs[0].write(arena, writer, v);
                },
                .b => |v| {
                    try writer.writeByte(1);
                    try subs[1].write(arena, writer, v);
                },
            },
            .game_profile => {
                try writer.writeInt(u128, val.uuid.value, .big);
                try writeString(writer, val.username());
                const props = val.properties();
                try writeVarInt(writer, props.len);
                for (props) |p| {
                    try writeString(writer, p.name());
                    try writeString(writer, p.value());
                    if (p.signature()) |sig| {
                        try writer.writeByte(1);
                        try writeString(writer, sig);
                    } else try writer.writeByte(0);
                }
            },
        }
    }

    pub fn format(comptime self: Type, writer: *Writer) Writer.Error!void {
        switch (self) {
            .custom => |c| try writer.print("Type.custom{{{s}}}", .{c.type}),
            .structured => |desc| {
                try writer.writeAll(desc.name);
                try writer.writeAll("{ ");
                inline for (desc.fields, 0..) |field, i| {
                    try writer.print("{s}: {f}", .{ field.name, field.type });
                    if (i + 1 < desc.fields.len) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(" }");
            },
            .bool => try writer.writeAll("bool"),
            .byte => |s| try writer.print("{c}byte", .{@tagName(s)[0]}),
            .short => |s| try writer.print("{c}short", .{@tagName(s)[0]}),
            inline .int, .long, .float, .double, .string => |_, tag| try writer.writeAll(@tagName(tag)),
            .json => |may_sub| try if (may_sub) |sub|
                writer.print("Json({any})", .{sub})
            else
                writer.writeAll("JsonValue"),
            .identifier => try writer.writeAll("Identifier"),
            .var_int => try writer.writeAll("VarInt"),
            .var_long => try writer.writeAll("VarLong"),
            .entity_metadata => try writer.writeAll("EntityMetadata"),
            .slot => try writer.writeAll("Slot"),
            .hashed_slot => try writer.writeAll("HashedSlot"),
            .nbt => try writer.writeAll("NBT"),
            .block_position => try writer.writeAll("BlockPos"),
            .byte_angle => try writer.writeAll("Angle"),
            .uuid => try writer.writeAll("UUID"),
            .bitset => |may_bits| if (may_bits) |bits|
                try writer.print("BitSet({d})", .{bits})
            else
                try writer.writeAll("BitSet"),
            .optional => |opt| {
                try writer.print("?{f}", .{opt.sub});
                switch (opt.condition) {
                    .prefixed => {},
                    .bool_field => |f| try writer.print(" (.{s} == true)", .{f}),
                    .field_cmp => |cmp| try writer.print(" (.{s} {s} {any})", .{
                        cmp.name,
                        switch (cmp.op) {
                            .lt => "<",
                            .lte => "<=",
                            .eq => "==",
                            .gte => ">=",
                            .gt => ">",
                            .neq => "!=",
                        },
                        cmp.value,
                    }),
                    .field_mask => |msk| try writer.print(" (.{s} & {b})", .{ msk.name, msk.value }),
                }
            },
            .array => |arr| switch (arr.size) {
                .remaining => try writer.print("[0..]{f}", .{arr.sub}),
                .prefixed => |max| try writer.print("[0..{d}]{f}", .{ max, arr.sub }),
                .fixed => |len| try writer.print("[{d}]{f}", .{ len, arr.sub }),
                .custom => try writer.print("[]{f}", .{arr.sub}),
            },
            .@"enum" => |ib| try writer.print("Enum({any}, {f})", .{ ib.base, ib.backing }),
            .enum_set => |ib| try writer.print("EnumSet({any}, {f})", .{ ib.backing, ib.base }),
            .packed_struct => |ib| try writer.print("PackedStruct({any}, {f})", .{ ib.backing, ib.base }),
            .id_or_x => |sub| try writer.print("IdOr({f})", .{sub}),
            .id_set => try writer.writeAll("IdSet"),
            .either => |subs| try writer.print("XorY({f}, {f})", .{ subs[0], subs[1] }),
            .game_profile => try writer.writeAll("GameProfile"),
        }
    }
};

pub fn IdOr(comptime T: type) type {
    return union(enum) { id: u32, value: T };
}

pub fn Either(comptime A: type, comptime B: type) type {
    return union(enum) { a: A, b: B };
}

pub fn getZigType(comptime self: StructuredPacket) type {
    return self.getType().getZigType();
}

pub inline fn intCanBeCasted(comptime From: type, comptime To: type) bool {
    const f_min = std.math.minInt(From);
    const f_max = std.math.maxInt(From);
    const t_min = std.math.minInt(To);
    const t_max = std.math.maxInt(To);
    return t_min <= f_min and f_max <= t_max;
}

pub inline fn writeVarInt(writer: *Writer, value: anytype) Writer.Error!void {
    return writer.writeLeb128(@as(@Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value)));
}

pub fn getType(comptime self: StructuredPacket) Type {
    return .{ .structured = self };
}

pub fn named(comptime name: []const u8) Type {
    return getType(.{ .name = name });
}

pub fn readVarIntMax(reader: *Reader, comptime T: type, max_val: T) Reader.TakeLeb128Error!T {
    const info = switch (@typeInfo(T)) {
        .int => |i| i,
        else => @compileError(@typeName(T) ++ " not supported"),
    };
    const UnsignedT = @Int(.unsigned, info.bits);
    const Byte = packed struct { bits: u7, more: bool };

    if (info.bits <= 7) {
        const byte: Byte = @bitCast(try reader.takeByte());
        const bits_as_T = @as(T, @bitCast(@as(UnsignedT, @truncate(byte.bits))));
        return if (byte.more or bits_as_T > max_val)
            error.Overflow
        else
            @truncate(byte.bits);
    }

    var result: UnsignedT = 0;
    const max_bytes = @divFloor(info.bits - 1, 7) + 1;
    inline for (0..max_bytes) |i| {
        const shift = 7 * i;
        const allowed_bits = comptime (std.math.maxInt(UnsignedT) >> shift) & 0x7F;
        const allow_more = comptime i < max_bytes - 1;

        const byte: Byte = @bitCast(try reader.takeByte());

        if (byte.more and !allow_more or
            byte.bits & allowed_bits != byte.bits) return error.Overflow;

        result |= @as(UnsignedT, byte.bits) << shift;
        if (!byte.more) break;
    }
    return if (result > max_val)
        error.Overflow
    else
        @bitCast(result);
}

pub fn readString(reader: *Reader, may_max_cps: ?u15) (Reader.TakeLeb128Error || Reader.ReadAllocError || error{ InvalidUTF8, InvalidLength })![]const u8 {
    const max_cps = may_max_cps orelse std.math.maxInt(u15);
    const len = try readVarIntMax(reader, u32, @as(u32, max_cps) * 3);
    const buf = try reader.take(len);
    const cps = std.unicode.utf8CountCodepoints(buf) catch |e| {
        logger.err("Invalid UTF8 string [{t}]", .{e});
        return error.InvalidUTF8;
    };
    if (cps > max_cps) {
        logger.err("String exceeded maximum length, got [{d}], max [{d}]", .{ cps, max_cps });
        return error.InvalidLength;
    }
    return buf;
}

pub fn writeString(writer: *Writer, s: []const u8) (Writer.Error || error{InvalidUTF8})!void {
    const cps = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUTF8;
    try writeVarInt(writer, cps);
    try writer.writeAll(s);
}
