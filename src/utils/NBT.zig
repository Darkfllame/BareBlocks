const NBT = @This();
const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;

const assert = std.debug.assert;

const logger = std.log.scoped(.NBT);
const is_debug = builtin.mode == .Debug;

const StreamedValue = union(ValueTag) {
    void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const i8,
    string: []const u8,
    list: []const u8,
    compound: []const u8,
    int_array: []const i32,
    long_array: []const i64,
};

/// A list than can element added dynamically, but not removed.
///
/// Consider this like a `Value` buffer.
const DynamicList = struct {
    common_subtype: ValueTag = .void,
    values: std.MultiArrayList(StreamedValue) = .empty,

    fn cleanup(self: *DynamicList, allocator: Allocator) void {
        for (0..self.values.len) |i| {
            switch (self.values.get(i)) {
                else => {},
                .list => |s| if (s[0] != 0) allocator.free(s),
                .string, .compound => |s| allocator.free(s),
                inline .byte_array, .int_array, .long_array => |a| allocator.free(a),
            }
        }
        self.common_subtype = .void;
        self.values.deinit(allocator);
        self.values = .empty;
    }

    fn append(self: *DynamicList, allocator: Allocator, v: StreamedValue) Allocator.Error!void {
        assert(v != .void);
        if (self.values.len >= std.math.maxInt(i32) - 1) return error.OutOfMemory;

        sw: switch (self.common_subtype) {
            .void => self.common_subtype = v,
            else => |cs| if (cs != v) {
                self.common_subtype = .compound;
            },

            .byte => {
                const v_int = switch (v) {
                    .byte, .short, .int, .long => |i| i,
                    else => continue :sw .compound, // go to 'else' branch
                };
                if (std.math.cast(i8, v_int) != null) {
                    // keep subtype
                } else if (std.math.cast(i16, v_int) != null) {
                    self.common_subtype = .short;
                } else if (std.math.cast(i32, v_int) != null) {
                    self.common_subtype = .int;
                } else {
                    self.common_subtype = .long;
                }
            },
            .short => {
                const v_int = switch (v) {
                    .byte, .short, .int, .long => |i| i,
                    else => continue :sw .compound, // go to 'else' branch
                };
                if (std.math.cast(i16, v_int) != null) {
                    // keep subtype
                } else if (std.math.cast(i32, v_int) != null) {
                    self.common_subtype = .int;
                } else {
                    self.common_subtype = .long;
                }
            },
            .int => {
                const v_int = switch (v) {
                    .byte, .short, .int, .long => |i| i,
                    else => continue :sw .compound, // go to 'else' branch
                };
                if (std.math.cast(i32, v_int) == null) {
                    // keep subtype
                } else {
                    self.common_subtype = .long;
                }
            },
            .long => switch (v) {
                .byte, .short, .int, .long => {}, // keep subtype
                else => continue :sw .compound, // go to 'else' branch
            },
        }
        try self.values.append(allocator, v);
    }

    fn makeValue(self: DynamicList, allocator: Allocator) SerialWriter.Error!StreamedValue {
        const add = std.math.add;
        const mul = std.math.mul;

        const slice = self.values.slice();
        switch (self.common_subtype) {
            .void => return .{ .list = &.{ 0, 0, 0, 0, 0 } },
            inline .byte, .int, .long => |tag| {
                const TargetInt, const target_tag = comptime switch (tag) {
                    .byte => .{ i8, "byte_array" },
                    .int => .{ i32, "int_array" },
                    .long => .{ i64, "long_array" },
                    else => unreachable,
                };
                const arr = try allocator.alloc(TargetInt, self.values.len);
                for (0..slice.len) |i| {
                    arr[i] = @intCast(switch (slice.get(i)) {
                        .byte, .short, .int, .long => |v| v,
                        else => unreachable,
                    });
                }
                return @unionInit(StreamedValue, target_tag, arr);
            },
            else => {},
        }

        var size: usize = 5;
        for (0..slice.len) |i| {
            const v = slice.get(i);
            size = add(usize, size, switch (v) {
                .void => unreachable,
                .byte => 1,
                .short => 2,
                .int, .float => 4,
                .long, .double => 8,
                // all of these do 4 + a.len * @sizeOf(Elem)
                .byte_array => |a| add(usize, 4, a.len) catch return error.InvalidLength,
                .int_array => |a| add(usize, 4, mul(usize, a.len, 4) catch return error.InvalidLength) catch return error.InvalidLength,
                .long_array => |a| add(usize, 4, mul(usize, a.len, 8) catch return error.InvalidLength) catch return error.InvalidLength,

                .string => |s| add(usize, 2, try calcJavaStringLength(s)) catch return error.InvalidLength,
                .list, .compound => |l| l.len,
            }) catch return error.InvalidLength;
        }
        assert(size >= 0);
        const out = try allocator.alloc(u8, @intCast(size));
        errdefer comptime unreachable;
        var writer = IoWriter.fixed(out);
        self.serialize(&writer) catch unreachable;

        return .{ .list = out };
    }

    fn getValueTag(self: DynamicList) ValueTag {
        return switch (self.common_subtype) {
            .byte => .byte_array,
            .int => .int_array,
            .long => .long_array,
            else => .list,
        };
    }

    fn serialize(self: DynamicList, writer: *IoWriter) WriteError!void {
        const slice = self.values.slice();

        switch (self.common_subtype) {
            .void => return writer.writeAll(&.{ 0, 0, 0, 0, 0 }),
            .byte, .int, .long => {}, // no subtype, just length
            else => try writer.writeByte(@intFromEnum(self.common_subtype)),
        }

        try writer.writeInt(i32, @intCast(slice.len), .big);

        switch (self.common_subtype) {
            .void => unreachable,
            .compound => {
                for (0..slice.len) |i| {
                    switch (slice.get(i)) {
                        .void => unreachable,
                        // Already properly serialized
                        .list, .compound => |bytes| try writer.writeAll(bytes),
                        inline else => |sub, tag| {
                            try writer.writeByte(@intFromEnum(tag));
                            try writeJavaString(writer, "");
                            try writeValueRaw(writer, @unionInit(Value, @tagName(tag), sub));
                            try writer.writeByte(@intFromEnum(ValueTag.void));
                        },
                    }
                }
            },
            .list => for (slice.items(.data)) |d| try writer.writeAll(d.list),
            inline .byte, .int, .long => |tag| {
                const TargetInt = comptime switch (tag) {
                    .byte => i8,
                    .int => i32,
                    .long => i64,
                    else => unreachable,
                };
                for (0..slice.len) |i| {
                    try writer.writeInt(TargetInt, @intCast(switch (slice.get(i)) {
                        .byte, .short, .int, .long => |v| v,
                        else => unreachable,
                    }), .big);
                }
            },
            inline else => |tag| {
                for (slice.items(.data)) |d| {
                    try writeValueRaw(writer, @unionInit(
                        Value,
                        @tagName(tag),
                        @field(d, @tagName(tag)),
                    ));
                }
            },
        }
    }
};

