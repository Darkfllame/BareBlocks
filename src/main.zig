const std = @import("std");
const core = @import("core");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var server = try init.gpa.create(core.Server);
    defer init.gpa.destroy(server);

    try server.init(.{
        .allocator = init.gpa,
        .io = init.io,
    });
    defer server.deinit();

    std.log.info("Listening on {f}", .{server.sock.socket.address});

    while (true) {
        try server.tick();
    }
}

test {
    std.testing.refAllDecls(@This());
}
