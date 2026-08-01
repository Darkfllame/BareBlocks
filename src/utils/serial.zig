// TODO: JSON Reader/Writer
// TODO: NBT Reader/Writer
// TODO: Comptime generic interface, for metadata-based serializing
// TODO: Replace old uses of json/nbt by these

const std = @import("std");
const builtin = @import("builtin");
const BitStack = @import("BitStack.zig");

const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;

const is_debug = builtin.mode == .Debug;

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
    array: Value.Array,
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
    array: Array,
    aggregate: Aggregate,

    pub const Array = struct { type: BaseType, values: []TaglessValue };
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

    pub fn getInt(self: Value) ?i64 {
        return switch (self) {
            .byte, .short, .int, .long => |v| v,
            else => null,
        };
    }

    pub fn getFloat(self: Value) ?f64 {
        return switch (self) {
            .float, .double => |v| v,
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

    pub fn getInt(self: Token) ?i64 {
        return switch (self) {
            .byte, .short, .int, .long => |v| v,
            else => null,
        };
    }

    pub fn getFloat(self: Token) ?f64 {
        return switch (self) {
            .float, .double => |v| v,
            else => null,
        };
    }
};

pub const Diagnostics = struct {
    /// Starts at 1.
    line: usize = 1,
    /// Starts at 1.
    column: usize = 1,
    offset: usize = 0,
};

pub const MapWriter = struct {
    writer: *IoWriter,
    vtable: *const VTable,

    pub const WriteError = IoWriter.Error;
    pub const BeginArrayError = IoWriter.Error || error{
        /// Some writers may disallow untyped arrays
        UnknownType,
        /// Some writers may disallow non length prefixed arrays
        UnknownLength,
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
        beginArray: *const fn (self: *MapWriter, length: ?usize, @"type": ?BaseType) BeginArrayError!void,
        endArray: *const fn (self: *MapWriter) WriteError!void,
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
    pub inline fn beginArray(self: *MapWriter, length: ?usize, @"type": ?BaseType) BeginArrayError!void {
        return self.vtable.beginArray(self, length, @"type");
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
    diag: Diagnostics,
    /// Override the `max_value_len` parameter when `nextAlloc()` is called.
    max_value_len: usize = default_max_value_len,

    pub const ReadError = Allocator.Error || IoReader.Error || error{
        UnexpectedToken,
    };

    pub const NestingType = enum(u1) { aggregate, list };

    pub const VTable = struct {
        peek: *const fn (self: *MapReader) ReadError!Token,
        peekNextTokenType: *const fn (self: *MapReader) ReadError!TokenType,
        next: *const fn (self: *MapReader, when: AllocWhen, max_value_len: usize) ReadError!Token,
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
        if (self.nesting.bit_len <= 1) return null;
        return @enumFromInt(self.nesting.peek());
    }

    pub inline fn nextAlloc(self: *MapReader, when: AllocWhen) ReadError!Token {
        return self.vtable.next(self, when, self.max_value_len);
    }

    pub inline fn nextAllocMax(self: *MapReader, when: AllocWhen, max_value_len: usize) ReadError!Token {
        return self.vtable.next(self, when, max_value_len);
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
};
