const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const Io = std.Io;

var ert_buf: [4096]usize = undefined;

pub fn main(init: std.process.Init) !void {
    var server = try init.gpa.create(core.Server);
    defer init.gpa.destroy(server);

    if (@errorReturnTrace()) |ert| {
        ert.instruction_addresses = &ert_buf;
    }

    var ca = utils.CountingAllocator.init(init.gpa, true);
    defer ca.deinit();

    try server.init(.{
        .allocator = ca.allocator(),
        .io = init.io,
        .bind_port_v6 = 35565,
    });
    defer server.deinit();

    std.log.info("Listening on {f}", .{server.addressAlt()});

    while (true) {
        try server.tick();
        std.log.debug("Counting alloc: (total: {d}, slots: {d}, largest: {d})", .{ ca.total, ca.allocs.items.len, ca.largestAllocation() });
    }
}

test {
    std.testing.refAllDecls(@This());
}
