// TODO: JSON Reader
// TODO: Comptime generic interface, for metadata-based serializing

const std = @import("std");
const builtin = @import("builtin");
const BitStack = @import("utils").BitStack;

const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;

const is_debug = builtin.mode == .Debug;

const assert = std.debug.assert;

fn castIntToFloat(comptime F: type, v: anytype) ?F {
    const V = @TypeOf(v);
    _ = @typeInfo(V).int;
    const max_F: comptime_int = @trunc(std.math.floatMax(F) - 1) + 1;
    const min_F: comptime_int = @trunc(std.math.floatMin(F) - 1) + 1;

    if (min_F <= v and v <= max_F) {
        return @floatFromInt(v);
    }
    return null;
}

fn castFloatToInt(comptime I: type, v: anytype) ?I {
    const V = @TypeOf(v);
    _ = @typeInfo(V).float;
    const max_I: V = @floatFromInt(std.math.maxInt(I));
    const min_I: V = @floatFromInt(std.math.minInt(I));

    if (min_I <= v and v <= max_I) {
        return @intFromFloat(v);
    }
    return null;
}

fn parseBool(s: []const u8) ?bool {
    return if (std.mem.eql(u8, s, "false"))
        false
    else if (std.mem.eql(u8, s, "true"))
        true
    else
        null;
}

fn readPropsRaw(comptime ftype: FieldProperty.Type, arena: Allocator, mapr: *MapReader) !ftype.GetType() {
    return switch (ftype) {
        .string => try mapr.nextDupeExpectString(),
        .boolean => try mapr.nextAsBool(),
        .int => try mapr.nextAsInt(),
        .float => try mapr.nextAsFloat(),
        .custom => |c| {
            var out: c.type = undefined;
            try c.read(arena, mapr, &out);
            return out;
        },
        .deserializeable => |T| try T.deserialize(mapr),
        .external, .array, .copy => unreachable,
    };
}

pub const NbtWriter = @import("NBT.zig").SerialWriter;
pub const NbtReader = @import("NBT.zig").SerialReader;

pub const JsonWriter = @import("json.zig").SerialWriter;
pub const JsonReader = @import("json.zig").SerialReader;

/// For security, the maximum size allocated to store a single string or number value is limited to 4MiB by default.
/// This limit can be specified by calling `nextAllocMax()` instead of `nextAlloc()`.
pub const default_max_value_len = 4 * 1024 * 1024;

pub const AllocWhen = enum { alloc_never, alloc_if_needed, alloc_always };
pub const BaseType = enum { boolean, byte, short, int, long, float, double, string, array, aggregate };
pub const TokenType = enum {
    boolean,
    byte,
    short,
    int,
    long,
    float,
    double,
    string,
    array_start,
    array_end,
    aggregate_start,
    aggregate_end,
};

pub const TaglessValue = union {
    fn makeTagged(self: TaglessValue, @"type": BaseType) Value {
        return switch (@"type") {
            inline else => |tag| @unionInit(
                Value,
                @tagName(tag),
                @field(self, @tagName(tag)),
            ),
        };
    }

    boolean: bool,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    string: []const u8,
    array: std.MultiArrayList(Value),
    aggregate: Value.Aggregate,
};

