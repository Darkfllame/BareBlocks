const std = @import("std");
const net = @import("net");
const core = @import("core");
const coro = @import("coro");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    _=init;
}

test {
    std.testing.refAllDecls(@This());
}
