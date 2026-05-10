const NBT = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

arena_state: ArenaAllocator.State = .{},
name: []const u8 = "",
root: Value = .void,

pub const ValueTag = enum(u8) {
    void = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,
};
pub const Value = union(ValueTag) {
    void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const i8,
    string: []const u8,
    list: List,
    compound: std.StringHashMapUnmanaged(Value),
    int_array: []const i32,
    long_array: []const i64,

    pub fn format(self: Value, writer: *Writer) Writer.Error!void {
        try switch (self) {
            .void => writer.writeAll("{}"),
            inline .byte, .short, .int, .long => |v| writer.printInt(v, 10, .lower, .{}),
            inline .float, .double => |v| writer.printFloat(v, .{}),
            inline .byte_array, .int_array, .long_array => |arr| {
                if (arr.len == 0) return writer.writeAll("[]");
                try writer.writeAll("[ ");
                for (arr, 0..) |v, i| {
                    try writer.printInt(v, 10, .lower, .{});
                    if (i + 1 < arr.len) try writer.writeAll(", ");
                }
                try writer.writeAll(" ]");
            },
            .string => |s| writer.print("\"{s}\"", .{s}),
            .list => |list| switch (list.type) {
                inline else => |tag| {
                    if (list.elems == 0) return writer.writeAll("[]");
                    try writer.writeAll("[ ");
                    for (list.getAs(tag).?, 0..) |v, i| {
                        try Value.format(@unionInit(Value, @tagName(tag), v), writer);
                        if (i + 1 < list.elems) try writer.writeAll(", ");
                    }
                    try writer.writeAll(" ]");
                },
            },
            .compound => |cp| {
                if (cp.count() == 0) return writer.writeAll("{}");

                try writer.writeAll("{ ");
                var i: usize = 0;
                var it = cp.iterator();
                while (it.next()) |entry| : (i += 1) {
                    const require_quotes = for (entry.key_ptr.*, 0..) |c, j| break switch (c) {
                        '0'...'9' => if (j == 0) true else continue,
                        'a'...'z', 'A'...'Z', '_' => continue,
                        else => true,
                    } else false;
                    try writer.print("{[0]s}{[1]s}{[0]s}: {[2]f}", .{
                        if (require_quotes) "\"" else "",
                        entry.key_ptr.*,
                        entry.value_ptr.*,
                    });
                    if (i + 1 < cp.count()) try writer.writeAll(", ");
                }
                try writer.writeAll(" }");
            },
        };
    }

    pub fn writeTo(self: Value, writer: *Writer) WriteError!void {
        try writer.writeByte(@intFromEnum(self));
        try writeValueRaw(writer, self);
    }
};

pub const List = struct {
    type: ValueTag = .void,
    elems: u31 = 0,
    data: [*]align(@alignOf(Value)) u8 = undefined,

    pub fn from(comptime @"type": ValueTag, data: []@FieldType(Value, @tagName(@"type"))) List {
        return .{
            .type = @"type",
            .elems = data.len,
            .data = @ptrCast(data),
        };
    }

    pub inline fn getAs(self: List, comptime @"type": ValueTag) ?[]@FieldType(Value, @tagName(@"type")) {
        if (self.type == .void) return &.{};
        if (self.type != @"type") return null;
        return @as([*]@FieldType(Value, @tagName(@"type")), @ptrCast(self.data))[0..self.elems];
    }
};

pub const ReadError = Reader.Error || Allocator.Error || error{ InvalidLength, InvalidEnumTag, InvalidString };
pub const WriteError = Writer.Error || error{ InvalidLength, InvalidEnumTag, InvalidString };

pub fn format(self: NBT, writer: *Writer) Writer.Error!void {
    return writer.print("\"{s}\": {f}", .{ self.name, self.root });
}