pub const Value = union(BaseType) {
    boolean: bool,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    string: []const u8,
    array: std.MultiArrayList(Value),
    aggregate: Aggregate,

    pub const Aggregate = struct {
        inline fn convertValueAtIndex(self: Aggregate, index: usize) Value {
            return self.values[index].makeTagged(self.types[index]);
        }

        count: usize,
        names: [*]const []const u8,
        types: [*]const BaseType,
        values: [*]const TaglessValue,

        /// Entry consisting of a key and value
        pub const Entry = struct { []const u8, Value };

        pub const Iterator = struct {
            aggr: *const Aggregate,
            next_index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                const ret = self.peek() orelse return null;
                self.next_index += 1;
                return ret;
            }

            pub fn peek(self: *Iterator) ?Entry {
                if (self.next_index >= self.aggr.count) return null;
                return .{
                    self.aggr.names[self.next_index],
                    self.aggr.convertValueAtIndex(self.next_index),
                };
            }
        };

        pub fn getIndex(self: Aggregate, index: usize) Entry {
            if (is_debug and index >= self.count)
                @call(.always_inline, std.builtin.panic.outOfBounds, .{ index, self.count });
            return .{ self.names[index], self.convertValueAtIndex(index) };
        }

        pub fn get(self: Aggregate, name: []const u8) ?Value {
            for (0..self.count) |i| {
                if (std.mem.eql(u8, self.names[i], name)) {
                    return self.convertValueAtIndex(i);
                }
            }
            return null;
        }
    };

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .boolean => |v| @intFromBool(v),
            .byte, .short, .int, .long => |v| v,
            .float, .double => |v| castFloatToInt(i64, v),
            .string => |s| std.fmt.parseInt(i64, s, 0) catch null,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            .byte, .short, .int, .long => |v| v != 0,
            .float, .double => |v| v != 0,
            .string => |s| parseBool(s),
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .boolean => |v| @floatFromInt(@intFromBool(v)),
            .byte, .short, .int, .long => |v| castIntToFloat(f64, v),
            .float, .double => |v| v,
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }
};

