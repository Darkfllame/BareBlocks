const std = @import("std");
const serial = @import("../serial.zig");

const Stringify = std.json.Stringify;
const Scanner = std.json.Scanner;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;
const IoWriter = std.Io.Writer;
const IoReader = std.Io.Reader;
const Allocator = std.mem.Allocator;

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
    mapr: MapReader,

    comptime {
        @compileError("TODO: Make json reader");
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(SerialWriter);
    std.testing.refAllDecls(SerialReader);
}