pub fn readJavaString(reader: *Reader, allocator: Allocator) ReadError![]const u8 {
    const len = try reader.takeInt(i16, .big);
    if (len < 0) return error.InvalidLength;

    const str = try reader.readAlloc(allocator, @intCast(len));

    if (!std.unicode.utf8ValidateSlice(str)) {
        allocator.free(str);
        return error.InvalidString;
    }
    return str;
}

pub fn readValueOnly(reader: *Reader, allocator: Allocator, tag: ValueTag) ReadError!Value {
    return switch (tag) {
        .void => .void,
        .byte => .{ .byte = try reader.takeByteSigned() },
        .short => .{ .short = try reader.takeInt(i16, .big) },
        .int => .{ .int = try reader.takeInt(i32, .big) },
        .long => .{ .long = try reader.takeInt(i64, .big) },
        .float => .{ .float = @as(f32, @bitCast(@byteSwap(@as(u32, @bitCast((try reader.takeArray(4)).*))))) },
        .double => .{ .double = @as(f64, @bitCast(@byteSwap(@as(u64, @bitCast((try reader.takeArray(8)).*))))) },
        inline .byte_array, .int_array, .long_array => |val| @unionInit(Value, @tagName(val), blk: {
            const T = switch (val) {
                .byte_array => i8,
                .int_array => i32,
                .long_array => i64,
                else => unreachable,
            };
            const len = try reader.takeInt(i32, .big);
            if (len < 0) return error.InvalidLength;
            const array = try allocator.alignedAlloc(T, .of(Value), @intCast(len));
            errdefer allocator.free(array);
            try reader.readSliceEndian(T, array, .big);
            break :blk array;
        }),
        .string => .{ .string = try readJavaString(reader, allocator) },
        .list => blk: {
            const list_tag = try reader.takeEnum(ValueTag, .big);
            const len = try reader.takeInt(i32, .big);
            if (len <= 0) return .{ .list = .{} };
            break :blk .{ .list = try readList(reader, allocator, list_tag, @intCast(len)) };
        },
        .compound => blk: {
            var map = std.StringHashMapUnmanaged(Value).empty;
            while (true) {
                const val_tag = std.enums.fromInt(ValueTag, try reader.peekByte()) orelse
                    return error.InvalidEnumTag;
                if (val_tag == .void) {
                    reader.toss(1);
                    break;
                }
                const value = try readNamedValueLeaky(reader, allocator);
                try map.put(allocator, value.name, value.root);
            }
            break :blk .{ .compound = map };
        },
    };
}

pub fn readList(reader: *Reader, allocator: Allocator, tag: ValueTag, len: u31) ReadError!List {
    switch (tag) {
        .void => unreachable,
        inline .byte, .short, .int, .long => |v| {
            const T = switch (v) {
                .byte => i8,
                .short => i16,
                .int => i32,
                .long => i64,
                else => unreachable,
            };
            const array = try allocator.alignedAlloc(T, .of(Value), len);
            errdefer allocator.free(array);
            try reader.readSliceEndian(T, array, .big);
            return .{ .type = tag, .elems = len, .data = @ptrCast(array.ptr) };
        },
        inline .float, .double => |v| {
            const T = switch (v) {
                .float => f32,
                .double => f64,
                else => unreachable,
            };
            const array = try allocator.alignedAlloc(T, .of(Value), len);
            errdefer allocator.free(array);
            try reader.readSliceAll(@ptrCast(array));
            for (array) |*f| {
                f.* = @bitCast(@byteSwap(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(f.*))));
            }
            return .{ .type = tag, .elems = len, .data = @ptrCast(array.ptr) };
        },
        inline else => |v| {
            const array = try allocator.alignedAlloc(
                @FieldType(Value, @tagName(v)),
                .of(Value),
                len,
            );
            errdefer allocator.free(array);
            for (array) |*out| {
                out.* = @field(try readValueOnly(reader, allocator, tag), @tagName(v));
            }
            return .{
                .type = tag,
                .elems = len,
                .data = @ptrCast(array.ptr),
            };
        },
    }
}