pub const ReadError = IoReader.Error || Allocator.Error || error{ InvalidLength, InvalidEnumTag, InvalidString };
pub const StreamStringError = IoReader.Error || IoWriter.Error || error{ InvalidLength, InvalidString };
pub const WriteError = IoWriter.Error || error{ InvalidLength, InvalidEnumTag, InvalidString };

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

    pub fn isIntType(self: ValueTag) bool {
        return switch (self) {
            .byte, .short, .int, .long => true,
            else => false,
        };
    }
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
    /// UTF-8 encoded.
    string: []const u8,
    list: List,
    compound: std.StringHashMapUnmanaged(Value),
    int_array: []const i32,
    long_array: []const i64,

    pub fn format(self: Value, writer: *IoWriter) IoWriter.Error!void {
        try switch (self) {
            .void => writer.writeAll("{}"),
            inline .byte, .short, .int, .long => |v| writer.printInt(v, 10, .lower, .{}),
            inline .float, .double => |v| writer.printFloat(v, .{}),
            inline .byte_array, .int_array, .long_array => |arr, tag| {
                try writer.writeAll(comptime switch (tag) {
                    .byte_array => "[B;",
                    .int_array => "[I;",
                    .long_array => "[L;",
                    else => unreachable,
                });
                if (arr.len == 0) return writer.writeByte(']');
                try writer.writeByte(' ');
                for (arr, 0..) |v, i| {
                    try writer.printInt(v, 10, .lower, .{});
                    if (i + 1 < arr.len) try writer.writeAll(", ");
                }
                try writer.writeAll(" ]");
            },
            .string => |s| writer.print("\"{s}\"", .{s}),
            .list => |list| {
                if (list.len == 0) return writer.writeAll("[]");
                try writer.writeAll("[ ");
                switch (list.type) {
                    inline else => |tag| for (list.getValuesAs(tag).?, 0..) |v, i| {
                        try Value.format(@unionInit(Value, @tagName(tag), v), writer);
                        if (i + 1 < list.len) try writer.writeAll(", ");
                    },
                }
                try writer.writeAll(" ]");
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

    pub fn writeTo(self: Value, writer: *IoWriter) WriteError!void {
        try writer.writeByte(@intFromEnum(self));
        try writeValueRaw(writer, self);
    }
};

pub const List = struct {
    type: ValueTag = .void,
    len: u31 = 0,
    data: [*]u8 = undefined,

    pub fn from(comptime @"type": ValueTag, data: []@FieldType(Value, @tagName(@"type"))) List {
        return .{
            .type = @"type",
            .len = @intCast(data.len),
            .data = @ptrCast(data),
        };
    }

    pub inline fn getValuesAs(self: *const List, comptime @"type": ValueTag) ?[]@FieldType(Value, @tagName(@"type")) {
        if (self.type == .void) return &.{};
        if (self.type != @"type") return null;
        return @as([*]@FieldType(Value, @tagName(@"type")), @ptrCast(@alignCast(self.data)))[0..self.len];
    }
};

pub const SerialWriter = struct {
    const max_stack_depth = 512;

    const vtable = MapWriter.VTable{
        .fieldName = &vtable_impl.fieldName,
        .writeBoolean = &vtable_impl.writeBoolean,
        .writeByte = &vtable_impl.writeByte,
        .writeShort = &vtable_impl.writeShort,
        .writeInt = &vtable_impl.writeInt,
        .writeLong = &vtable_impl.writeLong,
        .writeFloat = &vtable_impl.writeFloat,
        .writeDouble = &vtable_impl.writeDouble,
        .writeString = &vtable_impl.writeString,
        .stringWriter = &vtable_impl.stringWriter,
        .beginArray = &vtable_impl.beginArray,
        .endArray = &vtable_impl.endArray,
        .beginAggregate = &vtable_impl.beginAggregate,
        .endAggregate = &vtable_impl.endAggregate,
    };
    const string_writer_vtable = IoWriter.VTable{
        .drain = &vtable_impl.sw_drain,
        .flush = &vtable_impl.sw_flush,
    };

    const vtable_impl = struct {
        fn sw_drain(iow: *IoWriter, data: []const []const u8, splat: usize) IoWriter.Error!usize {
            assert(data.len > 0);
            const self: *SerialWriter = @fieldParentPtr("string_writer", iow);
            const slices = data[0 .. data.len - 1];
            const pattern = data[data.len - 1];

            const state = self.getState();
            if (state.data != .string) {
                self.@"error" = error.InvalidState;
                return error.WriteFailed;
            }
            const str = &state.data.string;

            const pattern_length = std.math.mul(usize, pattern.len, splat) catch {
                self.@"error" = error.OutOfMemory;
                return error.WriteFailed;
            };
            const header = iow.buffered();

            var total_length: usize = header.len;
            for (slices) |s| {
                total_length = std.math.add(usize, total_length, s.len) catch {
                    self.@"error" = error.OutOfMemory;
                    return error.WriteFailed;
                };
            }
            total_length = std.math.add(usize, total_length, pattern_length) catch {
                self.@"error" = error.OutOfMemory;
                return error.WriteFailed;
            };

            str.ensureUnusedCapacity(self.allocator, total_length) catch {
                self.@"error" = error.OutOfMemory;
                return error.WriteFailed;
            };

            str.appendSliceAssumeCapacity(header);
            for (slices) |s| str.appendSliceAssumeCapacity(s);
            if (pattern_length != 0) switch (splat) {
                0 => unreachable,
                1 => str.appendSliceAssumeCapacity(pattern),
                else => switch (pattern.len) {
                    0 => unreachable,
                    1 => @memset(str.addManyAsSliceAssumeCapacity(splat), pattern[0]),
                    else => for (0..splat) |_| str.appendSliceAssumeCapacity(pattern),
                },
            };

            iow.end = 0;

            return total_length;
        }
        fn sw_flush(iow: *IoWriter) IoWriter.Error!void {
            const self: *SerialWriter = @fieldParentPtr("string_writer", iow);

            const state_node = self.getStateNode();
            const old_state_node: *StateNode = @fieldParentPtr("node", state_node.node.next.?);

            const state = &state_node.state;
            if (state.data != .string) {
                self.@"error" = error.InvalidState;
                return error.WriteFailed;
            }
            const str = &state.data.string;
            str.appendSlice(self.allocator, iow.buffered()) catch {
                self.@"error" = error.OutOfMemory;
                return error.WriteFailed;
            };

            blk: {
                var aw: IoWriter.Allocating = undefined;
                var cbs_ptr: ?*CompoundBufferingState = null;

                const res = self.getOutput(&old_state_node.state, &aw, &cbs_ptr) catch |e| {
                    self.@"error" = e;
                    return error.WriteFailed;
                };
                const writer = switch (res) {
                    .writer => |w| w,
                    .list => |l| {
                        const cpy = str.toOwnedSlice(self.allocator) catch {
                            self.@"error" = error.OutOfMemory;
                            return error.WriteFailed;
                        };
                        l.append(self.allocator, .{ .string = cpy }) catch {
                            self.@"error" = error.OutOfMemory;
                            return error.WriteFailed;
                        };
                        break :blk;
                    },
                };
                defer if (cbs_ptr) |cbs| cbs.redeemAllocWriter(&aw);

                state.writePrologue(self.allocator, writer, .string) catch |e| {
                    self.@"error" = e;
                    return error.WriteFailed;
                };

                writeJavaString(writer, str.items) catch |e| {
                    self.@"error" = e;
                    return error.WriteFailed;
                };

                str.deinit(self.allocator);
            }

            self.allocator.destroy(self.popState());
        }

        inline fn callFunctionAdapted(mapw: *MapWriter, func: anytype, args: anytype) MapWriter.WriteError!@typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.payload {
            const sw: *SerialWriter = @fieldParentPtr("mapw", mapw);
            return @call(.auto, func, .{sw} ++ args) catch |e| {
                sw.@"error" = e;
                return error.WriteFailed;
            };
        }

        fn fieldName(mapw: *MapWriter, name: []const u8) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.setFieldName, .{name});
        }

        fn writeBoolean(mapw: *MapWriter, value: bool) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeBoolean, .{value});
        }

        fn writeByte(mapw: *MapWriter, value: i8) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeByte, .{value});
        }

        fn writeShort(mapw: *MapWriter, value: i16) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeShort, .{value});
        }

        fn writeInt(mapw: *MapWriter, value: i32) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeInt, .{value});
        }

        fn writeLong(mapw: *MapWriter, value: i64) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeLong, .{value});
        }

        fn writeFloat(mapw: *MapWriter, value: f32) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeFloat, .{value});
        }

        fn writeDouble(mapw: *MapWriter, value: f64) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeDouble, .{value});
        }

        fn writeString(mapw: *MapWriter, value: []const u8) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.writeString, .{value});
        }

        fn stringWriter(mapw: *MapWriter, length: ?usize, buffer: []u8) MapWriter.WriteError!*IoWriter {
            return callFunctionAdapted(mapw, SerialWriter.stringWriter, .{ length, buffer });
        }

        fn beginArray(mapw: *MapWriter, length: ?usize) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.beginArray, .{length});
        }

        fn endArray(mapw: *MapWriter) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.endArray, .{});
        }

        fn beginAggregate(mapw: *MapWriter) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.beginCompound, .{});
        }

        fn endAggregate(mapw: *MapWriter) MapWriter.WriteError!void {
            return callFunctionAdapted(mapw, SerialWriter.endCompound, .{});
        }
    };

    const State = struct {
        data: union(enum) {
            /// Always the starting state of a `SerialWriter`.
            ///
            /// This is required due to the FU- frankenstein-esque nature of
            /// NBT, the top level value of a NBT file should be a compound, but
            /// I personally don't care. And it must also be named, except when sent
            /// via network. Thanks mojang.
            ///
            /// So this is mainly to avoid some weird stuff.
            top_value,
            /// This field can have a value of `null` when in streaming mode,
            /// however, due to some limitations of `list` it may be non-`null`
            /// which indicates buffering mode.
            compound: CompoundBufferingState,
            /// If a list is currently being written, it must force all
            /// sub-sequent values to be buffered, including compounds.
            ///
            /// This is because lists' elements may be dynamically typed
            /// and serialized lists cannot.
            list: DynamicList,
            string: std.ArrayList(u8),
        },
        /// The name of the current value to be written.
        ///
        /// If `data` is in ***top_value** mode, this will act as the top-level name
        /// of the following data.
        ///
        /// If `data` is in ***compound*** mode and this is `null`, it must first
        /// be set before writing a value.
        ///
        /// If `data` is in ***list*** mode, this will act as the name of `data`.
        name: ?[]const u8,
        streaming: bool,

        /// Consumes `self.name`. Returns whether the name of the current state was empty.
        fn writePrologue(self: *State, allocator: Allocator, w: *IoWriter, tag: ValueTag) WriteError!void {
            try w.writeByte(@intFromEnum(tag));
            if (self.name) |nm| {
                if (nm.len == 0 and self.data == .compound and !self.streaming) {
                    self.data.compound.wrapper = switch (self.data.compound.wrapper) {
                        .dont_know => .maybe,
                        else => .false,
                    };
                }
                try writeJavaString(w, nm);
                allocator.free(nm);
                self.name = null;
            }
        }
    };
    const StateNode = struct { node: std.SinglyLinkedList.Node, state: State };
    const CompoundBufferingState = struct {
        buffer: union(enum) {
            owned: std.ArrayList(u8),
            shared: *std.ArrayList(u8),
        },
        wrapper: Wrapper,

        const Wrapper = enum { dont_know, maybe, false };

        fn redeemAllocWriter(self: *CompoundBufferingState, aw: *IoWriter.Allocating) void {
            self.bufferPtr().* = aw.toArrayList();
        }

        fn shareBuffer(self: *CompoundBufferingState, shared: *CompoundBufferingState) void {
            self.buffer = .{ .shared = switch (shared.buffer) {
                .owned => |*a| a,
                .shared => |p| p,
            } };
        }

        fn bufferPtr(self: *CompoundBufferingState) *std.ArrayList(u8) {
            return switch (self.buffer) {
                .owned => |*a| a,
                .shared => |p| p,
            };
        }

        fn bufferItems(self: *CompoundBufferingState) []u8 {
            return switch (self.buffer) {
                inline .owned, .shared => |a| a.items,
            };
        }

        fn getAllocWriter(self: *CompoundBufferingState, allocator: Allocator) IoWriter.Allocating {
            return .fromArrayList(allocator, self.bufferPtr());
        }

        fn maybeDeinit(self: *CompoundBufferingState, allocator: Allocator) void {
            switch (self.buffer) {
                .owned => |*a| a.deinit(allocator),
                .shared => {},
            }
            self.* = undefined;
        }
    };

    fn getState(self: *SerialWriter) *State {
        return &self.getStateNode().state;
    }

    fn getStateNode(self: *SerialWriter) *StateNode {
        if (self.state_stack.first) |f|
            return @as(*StateNode, @fieldParentPtr("node", f));
        if (is_debug) @panic("End of value");
        unreachable;
    }

    fn pushState(self: *SerialWriter) Error!*State {
        if (self.stack_depth >= max_stack_depth - 1) return error.TooDeep;
        const sn = try self.allocator.create(StateNode);
        self.state_stack.prepend(&sn.node);
        self.stack_depth += 1;
        return &sn.state;
    }

    fn popState(self: *SerialWriter) *StateNode {
        const sn = if (self.state_stack.first) |f|
            @as(*StateNode, @fieldParentPtr("node", f))
        else if (is_debug)
            @panic("End of value")
        else
            unreachable;
        self.state_stack.first = sn.node.next;
        self.stack_depth -= 1;
        return sn;
    }

    fn writeTag(self: *SerialWriter, value: Value) Error!void {
        assert(switch (value) {
            .byte, .short, .int, .long, .float, .double, .string => true,
            else => false,
        });

        var aw: IoWriter.Allocating = undefined;
        var cbs_ptr: ?*CompoundBufferingState = null;

        const state = self.getState();
        const writer = switch (try self.getOutput(state, &aw, &cbs_ptr)) {
            .writer => |w| w,
            .list => |l| {
                const vcpy = switch (value) {
                    .string => |s| StreamedValue{ .string = try self.allocator.dupe(u8, s) },
                    inline .byte,
                    .short,
                    .int,
                    .long,
                    .float,
                    .double,
                    => |v, tag| @unionInit(StreamedValue, @tagName(tag), v),
                    else => unreachable,
                };
                errdefer if (vcpy == .string) self.allocator.free(vcpy.string);

                return l.append(self.allocator, vcpy);
            },
        };
        defer if (cbs_ptr) |cbs| cbs.redeemAllocWriter(&aw);

        try state.writePrologue(self.allocator, writer, value);

        switch (value) {
            inline .byte, .short, .int, .long, .float, .double => |val| {
                const ValInt = @Int(.unsigned, @bitSizeOf(@TypeOf(val)));
                const val_bytes: [@sizeOf(ValInt)]u8 = @bitCast(@byteSwap(@as(ValInt, @bitCast(val))));
                try writer.writeAll(&val_bytes);
            },
            .string => |str| try writeJavaString(writer, str),
            else => unreachable,
        }
    }

    fn getOutput(self: *SerialWriter, state: *State, aw: *IoWriter.Allocating, cbs_ptr: *?*CompoundBufferingState) !union(enum) { writer: *IoWriter, list: *DynamicList } {
        return switch (state.data) {
            .top_value => .{ .writer = self.mapw.writer },
            .compound => |*cbs| {
                if (state.name == null) return error.NameNotSet;
                if (!state.streaming) {
                    cbs_ptr.* = cbs;
                    aw.* = cbs.getAllocWriter(self.allocator);
                    return .{ .writer = &aw.writer };
                }
                return .{ .writer = self.mapw.writer };
            },
            .list => |*l| .{ .list = l },
            .string => error.InvalidState,
        };
    }

    mapw: MapWriter,
    top_node: StateNode,
    state_stack: std.SinglyLinkedList,
    stack_depth: u16,
    allocator: Allocator,
    @"error": ?Error,
    string_writer: IoWriter,

    pub const Error = WriteError || Allocator.Error || error{
        TypeMismatch,
        NameAlreadySet,
        NameNotSet,
        InvalidState,
        TooDeep,
    };

    pub fn init(self: *SerialWriter, allocator: Allocator, output: *IoWriter) void {
        self.* = .{
            .mapw = .{
                .writer = output,
                .vtable = &vtable,
            },
            .top_node = .{
                .state = .{
                    .data = .top_value,
                    .name = null,
                    .streaming = false,
                },
                .node = .{},
            },
            .state_stack = .{ .first = &self.top_node.node },
            .stack_depth = 0,
            .allocator = allocator,
            .@"error" = null,
            .string_writer = .failing,
        };
    }

    pub fn deinit(self: *SerialWriter) void {
        while (self.stack_depth != 0) {
            const state_node = self.popState();
            switch (state_node.state.data) {
                .top_value => assert(self.stack_depth == 0),
                .compound => |*cbs| {
                    if (!state_node.state.streaming) {
                        std.log.debug(
                            \\Unclosed compound in NBT.SerialWriter:
                            \\ - buffer.len: {d}
                            \\ - is_wrapper: {t}
                        , .{ cbs.bufferItems().len, cbs.wrapper });
                        cbs.maybeDeinit(self.allocator);
                    } else {
                        std.log.debug("Unclosed streaming compound in NBT.SerialWriter", .{});
                    }
                },
                .list => |*l| {
                    std.log.debug(
                        \\Unclosed list in NBT.SerialWriter:
                        \\ - common_subtype: {t}
                        \\ - values.len: {d}
                    , .{ l.common_subtype, l.values.len });
                    l.cleanup(self.allocator);
                },
                .string => |*s| {
                    std.log.debug("Unclosed string in NBT.SerialWriter: {s}", .{s.items});
                    s.deinit(self.allocator);
                },
            }
            if (state_node.state.name) |nm| self.allocator.free(nm);

            if (state_node.state.data != .top_value) self.allocator.destroy(state_node);
        }
    }

    pub fn setFieldName(self: *SerialWriter, name: []const u8) Error!void {
        const state = self.getState();
        switch (state.data) {
            .top_value => {},
            .compound => {},
            .list, .string => return error.InvalidState,
        }

        if (state.name != null) return error.NameAlreadySet;

        state.name = try self.allocator.dupe(u8, name);
    }

    pub inline fn writeBoolean(self: *SerialWriter, value: bool) Error!void {
        return self.writeTag(.{ .byte = @intFromBool(value) });
    }

    pub inline fn writeByte(self: *SerialWriter, value: i8) Error!void {
        return self.writeTag(.{ .byte = value });
    }

    pub inline fn writeShort(self: *SerialWriter, value: i16) Error!void {
        return self.writeTag(.{ .short = value });
    }

    pub inline fn writeInt(self: *SerialWriter, value: i32) Error!void {
        return self.writeTag(.{ .int = value });
    }

    pub inline fn writeLong(self: *SerialWriter, value: i64) Error!void {
        return self.writeTag(.{ .long = value });
    }

    pub inline fn writeFloat(self: *SerialWriter, value: f32) Error!void {
        return self.writeTag(.{ .float = value });
    }

    pub inline fn writeDouble(self: *SerialWriter, value: f64) Error!void {
        return self.writeTag(.{ .double = value });
    }

    pub inline fn writeString(self: *SerialWriter, value: []const u8) Error!void {
        return self.writeTag(.{ .string = value });
    }

    pub fn stringWriter(self: *SerialWriter, length: ?usize, buffer: []u8) Error!*IoWriter {
        var arr = try std.ArrayList(u8).initCapacity(self.allocator, length orelse 16);
        errdefer arr.deinit(self.allocator);

        const old_state = self.getState();
        const new_state = try self.pushState();
        new_state.* = .{
            .data = .{ .string = arr },
            .name = null,
            .streaming = old_state.streaming,
        };

        self.string_writer = .{
            .vtable = &string_writer_vtable,
            .buffer = buffer,
            .end = 0,
        };
        return &self.string_writer;
    }

    pub fn beginArray(self: *SerialWriter, length: ?usize) Error!void {
        var arr = try std.MultiArrayList(StreamedValue)
            .initCapacity(self.allocator, length orelse 16);
        errdefer arr.deinit(self.allocator);

        const new_node = try self.pushState();
        new_node.* = .{
            .data = .{ .list = .{ .values = arr } },
            .name = null,
            .streaming = false,
        };
    }

    pub fn endArray(self: *SerialWriter) Error!void {
        const state_node = self.getStateNode();
        const list = &state_node.state.data.list;

        const old_state_node: *StateNode = @fieldParentPtr("node", state_node.node.next.?);
        const old_state = &old_state_node.state;

        blk: {
            var aw: IoWriter.Allocating = undefined;
            var cbs_ptr: ?*CompoundBufferingState = null;

            const writer = switch (try self.getOutput(old_state, &aw, &cbs_ptr)) {
                .writer => |w| w,
                .list => |l| {
                    try l.append(self.allocator, try list.makeValue(self.allocator));
                    break :blk;
                },
            };
            defer if (cbs_ptr) |cbs| cbs.redeemAllocWriter(&aw);

            try old_state.writePrologue(self.allocator, writer, list.getValueTag());

            try list.serialize(writer);
        }

        list.cleanup(self.allocator);
        self.allocator.destroy(self.popState());
    }

    pub fn beginCompound(self: *SerialWriter) Error!void {
        const old_state = self.getState();
        var new_state: State = undefined;
        new_state.name = null;
        const is_streaming = switch (old_state.data) {
            .top_value => true,
            .compound => old_state.streaming,
            .list => false,
            .string => return error.InvalidState,
        };
        new_state.streaming = is_streaming;
        new_state.data = .{ .compound = undefined };
        if (!is_streaming) {
            new_state.data.compound = .{
                .buffer = .{ .owned = .empty },
                .wrapper = .dont_know,
            };
            if (old_state.data == .compound) {
                new_state.data.compound.shareBuffer(&old_state.data.compound);
            }
        }
        errdefer if (!is_streaming) new_state.data.compound.maybeDeinit(self.allocator);

        const st = try self.pushState();
        st.* = new_state;

        var aw: IoWriter.Allocating = undefined;
        var cbs_ptr: ?*CompoundBufferingState = null;

        const writer = switch (try self.getOutput(old_state, &aw, &cbs_ptr)) {
            .writer => |w| w,
            .list => return,
        };
        defer if (cbs_ptr) |cbs| cbs.redeemAllocWriter(&aw);

        try old_state.writePrologue(self.allocator, writer, .compound);
    }

    pub fn endCompound(self: *SerialWriter) Error!void {
        const state_node = self.getStateNode();
        const compound = &state_node.state.data.compound;

        const old_state_node: *StateNode = @fieldParentPtr("node", state_node.node.next.?);
        const old_state = &old_state_node.state;

        blk: {
            var aw: IoWriter.Allocating = undefined;
            var cbs_ptr: ?*CompoundBufferingState = null;

            old_state.name = "";

            const writer = switch (try self.getOutput(old_state, &aw, &cbs_ptr)) {
                .writer => |w| w,
                .list => |l| {
                    const needs_wrapping = compound.wrapper == .maybe;

                    const len = compound.bufferItems().len + 1 + (@as(u8, @intFromBool(needs_wrapping))) * 4;
                    const slice = try self.allocator.alloc(u8, len);
                    errdefer self.allocator.free(slice);
                    var w = IoWriter.fixed(slice);
                    if (needs_wrapping) {
                        w.writeAll(&.{ @intFromEnum(ValueTag.compound), 0, 0 }) catch unreachable;
                    }
                    w.writeAll(compound.bufferItems()) catch unreachable;
                    w.writeByte(@intFromEnum(ValueTag.void)) catch unreachable;
                    if (needs_wrapping) {
                        w.writeByte(@intFromEnum(ValueTag.void)) catch unreachable;
                    }

                    try l.append(self.allocator, .{ .compound = slice });
                    break :blk;
                },
            };
            defer if (cbs_ptr) |cbs| cbs.redeemAllocWriter(&aw);
            old_state.name = null;

            if (!state_node.state.streaming) {
                try writer.writeAll(compound.bufferItems());
            }
            try writer.writeByte(@intFromEnum(ValueTag.void));
        }
        if (!state_node.state.streaming) {
            compound.maybeDeinit(self.allocator);
        }
        self.allocator.destroy(self.popState());
    }
};

