const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const utils = @import("utils");

const Io = std.Io;

var ert_buf: [8 * 1024]usize = undefined;

pub fn main(init: std.process.Init) !void {
    var server = try init.gpa.create(core.Server);
    defer init.gpa.destroy(server);

    if (@errorReturnTrace()) |ert| {
        ert.instruction_addresses = &ert_buf;
    }

    // Should take no memory except in debug mode

    try server.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .bind_port_v6 = 35565,
        // .broadcast = true,
    });
    defer server.deinit();

    std.log.info("Listening on {f}", .{server.addressAlt()});

    while (true) {
        try server.tick();
    }
}

test {
    std.testing.refAllDecls(@This());
}