pub fn readNamedValue(reader: *Reader, allocator: Allocator) ReadError!NBT {
    var aa = ArenaAllocator.init(allocator);
    errdefer aa.deinit();
    const arena = aa.allocator();
    var res = try readNamedValueLeaky(reader, arena);
    res.arena_state = aa.state;
    return res;
}

pub fn readNamedValueLeaky(reader: *Reader, allocator: Allocator) ReadError!NBT {
    const tag = try reader.takeEnum(ValueTag, .big);
    const name = try readJavaString(reader, allocator);
    const value = try readValueOnly(reader, allocator, tag);
    return .{ .name = name, .root = value };
}

pub fn readValue(reader: *Reader, allocator: Allocator) ReadError!NBT {
    var aa = ArenaAllocator.init(allocator);
    errdefer aa.deinit();
    const arena = aa.allocator();
    const res = try readValueLeaky(reader, arena);
    res.arena_state = aa.state;
    return res;
}

pub fn readValueLeaky(reader: *Reader, allocator: Allocator) ReadError!NBT {
    const tag = try reader.takeEnum(ValueTag, .big);
    return .{ .root = try readValueOnly(reader, allocator, tag) };
}

pub fn writeJavaString(writer: *Writer, str: []const u8) WriteError!void {
    if (str.len > std.math.maxInt(u15)) return error.InvalidLength;
    if (str.len == 0) {
        return writer.writeInt(i16, 0, .big);
    }
    const view = std.unicode.Utf8View.init(str) catch return error.InvalidString;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len > 3) return error.InvalidString;
    }
    const int_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @truncate(str.len))));
    var vecs = [_][]const u8{ &int_bytes, str };
    try writer.writeVecAll(&vecs);
}

pub fn writeValueRaw(writer: *Writer, value: Value) WriteError!void {
    switch (value) {
        .void => {},
        inline .byte, .short, .int, .long, .float, .double => |val| {
            const ValInt = @Int(.unsigned, @bitSizeOf(@TypeOf(val)));
            const val_bytes: [@sizeOf(ValInt)]u8 = @bitCast(@byteSwap(@as(ValInt, @bitCast(val))));
            try writer.writeAll(&val_bytes);
        },
        inline .byte_array, .int_array, .long_array => |arr| {
            if (arr.len > std.math.maxInt(u31)) return error.InvalidLength;
            try writer.writeInt(i32, @intCast(arr.len), .big);
            try writer.writeSliceEndian(@typeInfo(@TypeOf(arr)).pointer.child, arr, .big);
        },
        .string => |str| try writeJavaString(writer, str),
        .list => |list| {
            if (list.type == .void and list.elems != 0) return error.InvalidEnumTag;
            try writer.writeByte(@intFromEnum(list.type));
            try writer.writeInt(i32, list.elems, .big);
            switch (list.type) {
                .void => {},
                inline .byte, .short, .int, .long, .float, .double => |tag| {
                    const arr = list.getAs(tag).?;
                    const ChildInt = @Int(.unsigned, @bitSizeOf(@typeInfo(@TypeOf(arr)).pointer.child));
                    try writer.writeSliceEndian(ChildInt, @ptrCast(arr), .big);
                },
                inline else => |tag| for (list.getAs(tag).?) |v| {
                    try writeValueRaw(writer, @unionInit(
                        Value,
                        @tagName(tag),
                        v,
                    ));
                },
            }
        },
        .compound => |cp| {
            var it = cp.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                if (val == .void) return error.InvalidEnumTag;
                try writer.writeByte(@intFromEnum(val));
                try writeJavaString(writer, entry.key_ptr.*);
                try writeValueRaw(writer, val);
            }
            try writer.writeByte(0);
        },
    }
}

pub fn writeTo(self: NBT, writer: *Writer) WriteError!void {
    try writer.writeByte(@intFromEnum(self.root));
    try writeJavaString(writer, self.name);
    try writeValueRaw(writer, self.root);
}