pub const SerialReader = struct {
    const vtable = MapReader.VTable{
        .next = nextImpl,
        .skip = skipImpl,
    };

    const State = union(enum) {
        top_value: bool,
        value: ValueTag,
        compound_name,
        compound_value: ValueTag,
        list_value,
        value_end,
    };

    fn nextImpl(mapr: *MapReader, max_value_len: usize) MapReader.ReadError!serial.Token {
        const self: *SerialReader = @fieldParentPtr("mapr", mapr);
        return self.next(max_value_len) catch |e| switch (e) {
            error.OutOfMemory,
            error.ReadFailed,
            error.UnexpectedToken,
            error.ValueTooLong,
            => |err| return err,
            else => {
                self.@"error" = e;
                return error.ReadFailed;
            },
        };
    }

    fn skipImpl(mapr: *MapReader, until_height: usize) MapReader.ReadError!void {
        _ = mapr;
        _ = until_height;
        @panic("TODO: Unimplemented skip");
    }

    inline fn getAllocator(self: *SerialReader) Allocator {
        return self.mapr.getAlloctor();
    }

    inline fn getArena(self: *SerialReader) Allocator {
        return self.mapr.getArena();
    }

    fn streamValue(tag: ValueTag, reader: *IoReader, writer: *IoWriter) !void {
        switch (tag) {
            .void => unreachable,
            .byte => try reader.streamExact(writer, 1),
            .short => try reader.streamExact(writer, 2),
            .int, .float => try reader.streamExact(writer, 4),
            .long, .double => try reader.streamExact(writer, 8),
            .string => try reader.streamExact(writer, 2 + @as(usize, try reader.peekInt(u16, .big))),

            .list, .byte_array, .int_array, .long_array => {
                const type_tag: ValueTag, const bpe: ?usize = type_sw: switch (tag) {
                    .list => {
                        const t = try reader.takeEnum(ValueTag, .big);
                        try writer.writeByte(@intFromEnum(t));
                        const bpe: ?usize = switch (t) {
                            .void => null,
                            .byte => 1,
                            .short => 2,
                            .int => 4,
                            .float => 4,
                            .long => 8,
                            .double => 8,
                            .list, .byte_array, .int_array, .long_array => null,
                            .compound => null,
                            .string => null,
                        };
                        break :type_sw .{ t, bpe };
                    },
                    .byte_array => .{ .byte, 1 },
                    .int_array => .{ .int, 4 },
                    .long_array => .{ .long, 8 },
                    else => unreachable,
                };

                const len = try reader.takeInt(i32, .big);
                try writer.writeInt(i32, len, .big);
                const length: usize = if (type_tag == .void)
                    0
                else if (len < 0)
                    return error.InvalidLength
                else
                    @intCast(len);

                if (bpe) |bytes_per_element| {
                    try reader.streamExact(writer, 4 + length * bytes_per_element);
                } else for (0..length) |_| {
                    try streamValue(type_tag, reader, writer);
                }
            },
            .compound => {
                while (true) {
                    const t = try reader.takeEnum(ValueTag, .big);
                    try writer.writeByte(@intFromEnum(t));
                    if (t == .void) break;
                    try reader.streamExact(writer, 2 + @as(usize, try reader.peekInt(u16, .big)));
                    try streamValue(t, reader, writer);
                }
            },
        }
    }

    fn readValue(self: *SerialReader, tag: ValueTag, max_value_len: usize, reader: *IoReader, passthrough_state: State) Error!serial.Token {
        switch (tag) {
            .void => unreachable,
            .byte => {
                const v = try reader.takeByteSigned();
                self.state = passthrough_state;
                return .{ .byte = v };
            },
            .short => {
                const v = try reader.takeInt(i16, .big);
                self.state = passthrough_state;
                return .{ .short = v };
            },
            .int => {
                const v = try reader.takeInt(i32, .big);
                self.state = passthrough_state;
                return .{ .int = v };
            },
            .long => {
                const v = try reader.takeInt(i64, .big);
                self.state = passthrough_state;
                return .{ .long = v };
            },
            .float => {
                const v = try reader.takeInt(u32, .big);
                self.state = passthrough_state;
                return .{ .float = @bitCast(v) };
            },
            .double => {
                const v = try reader.takeInt(u64, .big);
                self.state = passthrough_state;
                return .{ .double = @bitCast(v) };
            },
            .string => {
                var aw = IoWriter.Allocating.fromArrayList(self.getAllocator(), &self.string_buffer);
                defer self.string_buffer = aw.toArrayList();
                aw.clearRetainingCapacity();

                _ = streamJavaString(reader, &aw.writer) catch |e| return switch (e) {
                    error.WriteFailed => error.OutOfMemory,
                    else => |err| err,
                };

                if (aw.writer.end >= max_value_len) return error.ValueTooLong;

                self.state = passthrough_state;
                return .{ .string = aw.written() };
            },
            .list, .byte_array, .int_array, .long_array => {
                try self.list_stack.ensureUnusedCapacity(self.getAllocator(), 1);
                try self.mapr.nesting.ensureTotalCapacity(self.getAllocator(), self.mapr.nesting.bit_len + 1);

                const type_tag: ValueTag, const base_type: ?serial.BaseType, const bpe: ?usize = type_sw: switch (tag) {
                    .list => {
                        const t = try reader.takeEnum(ValueTag, .big);
                        const bpe: ?usize, const base_type: ?serial.BaseType = switch (t) {
                            .void => .{ null, null },
                            .byte => .{ 1, .byte },
                            .short => .{ 2, .short },
                            .int => .{ 4, .int },
                            .float => .{ 4, .float },
                            .long => .{ 8, .long },
                            .double => .{ 8, .double },
                            .list, .byte_array, .int_array, .long_array => .{ null, .array },
                            .compound => .{ null, .aggregate },
                            .string => .{ null, .string },
                        };
                        break :type_sw .{ t, base_type, bpe };
                    },
                    .byte_array => .{ .byte, .byte, 1 },
                    .int_array => .{ .int, .int, 4 },
                    .long_array => .{ .long, .long, 8 },
                    else => unreachable,
                };

                const len = try reader.takeInt(i32, .big);
                const length: usize = if (type_tag == .void)
                    0
                else if (len < 0)
                    return error.InvalidLength
                else
                    @intCast(len);
                if (bpe) |bytes_per_element| {
                    if (reader.buffer.len >= (length * bytes_per_element)) {
                        try reader.rebase(length);
                        try reader.fill(length);
                    }
                }

                self.state = .list_value;
                self.mapr.pushNesting(.list) catch unreachable;
                self.list_stack.appendAssumeCapacity(.{
                    .type = type_tag,
                    .left = @bitCast(len),
                });
                return .{ .array_start = .{
                    .length = length,
                    .type = base_type,
                } };
            },
            .compound => {
                try self.mapr.pushNesting(.aggregate);
                self.state = .compound_name;
                return .aggregate_start;
            },
        }
    }

    fn popNesting(self: *SerialReader) void {
        if (self.mapr.peekNesting()) |nt| switch (nt) {
            .list => self.state = .list_value,
            .aggregate => self.state = .compound_name,
        } else self.state = .value_end;
    }

    mapr: MapReader,
    state: State,
    @"error": ?Error,
    string_buffer: std.ArrayList(u8),
    /// A stack of the number of remaining elemnts of lists.
    list_stack: std.ArrayList(struct { type: ValueTag, left: u32 }),
    wrapped_compound_value: ?struct {
        value: []u8,
        end: usize,

        fn toReader(self: @This()) IoReader {
            return .{
                .vtable = IoReader.ending_instance.vtable,
                .buffer = self.value,
                .seek = self.end,
                .end = self.value.len,
            };
        }

        fn redeemReader(self: *@This(), r: IoReader) void {
            self.end = r.seek;
        }
    },
    /// Enable automatic unwrap of nbt elements. Turning this to
    /// `false` will reduce memory usage on lists of compounds (especially
    /// if each of them are somewhat large) at the cost of disabling unwrapping
    /// as a whole.
    ///
    /// Should only be set to `false` if you're 100% sure to not encounter a
    /// single wrapper in your whole data input.
    unwrap_compounds: bool,

    pub fn init(self: *SerialReader, allocator: Allocator, input: *IoReader, named: bool) void {
        self.* = .{
            .mapr = .{
                .reader = input,
                .vtable = &vtable,
                .nesting = .init,
                .arena = .init(allocator),
            },
            .state = .{ .top_value = named },
            .@"error" = null,
            .string_buffer = .empty,
            .list_stack = .empty,
            .wrapped_compound_value = null,
            .unwrap_compounds = true,
        };
    }

    /// Will acquire `arena`'s state, and set it to `.init`.
    ///
    /// Use `.redeemArena()` to get it back.
    pub fn initWithArena(self: *SerialReader, arena: *ArenaAllocator, input: *IoReader, named: bool) void {
        self.init(undefined, input, named);
        self.mapr.arena = arena.*;
        arena.state = .init;
    }

    pub fn deinit(self: *SerialReader) void {
        if (self.wrapped_compound_value) |wcv| {
            self.getAllocator().free(wcv.value);
        }
        self.string_buffer.deinit(self.getAllocator());
        self.list_stack.deinit(self.getAllocator());
        self.mapr.nesting.deinit(self.getAllocator());
        self.mapr.arena.deinit();
        self.* = undefined;
    }

    pub fn redeemArena(self: *SerialReader, arena: *ArenaAllocator) void {
        arena.state = self.mapr.arena.state;
        self.mapr.arena.state = .init;
    }

    pub const Error = IoReader.Error || Allocator.Error || error{
        UnexpectedToken,
        InvalidLength,
        InvalidEnumTag,
        ValueTooLong,
        InvalidString,
    };

    pub fn next(self: *SerialReader, max_value_len: usize) Error!serial.Token {
        var mb_w_cmp = if (self.wrapped_compound_value) |wcv| may_r: {
            if (wcv.end == wcv.value.len) {
                self.getAllocator().free(wcv.value);
                self.wrapped_compound_value = null;
                break :may_r null;
            }
            break :may_r wcv.toReader();
        } else null;
        defer if (mb_w_cmp) |r| {
            if (r.seek == r.end) {
                self.getAllocator().free(self.wrapped_compound_value.?.value);
                self.wrapped_compound_value = null;
            } else {
                self.wrapped_compound_value.?.redeemReader(r);
            }
        };
        var reader = if (mb_w_cmp) |*r| r else self.mapr.reader;

        sw: switch (self.state) {
            .top_value => |is_named| {
                const v_tag = try reader.takeEnum(ValueTag, .big);
                if (is_named) {
                    const num_s = try reader.takeInt(u16, .big);
                    try reader.discardAll(num_s); // TODO: Store string name ?
                }
                if (v_tag == .void) return error.UnexpectedToken;
                self.state = .{ .value = v_tag };
                continue :sw self.state;
            },
            .value => |tag| return self.readValue(tag, max_value_len, reader, .value_end),
            .compound_name => {
                const t = try reader.takeEnum(ValueTag, .big);
                if (t == .void) {
                    assert(self.mapr.popNesting().? == .aggregate);
                    self.popNesting();
                    return .aggregate_end;
                }

                var aw = IoWriter.Allocating.fromArrayList(self.getAllocator(), &self.string_buffer);
                defer self.string_buffer = aw.toArrayList();
                aw.clearRetainingCapacity();

                _ = streamJavaString(reader, &aw.writer) catch |e| return switch (e) {
                    error.WriteFailed => error.OutOfMemory,
                    else => |err| err,
                };

                if (aw.writer.end >= max_value_len) return error.ValueTooLong;

                self.state = .{ .compound_value = t };
                return .{ .string = aw.written() };
            },
            .compound_value => |t| return self.readValue(t, max_value_len, reader, .compound_name),
            .list_value => {
                assert(self.mapr.peekNesting().? == .list);

                const list = &self.list_stack.items[self.list_stack.items.len - 1];
                if (list.left == 0) {
                    _ = self.mapr.popNesting().?;
                    self.list_stack.items.len -= 1;
                    self.popNesting();
                    return .array_end;
                }
                const ret: serial.Token = return_v: switch (list.type) {
                    .compound => {
                        const first_field_hdr = try reader.peekArray(3);
                        const len = std.mem.readInt(u16, first_field_hdr[1..3], .big);
                        if (len != 0) continue :return_v .void; // not a wrapper
                        reader.toss(3);
                        // may be a wrapper

                        const _tag = std.enums.fromInt(ValueTag, first_field_hdr[0]) orelse return error.InvalidEnumTag;

                        if (self.wrapped_compound_value != null) {
                            var discard_w = IoWriter.Discarding.init(&.{});

                            streamValue(_tag, reader, &discard_w.writer) catch |e| switch (e) {
                                error.WriteFailed, error.ReadFailed => unreachable,
                                else => |err| return err,
                            };

                            const next_tag = try reader.peekByte();
                            reader.rebase(discard_w.count) catch unreachable;
                            if (next_tag != 0) continue :return_v .void; // not a wrapper

                            break :return_v try self.readValue(_tag, max_value_len, reader, .list_value);
                        } else {
                            var aw = IoWriter.Allocating.init(self.getAllocator());
                            errdefer aw.deinit();
                            aw.ensureTotalCapacity(3 + 8) catch return error.OutOfMemory;
                            aw.writer.writeAll(first_field_hdr) catch unreachable;

                            streamValue(_tag, reader, &aw.writer) catch |e| switch (e) {
                                error.WriteFailed => return error.OutOfMemory,
                                else => |err| return err,
                            };
                            // cached [<type> 0x0000 "" <payload>]
                            self.wrapped_compound_value = .{
                                .value = try aw.toOwnedSlice(),
                                .end = 0,
                            };

                            const next_tag = try reader.peekByte();
                            var wcv_r = self.wrapped_compound_value.?.toReader();
                            if (next_tag != 0) { // not a wrapper
                                mb_w_cmp = wcv_r;
                                reader = &mb_w_cmp.?;
                                continue :return_v .void;
                            }

                            reader.toss(1);
                            wcv_r.toss(3);

                            defer self.wrapped_compound_value.?.redeemReader(wcv_r);

                            break :return_v try self.readValue(_tag, max_value_len, &wcv_r, .list_value);
                        }
                    },
                    else => try self.readValue(list.type, max_value_len, reader, .list_value),
                };
                list.left -= 1;

                return ret;
            },
            .value_end => return error.UnexpectedToken,
        }
    }
};

