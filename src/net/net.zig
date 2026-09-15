const std = @import("std");
const builtin = @import("builtin");
const coro = @import("coro");
const utils = @import("utils");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const math = std.math;
const TextComponent = utils.TextComponent;

const assert = std.debug.assert;

const static_io = coro.AnyCoroutine.static_io;

pub const logger = std.log.scoped(.net);

pub const packets = @import("packets.zig");
pub const datagram = @import("datagram.zig");
pub const StructuredPacket = @import("StructuredPacket.zig");
pub const Connection = @import("Connection.zig");

pub const PacketType = StructuredPacket.Type;

pub const NetworkingSide = enum {
    client,
    server,

    pub fn opposite(self: NetworkingSide) NetworkingSide {
        return switch (self) {
            .client => .server,
            .server => .client,
        };
    }
};
pub const NetworkingPhase = enum { handshake, status, login, configuration, play };
pub const PacketID = enum(u16) { _ };

pub const PacketRegistry = struct {
    entries: std.EnumArray(NetworkingSide, std.EnumArray(NetworkingPhase, []const Entry)),

    pub const empty = PacketRegistry{
        .entries = .initFill(.initFill(&.{})),
    };

    pub const Entry = struct {
        write_cushion: usize,
        resource: []const u8,
        callback: ?*const Connection.ReadCallbackFn,
    };

    pub fn getCallback(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?*const Connection.ReadCallbackFn {
        const list = self.entries.getPtrConst(side).get(phase);
        for (list) |entry| {
            if (std.mem.eql(u8, entry.resource, resource)) return entry.callback;
        }
        return null;
    }

    pub fn packedIDFromResource(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?PacketID {
        const list = self.entries.getPtrConst(side).get(phase);
        for (list, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.resource, resource)) return @enumFromInt(i);
        }
        return null;
    }

    pub fn getEntry(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, id: PacketID) *const Entry {
        return &self.entries.getPtrConst(side).get(phase)[@intFromEnum(id)];
    }

    pub fn getPacketID(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, id: i32) ?PacketID {
        const entries = self.entries.getPtrConst(side).get(phase);
        if (id < 0 or entries.len <= id) return null;
        return @enumFromInt(id);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(NetworkingSide);
    std.testing.refAllDecls(PacketRegistry);
}