pub const Token = union(TokenType) {
    boolean: bool,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    string: []const u8,
    /// The length field allows readers to pre-allocate memory based upon the given type.
    ///
    /// If length or type is null, further reading and book-keeping is required to make sure proper
    /// serialization on the writing-end, such as:
    /// - Length of the array
    /// - Type and structure of following elements
    array_start: struct { length: ?usize, type: ?BaseType },
    array_end,
    aggregate_start,
    aggregate_end,

    /// Converts integer-like values to a single integer type
    pub fn asInt(self: Token) ?i64 {
        return switch (self) {
            .boolean => |b| @intFromBool(b),
            .byte, .short, .int, .long => |v| v,
            .float, .double => |v| castFloatToInt(i64, v),
            .string => |s| std.fmt.parseInt(i64, s, 0) catch null,
            else => null,
        };
    }
    /// Same as `asInt` but doesn't extent sign bit.
    pub fn asIntUnsigned(self: Token) ?u64 {
        return switch (self) {
            .boolean => |b| @intFromBool(b),
            inline .byte, .short, .int, .long => |v| @as(u64, @as(@Int(.unsigned, @bitSizeOf(@TypeOf(v))), @bitCast(v))),
            .float, .double => |v| castFloatToInt(u64, v),
            .string => |s| std.fmt.parseInt(u64, s, 0) catch null,
            else => null,
        };
    }

    /// Converts integer-like values to a boolean value
    pub fn asBool(self: Token) ?bool {
        return switch (self) {
            .boolean => |b| b,
            .byte, .short, .int, .long => |v| v != 0,
            .float, .double => |v| v != 0,
            .string => |s| parseBool(s),
            else => null,
        };
    }

    pub fn asFloat(self: Token) ?f64 {
        return switch (self) {
            .boolean => |v| @floatFromInt(@intFromBool(v)),
            .byte, .short, .int, .long => |v| castIntToFloat(f64, v),
            .float, .double => |v| v,
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }
};

pub const MapWriter = struct {
    writer: *IoWriter,
    /// This can help serializers to know which types to choose when serializing.
    output_type: OutputType,
    vtable: *const VTable,

    /// `error.WriteError` can either be caused by the `writer` or and error within
    /// the underlaying implementation of this `MapWriter` value.
    pub const WriteError = IoWriter.Error;

    pub const OutputType = enum {
        /// A sub-mode for `text` that meant to specifically be presented to
        /// a human being.
        human_readable,
        /// Means the serialized values will be written in plain text (json, snbt)
        text,
        /// Means the serialized values will be written in binary format (nbt)
        binary,
    };

    pub const VTable = struct {
        fieldName: *const fn (self: *MapWriter, name: []const u8) WriteError!void,
        writeBoolean: *const fn (self: *MapWriter, value: bool) WriteError!void,
        writeByte: *const fn (self: *MapWriter, value: i8) WriteError!void,
        writeShort: *const fn (self: *MapWriter, value: i16) WriteError!void,
        writeInt: *const fn (self: *MapWriter, value: i32) WriteError!void,
        writeLong: *const fn (self: *MapWriter, value: i64) WriteError!void,
        writeFloat: *const fn (self: *MapWriter, value: f32) WriteError!void,
        writeDouble: *const fn (self: *MapWriter, value: f64) WriteError!void,
        writeString: *const fn (self: *MapWriter, value: []const u8) WriteError!void,
        stringWriter: *const fn (self: *MapWriter, length: ?usize, buffer: []u8) WriteError!*IoWriter,
        /// `length` is merely an indication as to how many elements will be in this
        /// array for the sole purpose of memory pre-allocation.
        beginArray: *const fn (self: *MapWriter, length: ?usize) WriteError!void,
        endArray: *const fn (self: *MapWriter) WriteError!void,
        /// `length` is merely an indication as to how many elements will be in this
        /// aggregate for the sole purpose of memory pre-allocation.
        beginAggregate: *const fn (self: *MapWriter) WriteError!void,
        endAggregate: *const fn (self: *MapWriter) WriteError!void,
    };

    pub inline fn fieldName(self: *MapWriter, name: []const u8) WriteError!void {
        return self.vtable.fieldName(self, name);
    }
    pub inline fn writeBoolean(self: *MapWriter, value: bool) WriteError!void {
        return self.vtable.writeBoolean(self, value);
    }
    pub inline fn writeByte(self: *MapWriter, value: i8) WriteError!void {
        return self.vtable.writeByte(self, value);
    }
    pub inline fn writeShort(self: *MapWriter, value: i16) WriteError!void {
        return self.vtable.writeShort(self, value);
    }
    pub inline fn writeInt(self: *MapWriter, value: i32) WriteError!void {
        return self.vtable.writeInt(self, value);
    }
    pub inline fn writeLong(self: *MapWriter, value: i64) WriteError!void {
        return self.vtable.writeLong(self, value);
    }
    pub inline fn writeFloat(self: *MapWriter, value: f32) WriteError!void {
        return self.vtable.writeFloat(self, value);
    }
    pub inline fn writeDouble(self: *MapWriter, value: f64) WriteError!void {
        return self.vtable.writeDouble(self, value);
    }
    pub inline fn writeString(self: *MapWriter, value: []const u8) WriteError!void {
        return self.vtable.writeString(self, value);
    }
    /// Hands the caller an `std.Io.Writer` to write a string value.
    ///
    /// **DON'T FORGET TO FLUSH!** \
    /// Calling `flush()` on the returned writer will end the string and leave the writer
    /// in a valid state to write more data.
    pub inline fn stringWriter(self: *MapWriter, length: ?usize, buffer: []u8) WriteError!*IoWriter {
        return self.vtable.stringWriter(self, length, buffer);
    }
    pub inline fn beginArray(self: *MapWriter, length: ?usize) WriteError!void {
        return self.vtable.beginArray(self, length);
    }
    pub inline fn endArray(self: *MapWriter) WriteError!void {
        return self.vtable.endArray(self);
    }
    pub inline fn beginAggregate(self: *MapWriter) WriteError!void {
        return self.vtable.beginAggregate(self);
    }
    pub inline fn endAggregate(self: *MapWriter) WriteError!void {
        return self.vtable.endAggregate(self);
    }
};

pub const MapReader = struct {
    reader: *IoReader,
    vtable: *const VTable,
    nesting: BitStack,
    arena: std.heap.ArenaAllocator,
    /// Override the `max_value_len` parameter when `nextAlloc()` is called.
    max_value_len: usize = default_max_value_len,
    cached_token: ?Token = null,

    pub const ReadError = Allocator.Error || IoReader.Error || error{
        UnexpectedToken,
        ValueTooLong,
        TooDeep,
        LengthMismatch,
        InvalidCharacter,
        MissingField,
        UnknownField,
        DuplicateField,
    };

    pub const NestingType = enum(u1) { aggregate, list };

    pub const VTable = struct {
        next: *const fn (self: *MapReader, max_value_len: usize) ReadError!Token,
        skip: *const fn (self: *MapReader, target_nesting: usize) ReadError!void,
    };

    pub inline fn getAlloctor(self: *MapReader) Allocator {
        return self.arena.child_allocator;
    }

    pub inline fn getArena(self: *MapReader) Allocator {
        return self.arena.allocator();
    }

    pub inline fn pushNesting(self: *MapReader, nt: NestingType) Allocator.Error!void {
        return self.nesting.push(self.getAlloctor(), @intFromEnum(nt));
    }

    pub inline fn popNesting(self: *MapReader) ?NestingType {
        if (self.nesting.bit_len == 0) return null;
        return @enumFromInt(self.nesting.pop());
    }

    pub inline fn peekNesting(self: *MapReader) ?NestingType {
        if (self.nesting.bit_len < 1) return null;
        return @enumFromInt(self.nesting.peek());
    }

    pub fn peek(self: *MapReader) ReadError!TokenType {
        if (self.cached_token) |t| return t;
        self.cached_token = try self.next();
        return self.cached_token.?;
    }

    pub fn next(self: *MapReader) ReadError!Token {
        if (self.cached_token) |t| {
            self.cached_token = null;
            return t;
        }
        return self.vtable.next(self, self.max_value_len);
    }

    pub inline fn nextMax(self: *MapReader, max_value_len: usize) ReadError!Token {
        return self.vtable.next(self, max_value_len);
    }

    pub inline fn skipValue(self: *MapReader) ReadError!void {
        return self.vtable.skip(self, self.nesting.bit_len);
    }

    pub inline fn skipUntilStackHeight(self: *MapReader, terminal_stack_height: usize) ReadError!void {
        return self.vtable.skip(self, terminal_stack_height);
    }

    pub inline fn stackHeight(self: *MapReader) usize {
        return self.nesting.bit_len;
    }

    pub inline fn ensureTotalStackCapacity(self: *MapReader, height: usize) Allocator.Error!void {
        return self.nesting.ensureTotalCapacity(self.getAlloctor(), height);
    }

    pub fn mapToWriter(self: *MapReader, comptime max_depth: usize, mapw: *MapWriter) (MapWriter.WriteError || ReadError)!void {
        const base_height = self.stackHeight();

        var bstack: [max_depth]u8 = undefined;
        var depth: usize = 0;
        var count: u1 = 0;
        while (true) {
            const tok = try self.next();

            const is_object = depth > 0 and std.BitStack.peekWithState(&bstack, depth) == 0;
            const is_fieldname = is_object and count == 0;
            if (is_object and tok != .aggregate_end) count ^= 1;

            try switch (tok) {
                .boolean => |v| mapw.writeBoolean(v),
                .byte => |v| mapw.writeByte(v),
                .short => |v| mapw.writeShort(v),
                .int => |v| mapw.writeInt(v),
                .long => |v| mapw.writeLong(v),
                .float => |v| mapw.writeFloat(v),
                .double => |v| mapw.writeDouble(v),
                .string => |v| if (is_fieldname)
                    mapw.fieldName(v)
                else
                    mapw.writeString(v),
                .array_start => |a| {
                    if (depth >= max_depth) return error.TooDeep;
                    std.BitStack.pushWithStateAssumeCapacity(&bstack, &depth, 1);
                    try mapw.beginArray(a.length);
                },
                .array_end => {
                    depth -= 1;
                    try mapw.endArray();
                },
                .aggregate_start => {
                    if (depth >= max_depth) return error.TooDeep;
                    std.BitStack.pushWithStateAssumeCapacity(&bstack, &depth, 0);
                    try mapw.beginAggregate();
                },
                .aggregate_end => {
                    depth -= 1;
                    try mapw.endAggregate();
                },
            };

            if (self.stackHeight() == base_height) break;
        }
    }

    pub fn nextDupeExpectString(self: *MapReader) ReadError![]u8 {
        const value = try self.nextExpect(.string);
        return self.getArena().dupe(u8, value);
    }

    pub fn nextAsInt(self: *MapReader) ReadError!i64 {
        return Token.asInt(try self.next()) orelse error.UnexpectedToken;
    }

    /// Same as `nextAsInt` but extends the integer in an unsigned manner.
    pub fn nextAsIntUnsigned(self: *MapReader) ReadError!u64 {
        return Token.asIntUnsigned(try self.next()) orelse error.UnexpectedToken;
    }

    pub fn nextAsBool(self: *MapReader) ReadError!bool {
        return Token.asBool(try self.next()) orelse error.UnexpectedToken;
    }

    pub fn nextAsFloat(self: *MapReader) ReadError!f64 {
        return Token.asFloat(try self.next()) orelse error.UnexpectedToken;
    }

    pub fn nextExpect(self: *MapReader, comptime ttype: TokenType) ReadError!@FieldType(Token, @tagName(ttype)) {
        const tok = try self.next();
        if (tok != ttype) return error.UnexpectedToken;
        return @field(tok, @tagName(ttype));
    }
};

pub const NextOptions = struct {
    duplicate_field_mode: enum { use_first, @"error", use_last } = .use_first,
    ignore_unknown_fields: bool = true,
};

pub const FieldProperty = struct {
    name: []const u8,
    type: Type,

    pub const Type = union(enum) {
        /// A UTF-8 string.
        string,
        /// A boolean field, can be either:
        /// - Any number: In which case `0` will be treated as `false` and any  other
        ///             value as `true`.
        /// - A string: `"true"` -> `true`, `"false"` -> `false`, and any other value
        ///             will result in an error.
        /// - A boolean: No explanation
        boolean,
        int,
        float,
        /// Externally parsed.
        external: type,
        /// Uses the type's own `deserialize` function.
        deserializeable: type,
        /// Will be represented as an `std.ArrayList` internally. But
        /// cleared each time the field is met.
        array: *const Type,
        custom: struct {
            type: type,
            read: fn (Allocator, *MapReader, anytype) MapReader.ReadError!void,
        },
        /// Will allocate a value of the subtype.
        copy: *const Type,

        fn isNestable(comptime self: Type) bool {
            return switch (self) {
                .string, .boolean, .int, .float, .deserializeable, .custom => true,
                .external, .array, .copy => false,
            };
        }

        fn GetType(comptime self: Type) type {
            return switch (self) {
                .string => []const u8,
                .boolean => bool,
                .int => i64,
                .float => f64,
                .deserializeable, .external => |T| T,
                .array => |a| {
                    assert(a.isNestable());
                    return std.ArrayList(a.GetType());
                },
                .custom => |c| c.type,
                .copy => |c| {
                    assert(c.isNestable());
                    return *c.GetType();
                },
            };
        }

        fn GetUseableType(comptime self: Type) type {
            return switch (self) {
                .string => []const u8,
                .boolean => bool,
                .int => i64,
                .float => f64,
                .deserializeable, .external => |T| T,
                .array => |a| {
                    assert(a.* != .copy);
                    assert(a.* != .external);
                    assert(a.* != .array);
                    return []const a.GetType();
                },
                .custom => |c| c.type,
                .copy => |c| {
                    assert(c.* != .copy);
                    assert(c.* != .external);
                    assert(c.* != .array);
                    return *c.GetType();
                },
            };
        }
    };
};

/// A generic struct that helps by improving reading aggregates. Simply
/// define your fields to gather in the `fields` argument, and call `.next()`
/// repetitively until `null` is returned. You can also add custom behaviour on certain
/// fields with the non-null return value of `.next()`.
///
/// ```zig
/// var fg = FieldGatherer(&.{
///     .{ .name = "field_a", .type = .boolean },
/// }){};
/// defer fg.deinit(gpa);
/// ```
pub fn FieldGatherer(comptime fields: []const FieldProperty) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |f, i| {
        names[i] = f.name;
        const T = f.type.GetType();
        types[i] = if (f.type == .copy) ?T else T;
        attrs[i] = .{ .default_value_ptr = @ptrCast(if (f.type == .copy) &@as(?T, null) else &@as(T, undefined)) };
    }

    const EnumInt = std.math.IntFittingRange(0, fields.len);
    const Values = @Struct(.auto, null, &names, &types, &attrs);
    const MaskStruct = @Struct(
        .@"packed",
        @Int(.unsigned, fields.len),
        &names,
        &@splat(bool),
        &@splat(.{ .default_value_ptr = &false }),
    );
    const FieldEnum = @Enum(
        EnumInt,
        .nonexhaustive,
        &names,
        &std.simd.iota(EnumInt, fields.len),
    );
    return struct {
        const Self = @This();

        fn FieldType(comptime field: FieldEnum) type {
            return fieldProps(field).type.GetUseableType();
        }

        fn fieldProps(comptime field: FieldEnum) FieldProperty {
            const name = @tagName(field);
            for (fields) |fp| {
                if (std.mem.eql(u8, fp.name, name)) {
                    return fp;
                }
            }
            unreachable;
        }

        fn readValue(self: *Self, comptime field: FieldEnum, gpa: Allocator, arena: Allocator, mapr: *MapReader) !void {
            const ftype = fieldProps(field).type;
            const value_ptr = &@field(self.values, @tagName(field));
            const mask_ptr = &@field(self.mask, @tagName(field));

            switch (ftype) {
                .string,
                .boolean,
                .custom,
                .deserializeable,
                .int,
                .float,
                => value_ptr.* = try readPropsRaw(ftype, arena, mapr),
                .external => unreachable,
                .array => |a| {
                    var tok = try mapr.next();
                    if (tok != .array_start) return error.UnexpectedToken;
                    value_ptr.clearRetainingCapacity();
                    try value_ptr.ensureUnusedCapacity(gpa, tok.array_start.length orelse 0);
                    while (true) {
                        tok = try mapr.next();
                        if (tok == .array_end) break;
                        try value_ptr.append(gpa, try readPropsRaw(a.*, arena, mapr));
                    }
                },
                .copy => |c| value_ptr.*.?.* = try readPropsRaw(c.*, arena, mapr),
            }
            mask_ptr.* = true;
        }

        mask: MaskStruct = .{},
        values: Values = .{},
        opts: NextOptions = .{},

        pub fn deinit(self: *Self, gpa: Allocator) void {
            inline for (fields) |f| {
                if (@field(self.mask, f.name)) switch (f.type) {
                    .array => @field(self.values, f.name).deinit(gpa),
                    .copy => if (@field(self.values, f.name)) |ptr| gpa.destroy(ptr),
                    else => comptime continue,
                };
            }
        }

        pub fn next(self: *Self, gpa: Allocator, arena: Allocator, mapr: *MapReader) MapReader.ReadError!?FieldEnum {
            const token = try mapr.next();
            const name = switch (token) {
                .string => |s| s,
                .aggregate_end => return null,
                else => return error.UnexpectedToken,
            };
            inline for (fields) |fp| {
                if (std.mem.eql(u8, fp.name, name)) {
                    const field_enum = comptime @field(FieldEnum, fp.name);
                    const value_ptr = &@field(self.values, fp.name);
                    const mask_ptr = &@field(self.mask, fp.name);

                    if (mask_ptr.*) switch (self.opts.duplicate_field_mode) {
                        .use_first => break,
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    };

                    switch (fp.type) {
                        .external => return field_enum,
                        // Make sure these types are valid.
                        .array => if (!mask_ptr.*) {
                            value_ptr.* = .empty;
                        },
                        .copy => |c| if (value_ptr.* == null) {
                            value_ptr.* = try gpa.create(c.GetType());
                        },
                        else => {},
                    }

                    try self.readValue(field_enum, gpa, arena, mapr);
                    return field_enum;
                }
            } else if (!self.opts.ignore_unknown_fields) return error.UnknownField;
            try mapr.skipValue();
            return @enumFromInt(fields.len); // always out of range
        }

        pub fn set(self: *const Self, comptime field: FieldEnum, value: @FieldType(Values, @tagName(field))) void {
            comptime assert(fieldProps(field).type == .external);

            const name = @tagName(field);
            @field(self.values, name) = value;
            @field(self.mask, name) = true;
        }

        /// Note: Pointer types (arrays and copy's) are `const`.
        pub fn get(self: *const Self, comptime field: FieldEnum) error{MissingField}!FieldType(field) {
            if (!@field(self.mask, @tagName(field))) return error.MissingField;
            const v = @field(self.values, @tagName(field));
            return switch (fieldProps(field).type) {
                .array => v.items,
                .copy => v.?,
                else => v,
            };
        }

        pub fn getNullable(self: *const Self, comptime field: FieldEnum) ?FieldType(field) {
            if (!@field(self.mask, @tagName(field))) return null;
            return self.get(field) catch unreachable;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(MapWriter);
    std.testing.refAllDecls(MapReader);
    std.testing.refAllDecls(Token);
}