/// Returns the number of uft8 codepoint read
fn streamJavaString(reader: *IoReader, writer: *IoWriter) StreamStringError!usize {
    const len = try reader.takeInt(u16, .big);
    writer.rebase(0, len) catch {};
    var cp_count: usize = 0;
    var read: usize = 0;

    var cp_out: [4]u8 = undefined;

    while (read < len) : (cp_count += 1) {
        const codepoint = decodeJavaCodepoint(reader, &read) catch |e| switch (e) {
            error.InvalidString => 0xFFFD,
            else => |err| return err,
        };

        // wtf8 allows surrogate codepoints, but they will technically never happen
        // in this case. It is used to avoid the "Utf8CannotEncodeSurrogateHalf" error
        // that is possible to be returned with the regular "utf8Encode" function.
        const l = std.unicode.wtf8Encode(codepoint, &cp_out) catch return error.InvalidString;
        try writer.writeAll(cp_out[0..l]);
    }

    return cp_count;
}

fn decodeJavaCodepoint(reader: *IoReader, read: *usize) !u21 {
    const lead_byte = try reader.takeByte();
    read.* += 1;
    var codepoint_full: u21 = undefined;
    switch (lead_byte) {
        0b00000000...0b01111111 => codepoint_full = lead_byte,
        0b11000000...0b11011111 => { // 2 bytes value
            const contib = try reader.takeByte();
            read.* += 1;
            if (contib & 0b11000000 != 0b10000000) return error.InvalidString;
            codepoint_full = (@as(u16, lead_byte & 0b11111) << 6) | (contib & 0b00111111);
        },
        0b11100000...0b11101111 => { // 3 bytes value
            const contib1 = try reader.takeByte();
            read.* += 1;
            if (contib1 & 0b11000000 != 0b10000000) return error.InvalidString;
            const contib2 = try reader.takeByte();
            read.* += 1;
            if (contib2 & 0b11000000 != 0b10000000) return error.InvalidString;

            const codepoint: u16 = (@as(u16, lead_byte & 0b1111) << 12) |
                (@as(u16, contib1 & 0b00111111) << 6) |
                (@as(u16, contib2 & 0b00111111));
            codepoint_full = sw: switch (codepoint) {
                0xD800...0xDBFF => {
                    const lead_byte2 = try reader.takeByte();
                    read.* += 1;
                    if (lead_byte2 & 0b11110000 != 0b11100000) return error.InvalidString;
                    const contib1_2 = try reader.takeByte();
                    read.* += 1;
                    if (contib1_2 & 0b11000000 != 0b10000000) return error.InvalidString;
                    const contib2_2 = try reader.takeByte();
                    read.* += 1;
                    if (contib2_2 & 0b11000000 != 0b10000000) return error.InvalidString;

                    const surrogate2: u16 = (@as(u16, lead_byte2 & 0b1111) << 12) |
                        (@as(u16, contib1_2 & 0b00111111) << 6) |
                        (@as(u16, contib2_2 & 0b00111111));

                    if (surrogate2 < 0xDC00 or surrogate2 > 0xDFFF) return error.InvalidString;

                    break :sw ((@as(u21, codepoint - 0xD800) << 10) + 0x10000) | @as(u21, surrogate2 - 0xDC00);
                },
                0xDC00...0xDFFF => return error.InvalidString, // low-surrogate codepoint
                else => codepoint,
            };
        },
        else => return error.InvalidString,
    }
    return codepoint_full;
}

