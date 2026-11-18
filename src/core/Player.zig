const Player = @This();
const std = @import("std");
const net = @import("net");
const utils = @import("utils");
const core = @import("core.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Server = core.Server;
const Connection = net.Connection;

const assert = std.debug.assert;

const logger = std.log.scoped(.@"core/Player");

const ConnectionImpl = struct {
    const OwnedConnection = Server.OwnedConnection;
    const ConfigPlayCommon = Server.ConfigPlayCommon;
    const LoginConnection = Server.LoginConnection;

    const vtable = Connection.VTable{
        .deinit = LoginConnection.deinitImpl,
        .disconnect = disconnectImpl,
        .tick = tickImpl,
    };

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const plr = fromConnectionPtr(conn);

        const owned = plr.getOwned();
        const owner = owned.owner;
        const playing = owned.data.play;

        var arena: std.heap.ArenaAllocator = undefined;
        const apair = net.PacketType.AllocPair.newFromGpa(owner.allocator, &arena);
        defer arena.deinit();

        try conn.sendPacket(apair, "disconnect", net.packets.disconnect_s2c, reason.*);

        var remove_index: ?usize = null;
        {
            owner.players_mutex.lockUncancelable();
            defer owner.players_mutex.unlock();
            _ = owner.player_count.fetchSub(1, .monotonic);

            for (owner.players.items, 0..) |player, i| {
                if (player == conn) {
                    if (remove_index != null) {
                        logger.err("Duplicate player entry: {f}", .{playing.profile});
                        _ = owner.players.swapRemove(i);
                    } else {
                        remove_index = i;
                    }
                    continue;
                }

                player.sendPacket(
                    apair,
                    "player_info_remove",
                    net.packets.player_info_remove_s2c,
                    (&playing.profile.uuid)[0..1],
                ) catch |e|
                    logger.warn("[{f}] Couldn't send player info: {t}", .{ player.alt(), e });
            }
        
            if (remove_index) |i| {
                _ = owner.players.swapRemove(i);
            } else {
                logger.warn("Missing player entry: {f}", .{playing.profile});
            }

            const message: utils.TextComponent = .translate("multiplayer.player.left", .{
                .args = &.{.text(owned.data.play.profile.username(), .{})},
                .common = .{ .color = .yellow },
            });
            owner.broadcastSystemChatLocked(apair, message);
        }
    }

    fn tickImpl(conn: *Connection, delta: u8) Connection.TickError!void {
        _ = delta;
        const plr = fromConnectionPtr(conn);
        try plr.connection.common.keepAlive(conn);
    }

    owned: *OwnedConnection,
    common: ConfigPlayCommon,
    // encryption: *Connection.Encryption, // Already handled by LoginConnection.deinitImpl
    // compression: *Connection.Compression, // Already handled by LoginConnection.deinitImpl
};

fn fromConnectionPtr(conn: *Connection) *Player {
    const owned: *ConnectionImpl.OwnedConnection = @fieldParentPtr("connection", conn);
    return owned.data.play;
}

connection: ConnectionImpl,
profile: utils.GameProfile,
entity_id: i32, // TODO: Entity management


pub const InitOptions = struct {
    owned: *Server.OwnedConnection,
    profile: utils.GameProfile,
    common: Server.ConfigPlayCommon,
};

pub fn init(self: *Player, options: InitOptions) void {
    const owner = options.owned.owner;
    self.* = .{
        .connection = .{
            .owned = options.owned,
            .common = options.common,
        },
        .profile = options.profile,
        .entity_id = owner.nextEntityId(),
    };
}

pub fn reconfigureForPlay(conn: *Connection) void {
    conn.reconfigure(.{
        .in_phase = .play,
        .out_phase = .play,
        .vtable = &ConnectionImpl.vtable,
    });
}

pub fn getOwned(self: *Player) *Server.OwnedConnection {
    return self.connection.owned;
}

pub fn getOwner(self: *const Player) *Server {
    return self.connection.owned.owner;
}

pub fn getGameProfile(self: *const Player) utils.GameProfile {
    return self.game_profile;
}

pub fn getLatency(self: *const Player) u64 {
    return self.connection.common.latency;
}