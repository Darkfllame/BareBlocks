const std = @import("std");

pub const Client = @import("Client.zig");
pub const Renderer = @import("Renderer.zig");

pub const logger = std.log.scoped(.bare_blocks);

test {
    std.testing.refAllDecls(@This());
}
