const PlayerManager = @This();
const std = @import("std");
const zio = @import("zio");
const utils = @import("utils");
const net = @import("net");
const lm = @import("math");
const core = @import("core.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const UUID = utils.UUID;
const Player = core.Player;

const logger = std.log.scoped(.@"core/PlayerManager");

const Event = union(enum) {
    player_join: *Player,
    player_remove: UUID,
    get_by_uuid: struct { uuid: UUID, result: *utils.Awaitable(?*Player) },
    get_by_name: struct { name: []const u8, result: *utils.Awaitable(?*Player) },
    broadcast: struct { text: utils.TextComponent, overlay: bool },
    // chat_broadcast: struct { player: *Player, text: utils.TextComponent },
};

fn playerInfoEntry(player: *const core.Player) net.packets.PlayerInfoEntry {
    return .{
        .profile = player.profile,
        .chat_session = @as(?net.packets.ChatSession, null),
        .game_mode = .creative,
        .listed = true,
        .ping = @intCast(@min(player.getLatency(), std.math.maxInt(i32))),
        .display_name = @as(?utils.TextComponent, null),
        .priority = 0,
        .hat_visible = true,
    };
}

fn addPlayer(self: *PlayerManager, player: *Player, apair: net.PacketType.AllocPair) !void {
    const gpa = self.owner.allocator;

    const player_info = net.packets.player_info_initialize_s2c;
    const PlayerEntry = net.packets.PlayerInfoEntry;

    const gop = try self.by_uuid.getOrPut(gpa, player.getGameProfile().uuid);
    if (gop.found_existing) return error.DoubleConnect;
    gop.value_ptr.* = player;
    errdefer self.by_uuid.removeByPtr(gop.key_ptr);

    try self.players.append(gpa, player);
    errdefer _ = self.players.swapRemove(self.players.items.len - 1);

    _ = self.player_count.fetchAdd(1, .monotonic);
    errdefer _ = self.player_count.fetchSub(1, .monotonic);

    var new_entry = [_]PlayerEntry{playerInfoEntry(player)};
    const others = try apair.arena.alloc(PlayerEntry, self.players.items.len - 1);

    var i: usize = 0;
    for (self.players.items) |plr| {
        try plr.sendPackets(apair, player_info.named("player_info_update", .{
            .actions = .full,
            .players = &new_entry,
        }));
        if (plr == player) continue;
        others[i] = playerInfoEntry(plr);
        i += 1;
    }
    if (others.len != 0) {
        try player.sendPackets(apair, player_info.named("player_info_update", .{
            .actions = .full,
            .players = others,
        }));
    }
}

fn handler(self: *PlayerManager) Io.Cancelable!void {
    const gpa = self.owner.allocator;
    const io = self.owner.runtime.io();

    defer {
        zio.beginShield();
        defer zio.endShield();

        self.event_queue.close(.graceful);
        while (self.event_queue.receive()) |ev| switch (ev) {
            .player_join => |plr| plr.release(),
            .player_remove, .broadcast => {},
            inline .get_by_uuid, .get_by_name => |get| get.result.set(io, null),
        } else |_| {}

        for (self.players.items) |plr| {
            plr.disconnect(.{ .static = &.server_shutdown });
            plr.release();
        }

        self.players.deinit(gpa);
        self.by_uuid.deinit(gpa);

        self.end_event.set();
    }

    self.owner.start.wait() catch return;

    var arena: std.heap.ArenaAllocator = undefined;
    const apair = net.PacketType.AllocPair.newFromGpa(gpa, &arena);
    defer arena.deinit();

    while (self.event_queue.receive()) |ev| switch (ev) {
        .player_join => |plr| {
            self.addPlayer(plr, apair) catch |e| {
                plr.release();
                logger.err("Player manager handler error'd with: {t}", .{e});
                self.event_queue.close(.graceful);
                switch (e) {
                    error.OutOfMemory => break,
                    else => {},
                }
            };
            _ = arena.reset(.{ .retain_with_limit = 512 * 1024 });
        },
        .player_remove => |uuid| {
            const plr = (self.by_uuid.fetchRemove(uuid) orelse continue).value;
            defer {
                plr.release();
                _ = self.player_count.fetchSub(1, .monotonic);
            }

            const message: utils.TextComponent = .translate("multiplayer.player.left", .{
                .args = &.{.text(plr.profile.username(), .{})},
                .common = .{ .color = .yellow },
            });
            for (self.players.items, 0..) |plr2, i| {
                if (plr == plr2) {
                    _ = self.players.swapRemove(i);
                    continue;
                }

                plr2.sendPackets(apair, .{
                    net.packets.player_info_remove_s2c.named("player_info_remove", (&uuid)[0..1]),
                    net.packets.system_chat_s2c.named("system_chat", .{
                        .content = message,
                        .overlay = false,
                    }),
                }) catch |e| logger.warn("[{s}] Couldn't send player info: {t}", .{ plr2.getUsername(), e });
            }
        },
        .get_by_uuid => |by_uuid| {
            by_uuid.result.set(io, if (self.by_uuid.get(by_uuid.uuid)) |plr| plr.acquire() else null);
        },
        .get_by_name => |by_name| {
            for (self.players.items) |plr| {
                if (std.mem.eql(u8, plr.getGameProfile().username(), by_name.name)) {
                    by_name.result.set(io, plr.acquire());
                    break;
                }
            } else {
                by_name.result.set(io, null);
            }
        },
        .broadcast => |bcast| {
            defer bcast.text.deinit(gpa);

            for (self.players.items) |plr| {
                plr.sendPackets(apair, net.packets.system_chat_s2c.named("system_chat", .{
                    .content = bcast.text,
                    .overlay = bcast.overlay,
                })) catch |e| logger.warn("[{s}] Couldn't broadcast chat message: {t}", .{ plr.getUsername(), e });
                _ = arena.reset(.{ .retain_with_limit = 512 * 1024 });
            }
        },
    } else |_| {}
}

owner: *core.Server,
player_count: std.atomic.Value(usize) = .init(0),
players: std.ArrayList(*Player) = .empty,
by_uuid: std.HashMapUnmanaged(UUID, *Player, UUID.HashCtx, std.hash_map.default_max_load_percentage) = .empty,

event_buffer: [32]Event = undefined,
event_queue: zio.Channel(Event),

end_event: zio.Event = .init,

pub fn init(self: *PlayerManager, owner: *core.Server, group: *Io.Group) Io.ConcurrentError!void {
    self.* = .{
        .owner = owner,
        .event_queue = .init(&self.event_buffer),
    };
    try group.concurrent(owner.runtime.io(), handler, .{self});
}

pub fn deinit(self: *PlayerManager) void {
    zio.beginShield();
    defer zio.endShield();

    self.event_queue.close(.graceful);
    self.end_event.wait() catch unreachable;
}

pub fn playerCount(self: *const PlayerManager) usize {
    return self.player_count.load(.monotonic);
}

pub fn add(self: *PlayerManager, plr: *Player) (Io.Cancelable || Io.QueueClosedError)!void {
    const plr2 = plr.acquire();
    errdefer plr2.release();

    return self.event_queue.send(.{ .player_join = plr2 });
}

pub fn remove(self: *PlayerManager, plr: *const Player) Io.Cancelable!void {
    return self.event_queue.send(.{ .player_remove = plr.getGameProfile().uuid }) catch |e| switch (e) {
        error.Canceled => |err| err,
        error.Closed => {},
    };
}

/// Acquires the new `Player`. Should call `release` on it once done with it.
pub fn getByUUID(self: *PlayerManager, uuid: UUID) Io.Cancelable!?*Player {
    var res: utils.Awaitable(?*Player) = .{ .value = null };
    self.event_queue.send(.{ .get_by_uuid = .{ .uuid = uuid, .result = &res } }) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => return null,
    };

    return res.waitUncancelable(self.owner.runtime.io());
}

