const std = @import("std");

pub const Region = @import("Region.zig");

test {
    std.testing.refAllDecls(@This());
}
