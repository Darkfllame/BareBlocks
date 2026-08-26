const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const serial = utils.serial;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const Foo = struct { a: f32, b: u32 };

pub fn main(init: std.process.Init) !void {
    const tc = utils.TextComponent.text("Hello World!", .{});

    const content = blk: {
        var aw = std.Io.Writer.Allocating.init(init.gpa);
        errdefer aw.deinit();

        var nbt_w: serial.nbt.Writer = undefined;
        nbt_w.init(init.gpa, &aw.writer);
        defer nbt_w.deinit();

        try tc.serialize(&nbt_w.mapw);

        break :blk try aw.toOwnedSlice();
    };
    defer init.gpa.free(content);
    var content_reader = std.Io.Reader.fixed(content);

    var nbt_r: serial.nbt.Reader = undefined;
    nbt_r.init(init.gpa, &content_reader, false);
    defer nbt_r.deinit();

    const tc2 = try utils.TextComponent.deserialize(&nbt_r.mapr);

    std.log.debug("{f}", .{tc});
    std.log.debug("{f}", .{tc2});
}
