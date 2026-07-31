const std = @import("std");

pub const StructuredPacket = @import("StructuredPacket.zig");
pub const packets = @import("packets.zig");

pub const PacketType = StructuredPacket.Type;

test {
    std.testing.refAllDecls(@This());
}
