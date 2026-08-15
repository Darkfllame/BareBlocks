const std = @import("std");
const utils = @import("utils");

const serial = utils.serial;

pub fn main(init: std.process.Init) !void {
    var ca = utils.CountingAllocator.init(init.gpa, true);
    defer ca.deinit();

    const gpa = ca.allocator();

    const nbt_data = blk: {
        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        var nbt_w: serial.nbt.Writer = undefined;
        nbt_w.init(gpa, &aw.writer);
        defer nbt_w.deinit();

        try nbt_w.beginArray(null);
        {
            try nbt_w.beginCompound();
            {
                try nbt_w.setFieldName("a");
                try nbt_w.beginArray(null);
                {
                    try nbt_w.beginCompound();
                    {
                        try nbt_w.setFieldName("");
                        try nbt_w.beginArray(null);
                        try nbt_w.endArray();
                    }
                    try nbt_w.endCompound();
                }
                try nbt_w.endArray();
            }
            try nbt_w.endCompound();
        }
        try nbt_w.endArray();

        break :blk try aw.toOwnedSlice();
    };
    defer gpa.free(nbt_data);
    var nbt_input = std.Io.Reader.fixed(nbt_data);
    std.log.info("Largest allocation: {f}", .{ca});

    std.debug.dumpHex(nbt_data);

    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    var nbt_r: serial.nbt.Reader = undefined;
    nbt_r.init(gpa, &nbt_input, false);
    defer nbt_r.deinit();

    var json_w: serial.json.Writer = undefined;
    json_w.init(gpa, &stdout.interface, .{ .whitespace = .indent_2 });
    defer json_w.deinit();

    try nbt_r.mapr.mapToWriter(256, &json_w.mapw);

    try stdout.interface.flush();
}