/// Acquires the new `Player`. Should call `release` on it once done with it.
pub fn getByName(self: *PlayerManager, name: []const u8) Io.Cancelable!?*Player {
    var res: utils.Awaitable(?*Player) = .{ .value = null };
    self.event_queue.send(.{ .get_by_name = .{ .name = name, .result = &res } }) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => return null,
    };

    return res.waitUncancelable(self.owner.runtime.io());
}

/// `text` should be cloned via `.clone()` except for static text data.
///
/// Dynamic data in `text` will be deinitialized with `self.owner.allocator`.
pub fn broadcast(self: *PlayerManager, text: *const utils.TextComponent, overlay: bool) Io.Cancelable!void {
    return self.event_queue.send(.{ .broadcast = .{
        .text = text.*,
        .overlay = overlay,
    } }) catch |e| switch (e) {
        error.Canceled => error.Canceled,
        else => {},
    };
}

/// `text` should be cloned via `.clone()` except for static text data.
///
/// Dynamic data in `text` will be deinitialized with `self.owner.allocator`.
pub fn broadcastChat(self: *PlayerManager, plr: *Player, text: *const utils.TextComponent) (Io.Cancelable || Allocator.Error)!void {
    return self.event_queue.send(.{ .broadcast = .{
        .text = try utils.TextComponent.clone(.translate("chat.type.text", .{
            .args = &.{ .text(plr.getUsername(), .{}), text.* },
        }), self.owner.allocator),
        .overlay = false,
    } }) catch |e| switch (e) {
        error.Canceled => error.Canceled,
        else => {},
    };
}

test {
    std.testing.refAllDecls(PlayerManager);
}
