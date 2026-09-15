const std = @import("std");
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
    var ca = utils.CountingAllocator.init(init.gpa, true);
    defer ca.deinit();

    try server.init(.{
        .allocator = if (utils.is_debug) ca.allocator() else init.gpa,
        .io = init.io,
        .bind_port_v6 = 35565,
        // .broadcast = true,
    });
    defer server.deinit();

    std.log.info("Listening on {f}", .{server.addressAlt()});

    var last_print_time = std.Io.Timestamp.now(init.io, .boot);

    while (true) {
        try server.tick();
        const now = std.Io.Timestamp.now(init.io, .boot);
        if (utils.is_debug and last_print_time.durationTo(now).toSeconds() >= 30) {
            last_print_time = now;
            std.log.debug("Counting alloc: (total: {d}, slots: {d}, largest: {d})", .{ ca.total, ca.allocs.items.len, ca.largestAllocation() });
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
