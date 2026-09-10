const std = @import("std");
const serial = @import("serial.zig");

const Stringify = std.json.Stringify;
const Scanner = std.json.Scanner;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;
const IoWriter = std.Io.Writer;
const IoReader = std.Io.Reader;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

pub const SerialWriter = struct {
    const vtable = MapWriter.VTable{
        .fieldName = fieldName,
        .writeBoolean = writeBoolean,
        .writeByte = writeByte,
        .writeShort = writeShort,
        .writeInt = writeInt,
        .writeLong = writeLong,
        .writeFloat = writeFloat,
        .writeDouble = writeDouble,
        .writeString = writeString,
        .stringWriter = stringWriter,
        .beginArray = beginArray,
        .endArray = endArray,
        .beginAggregate = beginAggregate,
        .endAggregate = endAggregate,
    };

    const string_writer_vtable = IoWriter.VTable{
        .drain = &sw_drain,
        .flush = &sw_flush,
    };

    fn sw_drain(iow: *IoWriter, data: []const []const u8, splat: usize) IoWriter.Error!usize {
        const self: *SerialWriter = @fieldParentPtr("string_writer", iow);
        const base_length = self.string_buffer.items.len;
        const pattern = data[data.len - 1];
        for (data[0 .. data.len - 1]) |s| {
            self.string_buffer.appendSlice(self.allocator, s) catch |e| {
                self.@"error" = e;
                return error.WriteFailed;
            };
        }
        switch (splat) {
            0 => {},
            1 => self.string_buffer.appendSlice(self.allocator, pattern) catch |e| {
                self.@"error" = e;
                return error.WriteFailed;
            },
            else => switch (pattern.len) {
                0 => {},
                1 => {
                    const s = self.string_buffer.addManyAsSlice(self.allocator, splat) catch |e| {
                        self.@"error" = e;
                        return error.WriteFailed;
                    };
                    @memset(s, pattern[0]);
                },
                else => for (0..splat) |_| {
                    self.string_buffer.appendSlice(self.allocator, pattern) catch |e| {
                        self.@"error" = e;
                        return error.WriteFailed;
                    };
                },
            },
        }

        return self.string_buffer.items.len - base_length;
    }

    fn sw_flush(iow: *IoWriter) IoWriter.Error!void {
        const self: *SerialWriter = @fieldParentPtr("string_writer", iow);
        self.string_writer = .failing;
        self.string_buffer.appendSlice(self.allocator, iow.buffered()) catch |e| {
            self.@"error" = e;
            return error.WriteFailed;
        };
        try Stringify.encodeJsonStringChars(self.string_buffer.items, .{}, self.jss.writer);
        try self.jss.writer.writeByte('"');
        self.jss.endWriteRaw();
    }

    fn fieldName(mapw: *MapWriter, name: []const u8) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.objectField(name);
    }

    fn writeBoolean(mapw: *MapWriter, value: bool) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeByte(mapw: *MapWriter, value: i8) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeShort(mapw: *MapWriter, value: i16) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeInt(mapw: *MapWriter, value: i32) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeLong(mapw: *MapWriter, value: i64) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeFloat(mapw: *MapWriter, value: f32) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeDouble(mapw: *MapWriter, value: f64) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn writeString(mapw: *MapWriter, value: []const u8) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.write(value);
    }

    fn stringWriter(mapw: *MapWriter, length: ?usize, buffer: []u8) MapWriter.WriteError!*IoWriter {
        _ = length;
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.beginWriteRaw();
        try self.jss.writer.writeByte('"');
        self.string_writer = .{
            .vtable = &string_writer_vtable,
            .buffer = buffer,
        };
        self.string_buffer.clearRetainingCapacity();
        return &self.string_writer;
    }

    fn beginArray(mapw: *MapWriter, length: ?usize) MapWriter.WriteError!void {
        _ = length;
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.beginArray();
    }

    fn endArray(mapw: *MapWriter) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.endArray();
    }

    fn beginAggregate(mapw: *MapWriter) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.beginObject();
    }

    fn endAggregate(mapw: *MapWriter) MapWriter.WriteError!void {
        const self: *SerialWriter = @fieldParentPtr("mapw", mapw);
        try self.jss.endObject();
    }

    mapw: MapWriter,
    jss: Stringify,
    string_writer: IoWriter,
    @"error": ?Allocator.Error,
    allocator: Allocator,
    string_buffer: std.ArrayList(u8),

    /// `jsopt` will only save `whitespace` and `escape_unicode` fields, the others will be ignored.
    pub fn init(self: *SerialWriter, allocator: Allocator, writer: *IoWriter, jsopt: Stringify.Options) void {
        self.* = .{
            .mapw = .{
                .writer = writer,
                // generally if you tell it to be minified you want to use as less space as possible
                .output_type = if (jsopt.whitespace != .minified) .human_readable else .text,
                .vtable = &vtable,
            },
            .jss = .{
                .writer = writer,
                .options = .{
                    .whitespace = jsopt.whitespace,
                    .emit_null_optional_fields = false,
                    .emit_strings_as_arrays = false,
                    .escape_unicode = jsopt.escape_unicode,
                    .emit_nonportable_numbers_as_strings = false,
                },
            },
            .string_writer = .failing,
            .@"error" = null,
            .allocator = allocator,
            .string_buffer = .empty,
        };
    }

    pub fn deinit(self: *SerialWriter) void {
        self.string_buffer.deinit(self.allocator);
    }
};
pub const SerialReader = struct {
    const vtable = MapReader.VTable{
        .next = nextImpl,
        .skip = skipImpl,
    };

    const State = enum { field_name, value, end_value };

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

    fn skipWhitespace(self: *SerialReader) Error!void {
        const reader = self.mapr.reader;
        search_ws: while (true) {
            const s = try reader.peekGreedy(1);
            for (s, 0..) |c, i| switch (c) {
                ' ', '\t', '\n', '\r' => continue,
                else => {
                    reader.toss(i);
                    break :search_ws;
                },
            };
            reader.toss(s.len);
        }
    }

    fn readContinuationByte(self: *SerialReader) Error!u21 {
        return switch (try self.mapr.reader.takeByte()) {
            0b10000000...0b10111111 => |c| c & 0b00111111,
            else => error.InvalidString,
        };
    }

    fn readCodepointShort(self: *SerialReader) Error!u21 {
        const reader = self.mapr.reader;
        const first = try reader.takeByte();
        var codepoint_full: u21 = undefined;
        switch (first) {
            '\\' => {
                reader.toss(1);
                return switch (try reader.takeByte()) {
                    '\\' => '\\',
                    '"' => '"',
                    '/' => '/',
                    'b' => 0x1b,
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'u' => {
                        var hex: [4]u8 = undefined;
                        try reader.readSliceAll(&hex);
                        return std.fmt.parseInt(u16, "0x" ++ hex, 16) catch error.InvalidString;
                    },
                    else => error.InvalidString,
                };
            },
            0b00000000...('\\' - 1), ('\\' + 1)...0b01111111 => return first,
            0b11000000...0b11011111 => {
                const second = try self.readContinuationByte();
                codepoint_full = (@as(u21, first & 0b00011111) << 6) | second;
            },
            0b11100000...0b11101111 => {
                const second = try self.readContinuationByte();
                const third = try self.readContinuationByte();
                codepoint_full = (@as(u21, first & 0b00001111) << 12) | (second << 6) | third;
            },
            0b11110000...0b11110111 => {
                const second = try self.readContinuationByte();
                const third = try self.readContinuationByte();
                const fourth = try self.readContinuationByte();
                codepoint_full = (@as(u21, first & 0b00000111) << 18) | (second << 12) | (third << 6) | fourth;
            },
            else => return error.InvalidString,
        }
        return codepoint_full;
    }

    fn readCodepoint(self: *SerialReader) Error!u21 {
        const first = try self.readCodepointShort();
        return switch (first) {
            0xD800...0xDBFF => {
                const second = try self.readCodepointShort();
                if (second < 0xDC00 or second > 0xDFFF) return error.InvalidString;
                return (((first - 0xD800) << 10) + 0x10000) | (second - 0xDC00);
            },
            0xDC00...0xDFFF => error.InvalidString,
            else => first,
        };
    }

    mapr: MapReader,
    @"error": ?Error,
    string_buffer: std.ArrayList(u8),
    state: State,

    pub const Error = IoReader.Error || Allocator.Error || error{
        UnexpectedToken,
        InvalidLength,
        ValueTooLong,
        InvalidString,
    };

    pub fn init(self: *SerialReader, allocator: Allocator, reader: *IoReader) void {
        self.* = .{
            .mapr = .{
                .reader = reader,
                .vtable = &vtable,
                .nesting = .init,
                .arena = .init(allocator),
            },
            .@"error" = null,
            .string_buffer = .empty,
            .state = .value,
        };
    }

    pub fn initWithArena(self: *SerialReader, arena: *std.heap.ArenaAllocator, reader: *IoReader) void {
        self.init(undefined, reader);
        self.mapr.arena = arena.*;
        arena.state = .init;
    }

    pub fn deinit(self: *SerialReader) void {
        self.string_buffer.deinit(self.getAllocator());
        self.mapr.nesting.deinit(self.getAllocator());
    }

    pub fn redeemArena(self: *SerialReader, arena: *std.heap.ArenaAllocator) void {
        arena.state = self.mapr.arena.state;
        self.mapr.arena.state = .init;
    }

    pub fn next(self: *SerialReader, max_value_len: usize) Error!serial.Token {
        const reader = self.mapr.reader;
        try self.skipWhitespace();

        sw: switch (self.state) {
            .end_value => {
                const c = try reader.takeByte();
                switch (c) {
                    ']' => {
                        assert(self.mapr.popNesting().? == .list);
                        self.state = .end_value;
                        return .array_end;
                    },
                    '}' => {
                        assert(self.mapr.popNesting().? == .aggregate);
                        self.state = .end_value;
                        return .aggregate_end;
                    },
                    ',' => {
                        self.state = if (self.mapr.peekNesting()) |nt| switch (nt) {
                            .list => .value,
                            .aggregate => .field_name,
                        } else return error.EndOfStream;
                        continue :sw self.state;
                    },
                    else => return error.UnexpectedToken,
                }
            },
            .value => {
                const c = try reader.takeByte();

                switch (c) {
                    ',' => continue :sw .end_value,
                    '{' => {
                        self.state = .field_name;
                        try self.mapr.pushNesting(.aggregate);
                        return .aggregate_start;
                    },
                    '[' => {
                        self.state = .value;
                        try self.mapr.pushNesting(.list);
                        return .{ .array_start = .{
                            .length = null,
                            .type = null,
                        } };
                    },
                    '"' => {
                        self.string_buffer.clearRetainingCapacity();
                        var tmp: [4]u8 = undefined;
                        while (true) {
                            const byte = try reader.peekByte();
                            switch (byte) {
                                '"' => break,
                                '\n', '\r', 0xc, 0x1b => return error.InvalidString,
                                else => {},
                            }
                            if (self.string_buffer.items.len > max_value_len) return error.ValueTooLong;
                            const cp = try self.readCodepoint();
                            const n = std.unicode.wtf8Encode(cp, &tmp) catch unreachable;
                            try self.string_buffer.appendSlice(self.getAllocator(), tmp[0..n]);
                        }
                        reader.toss(1);
                        self.state = .end_value;
                        return .{ .string = self.string_buffer.items };
                    },
                    'f', 't' => {
                        const max_len = @max("true".len, "false".len);
                        self.string_buffer.clearRetainingCapacity();
                        try self.string_buffer.ensureTotalCapacity(self.getAllocator(), max_len);
                        self.string_buffer.appendAssumeCapacity(c);

                        while (true) {
                            const byte = try reader.peekByte();
                            switch (byte) {
                                ',', ' ', '\n', '\r', '\t', 0xc => break,
                                'r', 'u', 'e', 'a', 'l', 's' => {},
                                else => return error.UnexpectedToken,
                            }
                            self.string_buffer.appendBounded(byte) catch return error.UnexpectedToken;
                        }
                        self.state = .end_value;
                        const items = self.string_buffer.items;
                        return .{ .boolean = if (std.mem.eql(u8, items, "false"))
                            false
                        else if (std.mem.eql(u8, items, "true"))
                            true
                        else
                            return error.UnexpectedToken };
                    },
                    '0'...'9' => {
                        self.string_buffer.clearRetainingCapacity();
                        try self.string_buffer.append(self.getAllocator(), c);

                        while (true) {
                            const byte = try reader.peekByte();
                            switch (byte) {
                                ',', ' ', '\n', '\r', '\t', 0xc, ']', '}' => break,
                                '0'...'9', 'e', 'E', '-', '.' => {},
                                else => return error.UnexpectedToken,
                            }
                            reader.toss(1);
                            if (self.string_buffer.items.len > max_value_len) return error.ValueTooLong;
                            try self.string_buffer.append(self.getAllocator(), byte);
                        }
                        self.state = .end_value;
                        const items = self.string_buffer.items;

                        if (std.fmt.parseInt(i64, items, 10)) |v| {
                            return .{ .long = v };
                        } else |_| if (std.fmt.parseFloat(f64, items)) |v| {
                            return .{ .double = v };
                        } else |_| return error.UnexpectedToken;
                    },
                    else => return error.UnexpectedToken,
                }
            },
            .field_name => {
                assert(self.mapr.peekNesting().? == .aggregate);

                switch (try reader.takeByte()) {
                    '"' => {},
                    else => return error.UnexpectedToken,
                }
                self.string_buffer.clearRetainingCapacity();
                var tmp: [4]u8 = undefined;
                while (true) {
                    const byte = try reader.peekByte();
                    switch (byte) {
                        '"' => break,
                        '\n', '\r', 0xc, 0x1b => return error.InvalidString,
                        else => {},
                    }
                    if (self.string_buffer.items.len > max_value_len) return error.ValueTooLong;
                    const cp = try self.readCodepoint();
                    const n = std.unicode.wtf8Encode(cp, &tmp) catch unreachable;
                    try self.string_buffer.appendSlice(self.getAllocator(), tmp[0..n]);
                }
                reader.toss(1);
                try self.skipWhitespace();
                if ((try reader.takeByte()) != ':') return error.UnexpectedToken;
                self.state = .value;
                return .{ .string = self.string_buffer.items };
            },
        }
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(SerialWriter);
    std.testing.refAllDecls(SerialReader);
}