inline fn writeJavaString(writer: *IoWriter, str: []const u8) WriteError!void {
    return writeJavaStringVec(writer, (&str)[0..1]);
}

inline fn calcJavaStringLength(str: []const u8) error{ InvalidLength, InvalidString }!u16 {
    return calcJavaStringLengthVec((&str)[0..1]);
}

/// So NBT uses "modified utf8" or what-the-fuck-ever.
fn writeJavaStringVec(writer: *IoWriter, strs: []const []const u8) WriteError!void {
    const total_len = try calcJavaStringLengthVec(strs);
    try writer.writeInt(u16, total_len, .big);
    if (total_len == 0) return;

    for (strs) |str| {
        var it = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
        while (it.nextCodepointSlice()) |cp_s| {
            const cp = std.unicode.utf8Decode(cp_s) catch unreachable;
            switch (cp) {
                0x01...0x7F => try writer.writeByte(@truncate(cp)),
                0, 0x080...0x3FF => try writer.writeAll(&[2]u8{
                    0b11000000 | (@as(u8, @truncate(cp >> 6)) & 0b00011111),
                    0b10000000 | (@as(u8, @truncate(cp)) & 0b00111111),
                }),
                0x400...0xFFFF => try writer.writeAll(&[3]u8{
                    0b11100000 | (@as(u8, @truncate(cp >> 12)) & 0b00001111),
                    0b10000000 | (@as(u8, @truncate(cp >> 6)) & 0b00111111),
                    0b10000000 | (@as(u8, @truncate(cp)) & 0b00111111),
                }),
                0x10000...0x10FFFF => {
                    const hi = 0xD800 | ((cp - 0x10000) >> 10);
                    const lo = 0xDC00 | (cp & 0x3FF);
                    try writer.writeAll(&[6]u8{
                        0b11100000 | (@as(u8, @truncate(hi >> 12)) & 0b00001111),
                        0b10000000 | (@as(u8, @truncate(hi >> 6)) & 0b00111111),
                        0b10000000 | (@as(u8, @truncate(hi)) & 0b00111111),
                        0b11100000 | (@as(u8, @truncate(lo >> 12)) & 0b00001111),
                        0b10000000 | (@as(u8, @truncate(lo >> 6)) & 0b00111111),
                        0b10000000 | (@as(u8, @truncate(lo)) & 0b00111111),
                    });
                },
                else => unreachable,
            }
        }
    }
}

