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

pub const StructuredPacket = @import("StructuredPacket.zig");
pub const packets = @import("packets.zig");
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
    arena_state: std.heap.ArenaAllocator.State,
    entries: std.EnumArray(NetworkingSide, std.EnumArray(NetworkingPhase, std.ArrayList(Entry))),

    pub const empty = PacketRegistry{
        .arena_state = .init,
        .entries = .initFill(.initFill(.empty)),
    };

    pub const Entry = struct {
        write_cushion: usize,
        resource: []const u8,
        callback: *const Connection.ReadCallbackFn,
    };

    pub fn addEntry(
        self: *PacketRegistry,
        allocator: Allocator,
        side: NetworkingSide,
        phase: NetworkingPhase,
        entry: Entry,
        copy_resource: bool,
    ) Allocator.Error!PacketID {
        const list = self.entries.getPtr(side).getPtr(phase);
        for (list.items, 0..) |en, i| {
            if (std.mem.eql(u8, en.resource, entry.resource)) return @enumFromInt(i);
        }

        try list.ensureUnusedCapacity(allocator, 1);

        var new_entry = entry;
        new_entry.resource = if (copy_resource) blk: {
            var arena = self.arena_state.promote(allocator);
            const val = try arena.allocator().dupe(u8, entry.resource);
            self.arena_state = arena.state;
            break :blk val;
        } else entry.resource;

        const id: PacketID = @enumFromInt(list.items.len);
        list.appendAssumeCapacity(new_entry);

        return id;
    }

    pub fn getCallback(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?*const Connection.ReadCallbackFn {
        const list = self.entries.getPtrConst(side).getPtrConst(phase);
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.resource, resource)) return entry.callback;
        }
        return null;
    }

    pub fn packedIDFromResource(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?PacketID {
        const list = self.entries.getPtrConst(side).getPtrConst(phase);
        for (list.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.resource, resource)) return @enumFromInt(i);
        }
        return null;
    }

    pub fn getEntry(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, id: PacketID) *const Entry {
        return &self.entries.getPtrConst(side).getPtrConst(phase).items[@intFromEnum(id)];
    }

    pub fn getPacketID(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, id: i32) ?PacketID {
        const entries = self.entries.getPtrConst(side).getPtrConst(phase).items;
        if (id < 0 or entries.len <= id) return null;
        return @enumFromInt(id);
    }
};


test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PacketRegistry);
    std.testing.refAllDecls(Connection);
}
