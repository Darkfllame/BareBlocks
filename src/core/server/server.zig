const std = @import("std");

pub const EventLoop = @import("EventLoop.zig");

test {
    std.testing.refAllDecls(@This());
}