fn calcJavaStringLengthVec(strs: []const []const u8) error{ InvalidLength, InvalidString }!u16 {
    var total_len: u16 = 0;
    for (strs) |str| {
        const view = std.unicode.Utf8View.init(str) catch return error.InvalidString;
        var it = view.iterator();
        while (it.nextCodepointSlice()) |cp_s| {
            const cp = std.unicode.utf8Decode(cp_s) catch unreachable;
            const len: u3 = switch (cp) {
                0x01...0x7F => 1,
                0, 0x080...0x3FF => 2,
                0x400...0xFFFF => 3,
                0x10000...0x10FFFF => 6,
                else => unreachable,
            };

            total_len = std.math.add(u16, total_len, len) catch return error.InvalidLength;
        }
    }
    return total_len;
}

fn writeValueRaw(writer: *IoWriter, value: Value) WriteError!void {
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
            if (list.type == .void and list.len != 0) return error.InvalidEnumTag;
            try writer.writeByte(@intFromEnum(list.type));
            try writer.writeInt(i32, list.len, .big);
            switch (list.type) {
                .void => {},
                inline .byte, .short, .int, .long => |tag| {
                    const arr = list.getValuesAs(tag).?;
                    const ChildInt = @Int(.unsigned, @bitSizeOf(@typeInfo(@TypeOf(arr)).pointer.child));
                    try writer.writeSliceEndian(ChildInt, @ptrCast(arr), .big);
                },
                inline else => |tag| for (list.getValuesAs(tag).?) |v| {
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(List);
    std.testing.refAllDecls(DynamicList);
    std.testing.refAllDecls(StreamedValue);
    std.testing.refAllDecls(Value);
    std.testing.refAllDecls(SerialWriter);
    std.testing.refAllDecls(SerialReader);
}
