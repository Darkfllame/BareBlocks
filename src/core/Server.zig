const Server = @This();
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const net = @import("net");
const utils = @import("utils");
const packets = @import("packets");
const registries = @import("registries");
const crypto = @import("crypto");
const core = @import("core.zig");

const Io = std.Io;
const Connection = net.Connection;
const Allocator = std.mem.Allocator;

const logger = std.log.scoped(.@"core/server");

const current_version = net.packets.StatusResponse.Version.@"26.3";

const assert = std.debug.assert;

const broadcast_interval = 1500 * std.time.ns_per_ms;

const CoroAccpetError = Allocator.Error || error{
    SystemResources,
    SocketNotListening,
    NetworkDown,
    ProtocolFailure,
    SocketUnconnected,
    Timeout,
    Unexpected,
};

const BroadcastCoroError = Allocator.Error || error{SystemResources};

const LoginError = error{
    HelloMissing,
    DoubleHello,
    EncryptionContextCreation,
    KeyDecryption,
    Challenge,
    EncryptionSetupFailed,
    EncryptionAlreadySet,
    OutOfMemory,
};

const TickError = Io.UnexpectedError || Allocator.Error || error{
    SystemResources,
};

const PolledInfo = union(enum) {
    server,
    serverv6,
    broadcast,
    client: *Connection,

    pub fn format(self: PolledInfo, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .server => try writer.writeAll(".server"),
            .client => |conn| try writer.print("({f})", .{conn}),
        }
    }
};

fn coro_acceptConnection(self: *Server, which: enum { v4, v6 }) CoroAccpetError!void {
    self.start.wait() catch return;
    defer logger.info("Stopped listening for connections on ip{t} interface", .{which});

    const io = self.runtime.io();

    var sock: Io.net.Server = switch (which) {
        .v4 => .{
            .socket = .{
                .handle = self.sockv4_handle,
                .address = .{ .ip4 = self.ipv4 },
            },
            .options = self.accept_options,
        },
        .v6 => .{
            .socket = .{
                .handle = self.sockv6_handle,
                .address = .{ .ip6 = self.ipv6 },
            },
            .options = self.accept_options,
        },
    };

    logger.info("Listening for connections on ip{t} interface: {f}", .{ which, sock.socket.address });

    while (true) {
        var stream: ?Io.net.Stream = sock.accept(io) catch |err| switch (err) {
            error.Unexpected, error.WouldBlock => unreachable,
            error.Canceled => break,

            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.ConnectionAborted,
            error.BlockedByFirewall,
            error.ProtocolFailure,
            => |e| {
                logger.err("Couldn't accept connection: {t}", .{e});
                continue;
            },

            error.SystemResources,
            error.SocketNotListening,
            error.NetworkDown,
            => |e| return e,
        };
        errdefer if (stream) |s| s.close(io);

        logger.debug("Incomming connection to {f}", .{stream.?.socket.address});

        // {
        //     self.connections_mutex.lock() catch break;
        //     defer self.connections_mutex.unlock();

        //     try self.connections.ensureUnusedCapacity(self.allocator, 1);
        // }

        const owned = try self.allocator.create(OwnedConnection);
        owned.* = .{
            .owner = self,
            .connection = undefined,
            .data = .none,
        };
        const conn = &owned.connection;

        conn.init(self.allocator, &self.group, .{
            .packet_registry = self.packet_registry,
            .runtime = self.runtime,
            .stream = stream.?,
            .target_side = .client,
            .vtable = &OwnedConnection.vtable,
            .timeout = .fromSeconds(10),
        }) catch |err| {
            stream.?.close(io);
            self.allocator.destroy(owned);

            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| {
                    var buf: [128]u8 = undefined;
                    var stderr = std.debug.lockStderr(&buf);
                    defer std.debug.unlockStderr();

                    logger.err("Couldn't initialize connection to {f}: {t}", .{ stream.?.socket.address, e });
                    if (@errorReturnTrace()) |ert| {
                        std.debug.writeErrorReturnTrace(ert, stderr.terminal()) catch {};
                    }
                    stderr.file_writer.flush() catch {};
                    continue;
                },
            }
        };
        defer conn.release(.failing);
        stream = null;
        logger.debug("[{f}] Initalized", .{conn});

        // {
        //     self.connections_mutex.lockUncancelable();
        //     defer self.connections_mutex.unlock();

        //     const gop = self.connections.getOrPutAssumeCapacity(conn);
        //     if (gop.found_existing) {
        //         logger.debug("Threw {f}: duplicate connection", .{conn.ip_address});
        //         conn.release(self.allocator);
        //     }
        // }

        conn.start.set();

        logger.debug("[{f}] Accept finish", .{conn});
    }
}

fn coro_broadcast(self: *Server) BroadcastCoroError!void {
    self.start.wait() catch return;

    const broadcast_addr = comptime (Io.net.IpAddress.parseLiteral("224.0.2.60:4445") catch unreachable);
    const io = self.runtime.io();

    var data_buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(&data_buf);
    w.print("[MOTD]{s}[/MOTD][AD]{d}[/AD]", .{
        "I like §ldih",
        self.ipv4.port,
    }) catch unreachable;
    const data = w.buffered();

    while (true) {
        logger.debug("BROADCAST!", .{});
        self.broadcast.socket.send(io, &broadcast_addr, data) catch |err| {
            if (err == error.Canceled) break;
            logger.err("Broadcast error: {t}", .{err});
        };

        io.sleep(.fromMilliseconds(1500), .boot) catch break;
    }
}

fn enableBroadcast(self: *Server) !void {
    const io = self.runtime.io();

    self.broadcast.socket = try net.datagram.socket(&Io.net.IpAddress{ .ip4 = .unspecified(0) }, false, true);
    errdefer net.datagram.close(self.broadcast.socket);

    self.broadcast.coro = try io.concurrent(coro_broadcast, .{self});
    errdefer self.broadcast.coro.cancel(io) catch {};

    self.broadcast.enabled = true;
}

fn deinitBroadcast(self: *Server) void {
    if (!self.broadcast.enabled) return;
    const io = self.runtime.io();

    net.datagram.close(self.broadcast.socket);
    self.broadcast.coro.cancel(io) catch |e| {
        logger.err("Closed broadcast coroutine with error: {t}", .{e});
    };
}

packet_registry: *const net.PacketRegistry,
allocator: Allocator,
runtime: *zio.Runtime,
start: zio.Event,

accept_options: Io.net.Server.AcceptOptions,
v6_enabled: bool,
sockv4_handle: Io.net.Socket.Handle,
sockv6_handle: Io.net.Socket.Handle,
ipv4: Io.net.Ip4Address,
ipv6: Io.net.Ip6Address,
broadcast: struct {
    enabled: bool,
    socket: Io.net.Socket,
    coro: Io.Future(BroadcastCoroError!void),
},

connections_mutex: zio.Mutex,
connections: std.HashMapUnmanaged(*Connection, void, Connection.HashContext, std.hash_map.default_max_load_percentage),
/// Connections in the play phase.
players_mutex: zio.Mutex,
players: std.ArrayList(*Connection),
next_entity_id: std.atomic.Value(i32),
accept_coro: Io.Future(CoroAccpetError!void),
acceptv6_coro: Io.Future(CoroAccpetError!void),

group: Io.Group,

server_id: [20]u8,
rsa_key: *crypto.EVP_PKEY,
public_key_bytes: []u8,

compression_threshold: u31,

pub const server_id_header = "gecko_";

pub const InitError = error{
    EncryptionSetupFailed,
} || Io.ConcurrentError || Io.net.IpAddress.ListenError || Allocator.Error;

pub const InitOptions = struct {
    // packet_registry: *const net.PacketRegistry,
    allocator: Allocator,
    runtime: *zio.Runtime,
    bind_port: u16 = 25565,
    bind_port_v6: ?u16 = null,
    max_connections: u31 = Io.net.default_kernel_backlog,
    compression_threshold: u31 = 256,
    broadcast: bool = false,
};

pub const AddressAlt = struct {
    v4: Io.net.Ip4Address,
    v6: ?Io.net.Ip6Address,

    pub fn format(self: *const AddressAlt, writer: *Io.Writer) Io.Writer.Error!void {
        try self.v4.format(writer);
        if (self.v6) |v6| {
            try writer.print("({f})", .{v6});
        }
    }
};

pub const OwnedConnection = struct {
    const vtable = Connection.VTable{
        .deinit = deinitImpl,
    };

    owner: *Server,
    connection: Connection,
    data: union(enum) {
        none,
        login: *LoginConnection,
        config: *ConfigConnection,
        play: *PlayConnection,
    },

    fn deinitImpl(conn: *Connection, allocator: Allocator) void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

        switch (owned.data) {
            .none => {},
            .login => |loginging| allocator.destroy(loginging),
            .config => |configing| allocator.destroy(configing),
            .play => |playing| allocator.destroy(playing),
        }
        allocator.destroy(owned);
    }
};

pub const LoginConnection = struct {
    const vtable = Connection.VTable{
        .deinit = deinitImpl,
        .disconnect = disconnectImpl,
    };

    fn deinitImpl(conn: *Connection, allocator: Allocator) void {
        allocator.free(conn.name.?);
        if (conn.encryption) |enc| {
            enc.deinit();
            allocator.destroy(enc);
        }
        if (conn.compression) |comp| {
            comp.deinit(allocator);
            allocator.destroy(comp);
        }
        OwnedConnection.deinitImpl(conn, allocator);
    }

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

        const gpa = owned.owner.allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try conn.sendPacket(.newWithArena(gpa, &arena), "login_disconnect", net.packets.login_disconnect_s2c, reason.*);
    }

    fn setupEncryption(self: *LoginConnection, owner: *Server, in_shared_secret: []const u8, verify_token: []const u8) LoginError!void {
        self.encryption = try owner.allocator.create(Connection.Encryption);
        errdefer {
            owner.allocator.destroy(self.encryption.?);
            self.encryption = null;
        }
        const shared_secret = &self.encryption.?.shared_secret;
        var shared_buffer: [128]u8 = undefined;

        const ctx = crypto.EVP_PKEY_CTX_new(owner.rsa_key, null) orelse return error.EncryptionContextCreation;
        defer crypto.EVP_PKEY_CTX_free(ctx);

        // logger.debug("created ctx", .{});

        if (crypto.EVP_PKEY_decrypt_init(ctx) <= 0) return error.EncryptionContextCreation;
        // logger.debug("context reset", .{});
        if (crypto.EVP_PKEY_CTX_set_rsa_padding(ctx, crypto.RSA_PKCS1_PADDING) <= 0) return error.EncryptionContextCreation;
        // logger.debug("padding set", .{});

        var len: usize = shared_buffer.len;
        var res = crypto.EVP_PKEY_decrypt(
            ctx,
            &shared_buffer,
            &len,
            in_shared_secret.ptr,
            in_shared_secret.len,
        );
        // logger.debug("key size: {d}", .{len});
        if (res <= 0 or len != shared_secret.len) return error.KeyDecryption;
        @memcpy(shared_secret, shared_buffer[0..16]);
        // logger.debug("key decrypted", .{});

        if (crypto.EVP_PKEY_decrypt_init(ctx) <= 0) return error.EncryptionContextCreation;
        // logger.debug("context reset", .{});
        if (crypto.EVP_PKEY_CTX_set_rsa_padding(ctx, crypto.RSA_PKCS1_PADDING) <= 0) return error.EncryptionContextCreation;
        // logger.debug("padding set", .{});

        len = shared_buffer.len;
        res = crypto.EVP_PKEY_decrypt(
            ctx,
            &shared_buffer,
            &len,
            verify_token.ptr,
            verify_token.len,
        );
        if (res <= 0 or len != self.verify_token.len) return error.KeyDecryption;
        // logger.debug("challenge decrypted", .{});

        if (!std.mem.eql(u8, shared_buffer[0..self.verify_token.len], &self.verify_token)) return error.Challenge;

        self.encryption.?.init(.fixed_secret) catch return error.EncryptionSetupFailed;
    }

    owned: *OwnedConnection,
    profile: utils.GameProfile,
    verify_token: [4]u8,
    encryption: ?*Connection.Encryption = null,
    compression: ?*Connection.Compression = null,

    @"error": ?LoginError = null,
};

pub const ConfigPlayCommon = struct {
    const keepalive_timeout_ms = 15_000;

    fn getKeepAliveValue() u64 {
        return @bitCast(Io.Timestamp.now(std.Options.debug_io, .boot).toMilliseconds());
    }
    fn getPingValue() u32 {
        return @truncate(getKeepAliveValue());
    }

    /// Value of the keep alive waiting for an answer.
    keep_alive: ?u64,
    /// When the last keep alive was sent.
    keep_alive_time: u64 = 0,
    ping: ?u32,
    latency: u64,

    /// Same as vanilla: every 15s, send a keep alive, or disconnect if the last one wasn't answered.
    fn keepAlive(self: *ConfigPlayCommon, conn: *Connection) net.Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

        const now = getKeepAliveValue();
        if (now - self.keep_alive_time < keepalive_timeout_ms) return;

        if (self.keep_alive != null) {
            conn.disconnect(.{ .static = &.timeout });
            return;
        }
        self.keep_alive = now;
        self.keep_alive_time = now;

        var arena: std.heap.ArenaAllocator = .init(owned.owner.allocator);
        defer arena.deinit();
        try conn.sendPacket(.newWithArena(owned.owner.allocator, &arena), "keep_alive", net.packets.keep_alive, @bitCast(now));
    }

    fn handleCommonPing(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
        const ping = net.packets.ping_pong;
        const pack = try ping.readRoot(params, reader);
        logger.debug("[{f}] Ping: {f}", .{ conn, ping.formatted(pack, params.toAllocPair()) });

        try conn.sendPacket(params.toAllocPair(), "pong", ping, pack);
    }

    fn handleCommonKeepAlive(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
        const keep_alive = net.packets.keep_alive;
        const pack = try keep_alive.readRoot(params, reader);
        logger.debug("[{f}] Keep Alive: {f}", .{ conn, keep_alive.formatted(pack, params.toAllocPair()) });

        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        const common = switch (owned.data) {
            .none, .login => unreachable,
            .config => |c| &c.common,
            .play => |p| &p.common,
        };

        if (common.keep_alive) |ka| {
            if (@as(u64, @bitCast(pack)) != ka) {
                conn.disconnect(.{ .static = &.timeout });
                return error.CallbackHandlerFailed;
            }
            const diff = getKeepAliveValue() - ka;
            common.latency = (common.latency * 3 + diff) / 4;
            common.keep_alive = null;
        }
    }
};

pub const ConfigConnection = struct {
    const vtable = Connection.VTable{
        .deinit = LoginConnection.deinitImpl,
        .disconnect = disconnectImpl,
        .tick = tickImpl,
    };

    fn tickImpl(conn: *Connection, delta: u8) Connection.TickError!void {
        _ = delta;
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        try owned.data.config.common.keepAlive(conn);
    }

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        assert(owned.data == .config);

        const gpa = owned.owner.allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try conn.sendPacket(.newWithArena(gpa, &arena), "disconnect", net.packets.disconnect_s2c, reason.*);
    }

    owned: *OwnedConnection,
    common: ConfigPlayCommon,
    profile: utils.GameProfile,
    encryption: *Connection.Encryption,
    compression: *Connection.Compression,
};

pub const PlayConnection = struct {
    const vtable = Connection.VTable{
        .deinit = deinitImpl,
        .disconnect = disconnectImpl,
        .tick = tickImpl,
    };

    fn deinitImpl(conn: *Connection, allocator: Allocator) void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        const owner = owned.owner;
        {
            owner.players_mutex.lockUncancelable();
            defer owner.players_mutex.unlock();

            for (owner.players.items, 0..) |player, i| {
                if (player == conn) {
                    _ = owner.players.swapRemove(i);
                    break;
                }
            }
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();

            var uuids = [_]utils.UUID{owned.data.play.profile.uuid};
            for (owner.players.items) |player| {
                player.sendPacket(.newWithArena(allocator, &arena), "player_info_remove", net.packets.player_info_remove_s2c, &uuids) catch |e|
                    logger.warn("[{f}] Couldn't send player info: {t}", .{ player, e });
            }
            const message: utils.TextComponent = .translate("multiplayer.player.left", .{
                .args = &.{.text(owned.data.play.profile.username(), .{})},
                .common = .{ .color = .yellow },
            });
            owner.broadcastSystemChatLocked(.newWithArena(allocator, &arena), message);
        }
        LoginConnection.deinitImpl(conn, allocator);
    }

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        assert(owned.data == .play);

        const gpa = owned.owner.allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try conn.sendPacket(.newWithArena(gpa, &arena), "disconnect", net.packets.disconnect_s2c, reason.*);
    }

    fn tickImpl(conn: *Connection, delta: u8) Connection.TickError!void {
        _ = delta;
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        try owned.data.play.common.keepAlive(conn);
    }

    owned: *OwnedConnection,
    common: ConfigPlayCommon,
    profile: utils.GameProfile,
    entity_id: i32,
    encryption: *Connection.Encryption,
    compression: *Connection.Compression,
};

pub fn init(self: *Server, options: InitOptions) InitError!void {
    const addr = Io.net.IpAddress{ .ip4 = .unspecified(options.bind_port) };
    const listen_opt = Io.net.IpAddress.ListenOptions{
        .kernel_backlog = options.max_connections,
        .reuse_address = true,
    };

    const io = options.runtime.io();

    var sock = try addr.listen(io, listen_opt);
    errdefer sock.deinit(io);

    var sockv6 = if (options.bind_port_v6) |port|
        try Io.net.IpAddress.listen(&.{ .ip6 = .unspecified(port) }, io, listen_opt)
    else
        null;
    errdefer if (sockv6) |*s| s.deinit(io);

    const key_ctx = crypto.EVP_PKEY_CTX_new_id(crypto.EVP_PKEY_RSA, null) orelse return error.EncryptionSetupFailed;
    defer crypto.EVP_PKEY_CTX_free(key_ctx);

    if (crypto.EVP_PKEY_keygen_init(key_ctx) <= 0) return error.EncryptionSetupFailed;
    if (crypto.EVP_PKEY_CTX_set_rsa_keygen_bits(key_ctx, 1024) <= 0) return error.EncryptionSetupFailed;

    var key: ?*crypto.EVP_PKEY = null;
    if (crypto.EVP_PKEY_keygen(key_ctx, @ptrCast(&key)) <= 0) return error.EncryptionSetupFailed;
    errdefer crypto.EVP_PKEY_free(key);
    assert(key != null);

    const der = blk: {
        var der: [*c]u8 = null;

        const len = crypto.i2d_PUBKEY(key, &der);
        if (len <= 0) return error.EncryptionSetupFailed;
        defer crypto.CRYPTO_free(der, @src().file, @src().line);

        break :blk try options.allocator.dupe(u8, der[0..@intCast(len)]);
    };
    errdefer options.allocator.free(der);

    self.* = .{
        .packet_registry = comptime &packets.registry(net.PacketRegistry, Server),
        .allocator = options.allocator,
        .runtime = options.runtime,
        .start = .init,

        .accept_options = sock.options,
        .v6_enabled = sockv6 != null,
        .sockv4_handle = sock.socket.handle,
        .sockv6_handle = if (sockv6) |s| s.socket.handle else undefined,
        .ipv4 = sock.socket.address.ip4,
        .ipv6 = if (sockv6) |s| s.socket.address.ip6 else undefined,
        .broadcast = .{
            .enabled = false,
            .socket = undefined,
            .coro = .{ .any_future = null, .result = {} },
        },

        .connections_mutex = .init,
        .connections = .empty,
        .players_mutex = .init,
        .players = .empty,
        .next_entity_id = .init(1),
        .accept_coro = .{ .any_future = null, .result = {} },
        .acceptv6_coro = .{ .any_future = null, .result = {} },

        .group = .init,

        .server_id = undefined,
        .rsa_key = key.?,
        .public_key_bytes = der,

        .compression_threshold = options.compression_threshold,
    };

    { // server id generation
        var id_writer = Io.Writer.fixed(&self.server_id);
        id_writer.writeAll(server_id_header) catch {};
        var hex_buffer: [@divFloor(self.server_id.len - server_id_header.len + 1, 2)]u8 = undefined;
        io.random(&hex_buffer);
        for (hex_buffer) |b| {
            id_writer.writeAll(&std.fmt.hex(b)) catch {};
        }
    }

    if (options.broadcast) {
        self.enableBroadcast() catch |e| {
            self.broadcast.enabled = false;
            logger.err("Couldn't enable broadcast to LAN: {t}", .{e});
        };
    }
    errdefer {
        self.deinitBroadcast();
        self.accept_coro.cancel(io) catch {};
        self.acceptv6_coro.cancel(io) catch {};
    }

    self.accept_coro = try io.concurrent(coro_acceptConnection, .{ self, .v4 });
    if (self.v6_enabled) {
        self.acceptv6_coro = try io.concurrent(coro_acceptConnection, .{ self, .v6 });
    }
}

pub fn deinit(self: *Server) void {
    const io = self.runtime.io();

    self.deinitBroadcast();

    self.group.cancel(io);

    self.accept_coro.cancel(io) catch |e| {
        logger.err("Caught error while closing server: {t}", .{e});
    };
    self.acceptv6_coro.cancel(io) catch |e| {
        logger.err("Caught error while closing server: {t}", .{e});
    };

    Io.net.Socket.close(&.{
        .handle = self.sockv4_handle,
        .address = .{ .ip4 = self.ipv4 },
    }, io);
    if (self.v6_enabled) {
        Io.net.Socket.close(&.{
            .handle = self.sockv6_handle,
            .address = .{ .ip6 = self.ipv6 },
        }, io);
    }

    self.connections_mutex.lockUncancelable();
    var conn_it = self.connections.keyIterator();
    while (conn_it.next()) |conn_ptr| {
        const conn = conn_ptr.*;

        conn.release(self.allocator);
    }
    self.connections.deinit(self.allocator);
    self.players.deinit(self.allocator);

    crypto.EVP_PKEY_free(self.rsa_key);
    self.allocator.free(self.public_key_bytes);
}

pub fn addressAlt(self: *const Server) AddressAlt {
    return .{
        .v4 = self.ipv4,
        .v6 = if (self.v6_enabled) self.ipv6 else null,
    };
}

pub fn @"serverbound/handshake/intention"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const hs = net.packets.handshake_c2s;
    const pack = try hs.readRoot(params, reader);
    logger.debug("[{f}] Hanshake: {f}", .{ conn, hs.formatted(pack, params.toAllocPair()) });
    switch (pack.intent) {
        .invalid => return error.InvalidEnumTag,
        .status => {
            try conn.lock();
            defer conn.unlock();

            conn.reconfigure(.{
                .in_phase = .status,
                .out_phase = .status,
            });
        },
        .login => {
            conn.reconfigure(.{ .out_phase = .login });
            if (pack.protocol_version != current_version.protocol) {
                conn.disconnect(.{ .static = &.translate("multiplayer.status.incompatible", .{}) });
                return error.CallbackHandlerFailed;
            }
            conn.reconfigure(.{
                .in_phase = .login,
                .timeout = .fromSeconds(20),
                .vtable = &LoginConnection.vtable,
            });
        },
        .transfer => {
            try conn.lock();
            defer conn.unlock();

            conn.reconfigure(.{ .out_phase = .login });
            conn.disconnect(.{ .static = &.transfers_disabled });
            return error.CallbackHandlerFailed;
        },
    }
}

pub fn @"serverbound/status/status_request"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const status = net.packets.status_request_c2s;
    const pack = try status.readRoot(params, reader);
    logger.debug("[{f}] Status: {f}", .{ conn, status.formatted(pack, params.toAllocPair()) });
    try conn.lock();
    defer conn.unlock();

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

    const count = @atomicLoad(u32, &owned.owner.connections.size, .monotonic);

    try conn.sendPacket(
        params.toAllocPair(),
        "status_response",
        net.packets.status_response_s2c,
        net.packets.StatusResponse{
            .version = current_version,
            .description = .text("Minecraft on crack", .{}),
            .players = .{
                .online = @intCast(count),
                .max = 20,
            },
        },
    );
}

pub fn @"serverbound/status/ping_request"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const ping = net.packets.ping_pong;
    const pack = try ping.readRoot(params, reader);
    logger.debug("[{f}] Ping: {f}", .{ conn, ping.formatted(pack, params.toAllocPair()) });

    try conn.sendPacket(
        params.toAllocPair(),
        "pong_response",
        ping,
        pack,
    );
}

pub fn @"serverbound/login/hello"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const hello = net.packets.login_start_c2s;
    const pack = try hello.readRoot(params, reader);
    logger.debug("[{f}] Login Start: {f}", .{ conn, hello.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    if (owned.data != .none) {
        const logingin = owned.data.login;
        conn.disconnect(.{ .static = &.translate("disconnect.packetError", .{ .common = .{
            .children = &.{
                .text(": ", .{}),
                .text("Double hello", .{}),
            },
        } }) });
        logingin.@"error" = error.DoubleHello;
        return error.CallbackHandlerFailed;
    }
    const owner = owned.owner;
    const io = owner.runtime.io();

    const offline_text = "Offline: ";

    const name_copy = try owner.allocator.alloc(u8, offline_text.len + pack.name.len);
    errdefer owner.allocator.free(name_copy);
    @memcpy(name_copy[0..offline_text.len], offline_text);
    @memcpy(name_copy[offline_text.len..], pack.name);

    const gp = try utils.GameProfile.validate(name_copy[offline_text.len..], utils.UUID.makeVersion3(name_copy));

    const loginging = try owner.allocator.create(LoginConnection);
    errdefer owner.allocator.destroy(loginging);

    loginging.* = .{
        .owned = owned,
        .profile = gp,
        .verify_token = undefined,
    };
    conn.reconfigure(.{
        .name = name_copy,
        .vtable = &LoginConnection.vtable,
    });
    io.random(&loginging.verify_token);

    try conn.sendPacket(
        params.toAllocPair(),
        "hello",
        net.packets.encryption_request_s2c,
        .{
            .server_id = &owner.server_id,
            .public_key = owner.public_key_bytes,
            .verify_token = &loginging.verify_token,
            .should_authenticate = false,
        },
    );

    owned.data = .{ .login = loginging };
}

pub fn @"serverbound/login/key"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const encryption_setup_failed_tc = &utils.TextComponent.text("Internal Error: couldn't setup encryption", .{ .color = .red });

    const key = net.packets.key;
    const set_compression = net.packets.set_compression_s2c;
    const login_success = net.packets.login_success_s2c;

    const pack = try key.readRoot(params, reader);
    logger.debug("[{f}] Login Key: {f}", .{ conn, key.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const io = owner.runtime.io();
    const logingin = switch (owned.data) {
        .config, .play => unreachable,
        .none => {
            conn.disconnect(.{ .static = &.text("Client didn't initialize login", .{ .color = .red }) });
            return;
        },
        .login => |l| l,
    };
    if (logingin.encryption != null) {
        conn.disconnect(.{ .static = encryption_setup_failed_tc });
        logingin.@"error" = error.EncryptionAlreadySet;
        return error.CallbackHandlerFailed;
    }

    logingin.setupEncryption(owner, pack.shared_secret, pack.verify_token) catch |e| {
        logingin.encryption = null;
        conn.disconnect(.{ .static = encryption_setup_failed_tc });
        logingin.@"error" = e;
        return error.CallbackHandlerFailed;
    };

    logingin.compression = try owner.allocator.create(Connection.Compression);
    errdefer {
        owner.allocator.destroy(logingin.compression.?);
        logingin.compression = null;
    }
    try logingin.compression.?.init(owner.allocator, owner.compression_threshold, 16);
    errdefer logingin.compression.?.deinit(owner.allocator);

    conn.reconfigure(.{ .encryption = logingin.encryption.? });

    try conn.sendPacket(
        params.toAllocPair(),
        "login_compression",
        set_compression,
        @intCast(owner.compression_threshold),
    );

    conn.reconfigure(.{ .compression = logingin.compression.? });

    try conn.sendPacket(params.toAllocPair(), "login_finished", login_success, .{
        .profile = logingin.profile,
        .session_id = utils.UUID.makeVersion4(io),
    });

    conn.reconfigure(.{ .out_phase = .configuration });
}

pub fn @"serverbound/login/login_acknowledged"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const ack = net.packets.login_acknowledged_c2s;
    const pack = try ack.readRoot(params, reader);
    logger.debug("[{f}] Login Ack: {f}", .{ conn, ack.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const loginging = owned.data.login;

    if (loginging.encryption == null) {
        conn.disconnect(.{ .static = &.translate("disconnect.packetError", .{ .common = .{
            .children = &.{
                .text(": ", .{}),
                .text("Hello packet wasn't sent", .{}),
            },
        } }) });
        loginging.@"error" = error.HelloMissing;
        return error.CallbackHandlerFailed;
    }

    {
        const configing = try owner.allocator.create(ConfigConnection);
        errdefer comptime unreachable;

        configing.* = .{
            .owned = owned,
            .common = .{
                .keep_alive = null,
                // Same as vanilla, the first one is sent after 15s
                .keep_alive_time = ConfigPlayCommon.getKeepAliveValue(),
                .ping = null,
                .latency = 0,
            },
            .profile = loginging.profile,
            .encryption = loginging.encryption.?,
            .compression = loginging.compression.?,
        };
        owned.data = .{ .config = configing };
        owner.allocator.destroy(loginging);
        conn.reconfigure(.{
            .in_phase = .configuration,
            .out_phase = .configuration,
            .vtable = &ConfigConnection.vtable,
        });
    }

    try startConfiguration(conn, params.toAllocPair());
}

//=====================configuration===================//

/// Same order as vanilla's `ServerConfigurationPacketListenerImpl.startConfiguration`, without
/// the optional brand and server links.
fn startConfiguration(conn: *Connection, apair: net.PacketType.AllocPair) net.Connection.WritePacketError!void {
    var features = [_]utils.Identifier{.vanilla("vanilla")};
    try conn.sendPacket(apair, "update_enabled_features", net.packets.feature_flags_s2c, &features);

    const pack = registries.known_pack;
    var known_packs = [_]@typeInfo(net.packets.known_packs.getZigType()).pointer.child{
        .{ .namespace = pack.namespace, .id = pack.id, .version = pack.version },
    };
    try conn.sendPacket(apair, "select_known_packs", net.packets.known_packs, &known_packs);
}

pub fn @"serverbound/configuration/select_known_packs"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const known_packs = net.packets.known_packs;
    const pack = try known_packs.readRoot(params, reader);
    logger.debug("[{f}] Known Packs: {f}", .{ conn, known_packs.formatted(pack, params.toAllocPair()) });

    // Registry entries are only sent by name, the client must have vanilla's data for them
    const vanilla = registries.known_pack;
    const has_vanilla = for (pack) |p| {
        if (std.mem.eql(u8, p.namespace, vanilla.namespace) and
            std.mem.eql(u8, p.id, vanilla.id) and
            std.mem.eql(u8, p.version, vanilla.version)) break true;
    } else false;
    if (!has_vanilla) {
        conn.disconnect(.{ .static = &comptime .text(std.fmt.comptimePrint(
            "This server needs the vanilla data pack ({s}:{s} {s}) on the client",
            .{ vanilla.namespace, vanilla.id, vanilla.version },
        ), .{}) });
        return error.CallbackHandlerFailed;
    }

    const registry_data = net.packets.registry_data_s2c;
    const Entry = @typeInfo(@FieldType(registry_data.getZigType(), "entries")).pointer.child;
    const apair = params.toAllocPair();
    for (registries.synchronized) |registry| {
        const entries = try apair.arena.alloc(Entry, registry.entries.len);
        for (entries, registry.entries) |*entry, id| {
            entry.* = .{ .entry_id = utils.Identifier.validate(id) catch unreachable, .data = null };
        }
        try conn.sendPacket(apair, "registry_data", registry_data, .{
            .registry_id = utils.Identifier.validate(registry.id) catch unreachable,
            .entries = entries,
        });
    }

    // Same as vanilla's SynchronizeRegistriesTask, tags right after the registries
    const update_tags = net.packets.update_tags_s2c;
    const RegistryTags = @typeInfo(update_tags.getZigType()).pointer.child;
    const Tag = @typeInfo(@FieldType(RegistryTags, "tags")).pointer.child;
    const registry_tags = try apair.arena.alloc(RegistryTags, registries.tags.len);
    for (registry_tags, registries.tags) |*out, registry| {
        const tags = try apair.arena.alloc(Tag, registry.tags.len);
        for (tags, registry.tags) |*tag, src| {
            const entries = try apair.arena.alloc(i32, src.entries.len);
            for (entries, src.entries) |*e, id| e.* = @intCast(id);
            tag.* = .{ .name = utils.Identifier.validate(src.name) catch unreachable, .entries = entries };
        }
        out.* = .{ .registry = utils.Identifier.validate(registry.registry) catch unreachable, .tags = tags };
    }
    try conn.sendPacket(apair, "update_tags", update_tags, registry_tags);

    try conn.sendPacket(apair, "finish_configuration", net.packets.finish_configuration_s2c, .{});
}

pub fn @"serverbound/configuration/client_information"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const info = net.packets.client_information_c2s;
    const pack = try info.readRoot(params, reader);
    logger.debug("[{f}] Client Information: {f}", .{ conn, info.formatted(pack, params.toAllocPair()) });
}

pub fn @"serverbound/configuration/custom_payload"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const message = net.packets.plugin_message;
    const pack = try message.readRoot(params, reader);
    logger.debug("[{f}] Plugin Message: {f} ({d} bytes)", .{ conn, pack.channel, pack.data.len });
}

pub const @"serverbound/configuration/keep_alive" = ConfigPlayCommon.handleCommonKeepAlive;

pub fn @"serverbound/configuration/finish_configuration"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const ack = net.packets.ack_finish_configuration_c2s;
    const pack = try ack.readRoot(params, reader);
    logger.debug("[{f}] Finish Configuration Ack: {f}", .{ conn, ack.formatted(pack, params.toAllocPair()) });
    logger.info("[{f}] Configuration done", .{conn});

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const configing = owned.data.config;
    {
        const playing = try owner.allocator.create(PlayConnection);
        errdefer comptime unreachable;

        playing.* = .{
            .owned = owned,
            .common = configing.common,
            .profile = configing.profile,
            .entity_id = owner.next_entity_id.fetchAdd(1, .monotonic),
            .encryption = configing.encryption,
            .compression = configing.compression,
        };
        owned.data = .{ .play = playing };
        owner.allocator.destroy(configing);
        // Same as vanilla's `handleConfigurationFinished`, the client is in play from now on
        conn.reconfigure(.{
            .in_phase = .play,
            .out_phase = .play,
            .vtable = &PlayConnection.vtable,
        });
    }

    try joinWorld(conn, params.toAllocPair());
}

//=====================play===========================//

/// An empty world, no chunks are ever sent.
const limbo = struct {
    const dimension = "minecraft:overworld";
    const dimension_type = syncedEntryIndex("minecraft:dimension_type", "minecraft:overworld");
    /// Spectators don't wait for the chunk they're in to leave the loading screen, see
    /// the client's `LevelLoadTracker`.
    const game_mode: net.packets.GameMode = .spectator;
    const x = 0.5;
    const y = 100.0;
    const z = 0.5;
    // LEVEL_CHUNKS_LOAD_START in vanilla's `ClientboundGameEventPacket`
    const level_chunks_load_start = 13;
};

/// Numeric id of a synchronized registry entry, the order they're sent in.
fn syncedEntryIndex(comptime registry: []const u8, comptime entry: []const u8) i32 {
    comptime for (registries.synchronized) |r| {
        if (!std.mem.eql(u8, r.id, registry)) continue;
        for (r.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e, entry)) return i;
        }
    };
    @compileError("No " ++ entry ++ " in " ++ registry);
}

fn joinWorld(conn: *Connection, apair: net.PacketType.AllocPair) net.Connection.ReadCallbackError!void {
    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const playing = owned.data.play;

    var dimensions = [_]utils.Identifier{.literal(limbo.dimension)};
    try conn.sendPacket(apair, "login", net.packets.login_s2c, .{
        .entity_id = playing.entity_id,
        .hardcore = false,
        .dimensions = &dimensions,
        .max_players = 20,
        .view_distance = 2,
        .simulation_distance = 2,
        .reduced_debug_info = false,
        .show_death_screen = true,
        .limited_crafting = false,
        .dimension_type = limbo.dimension_type,
        .dimension = .literal(limbo.dimension),
        .hashed_seed = 0,
        .game_mode = limbo.game_mode,
        .previous_game_mode = 0,
        .debug = false,
        .flat = true,
        .death_location = null,
        .portal_cooldown = 0,
        .sea_level = 63,
        .online_mode = false,
        .enforces_secure_chat = false,
    });
    try conn.sendPacket(apair, "player_position", net.packets.player_position_s2c, .{
        .teleport_id = 1,
        .x = limbo.x,
        .y = limbo.y,
        .z = limbo.z,
        .velocity_x = 0,
        .velocity_y = 0,
        .velocity_z = 0,
        .yaw = 0,
        .pitch = 0,
        .flags = .empty,
    });
    try conn.sendPacket(apair, "game_event", net.packets.game_event_s2c, .{
        .event = limbo.level_chunks_load_start,
        .value = 0,
    });

    owner.players_mutex.lockUncancelable();
    defer owner.players_mutex.unlock();
    try owner.players.append(owner.allocator, conn);

    // Same as vanilla's `PlayerList.placeNewPlayer`: everyone gets the new player, the new player
    // gets everyone. The client also needs its own entry, it's where it gets its game mode from.
    const player_info = net.packets.player_info_initialize_s2c;
    const PlayerEntry = @typeInfo(@FieldType(player_info.getZigType(), "players")).pointer.child;
    const all_actions: std.EnumSet(net.packets.PlayerInfoAction) = .full;

    var new_entry = [_]PlayerEntry{playerInfoEntry(playing)};
    for (owner.players.items) |player| {
        player.sendPacket(apair, "player_info_update", player_info, .{ .actions = all_actions, .players = &new_entry }) catch |e|
            logger.warn("[{f}] Couldn't send player info: {t}", .{ player, e });
    }
    const others = try apair.arena.alloc(PlayerEntry, owner.players.items.len - 1);
    var i: usize = 0;
    for (owner.players.items) |player| {
        if (player == conn) continue;
        const other: *OwnedConnection = @fieldParentPtr("connection", player);
        others[i] = playerInfoEntry(other.data.play);
        i += 1;
    }
    if (others.len != 0) {
        try conn.sendPacket(apair, "player_info_update", player_info, .{ .actions = all_actions, .players = others });
    }

    logger.info("{s} joined the game", .{playing.profile.username()});
    const message: utils.TextComponent = .translate("multiplayer.player.joined", .{
        .args = &.{.text(playing.profile.username(), .{})},
        .common = .{ .color = .yellow },
    });
    owner.broadcastSystemChatLocked(apair, message);
}

fn playerInfoEntry(playing: *const PlayConnection) @typeInfo(@FieldType(net.packets.player_info_initialize_s2c.getZigType(), "players")).pointer.child {
    return .{
        .uuid = playing.profile.uuid,
        .name = playing.profile.username(),
        .properties = &.{},
        .chat_session = null,
        .game_mode = limbo.game_mode,
        .listed = true,
        .latency = @intCast(@min(playing.common.latency, std.math.maxInt(i32))),
        .display_name = null,
        .list_order = 0,
        .show_hat = true,
    };
}

/// `players_mutex` must be locked.
fn broadcastSystemChatLocked(self: *Server, apair: net.PacketType.AllocPair, message: utils.TextComponent) void {
    for (self.players.items) |player| {
        player.sendPacket(apair, "system_chat", net.packets.system_chat_s2c, .{
            .content = message,
            .overlay = false,
        }) catch |e| logger.warn("[{f}] Couldn't send chat message: {t}", .{ player, e });
    }
}

pub const @"serverbound/play/keep_alive" = ConfigPlayCommon.handleCommonKeepAlive;

pub fn @"serverbound/play/accept_teleportation"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const accept = net.packets.accept_teleportation_c2s;
    const pack = try accept.readRoot(params, reader);
    logger.debug("[{f}] Accept Teleportation: {f}", .{ conn, accept.formatted(pack, params.toAllocPair()) });
}

pub fn @"serverbound/play/player_loaded"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    _ = try net.packets.player_loaded_c2s.readRoot(params, reader);
    logger.debug("[{f}] Player loaded", .{conn});
}

pub fn @"serverbound/play/chat"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const chat = net.packets.chat_c2s;
    const pack = try chat.readRoot(params, reader);

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const name = owned.data.play.profile.username();
    logger.info("<{s}> {s}", .{ name, pack.message });

    // Unsigned, so sent as a system message (the server doesn't enforce secure chat)
    const message: utils.TextComponent = .translate("chat.type.text", .{
        .args = &.{ .text(name, .{}), .text(pack.message, .{}) },
    });
    owner.players_mutex.lockUncancelable();
    defer owner.players_mutex.unlock();
    owner.broadcastSystemChatLocked(params.toAllocPair(), message);
}

pub fn @"serverbound/play/chat_command"(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const command = net.packets.chat_command_c2s;
    const pack = try command.readRoot(params, reader);
    logger.info("[{f}] Command: /{s}", .{ conn, pack });

    try conn.sendPacket(params.toAllocPair(), "system_chat", net.packets.system_chat_s2c, .{
        .content = .text("Commands aren't implemented yet", .{}),
        .overlay = false,
    });
}

/// For packets a client keeps sending while idling, they don't do anything yet.
fn ignorePacket(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    _ = conn;
    _ = params;
    _ = try reader.discardRemaining();
}

pub const @"serverbound/play/attack" = ignorePacket;
pub const @"serverbound/play/chat_ack" = ignorePacket;
pub const @"serverbound/play/chunk_batch_received" = ignorePacket;
pub const @"serverbound/play/client_command" = ignorePacket;
pub const @"serverbound/play/client_information" = ignorePacket;
pub const @"serverbound/play/client_tick_end" = ignorePacket;
pub const @"serverbound/play/command_suggestion" = ignorePacket;
pub const @"serverbound/play/container_close" = ignorePacket;
pub const @"serverbound/play/custom_payload" = ignorePacket;
pub const @"serverbound/play/debug_subscription_request" = ignorePacket;
pub const @"serverbound/play/interact" = ignorePacket;
pub const @"serverbound/play/move_player_pos" = ignorePacket;
pub const @"serverbound/play/move_player_pos_rot" = ignorePacket;
pub const @"serverbound/play/move_player_rot" = ignorePacket;
pub const @"serverbound/play/move_player_status_only" = ignorePacket;
pub const @"serverbound/play/pick_item_from_block" = ignorePacket;
pub const @"serverbound/play/pick_item_from_entity" = ignorePacket;
pub const @"serverbound/play/ping_request" = ignorePacket;
pub const @"serverbound/play/player_abilities" = ignorePacket;
pub const @"serverbound/play/player_action" = ignorePacket;
pub const @"serverbound/play/player_command" = ignorePacket;
pub const @"serverbound/play/player_input" = ignorePacket;
pub const @"serverbound/play/pong" = ignorePacket;
pub const @"serverbound/play/punch" = ignorePacket;
pub const @"serverbound/play/recipe_book_change_settings" = ignorePacket;
pub const @"serverbound/play/seen_advancements" = ignorePacket;
pub const @"serverbound/play/set_carried_item" = ignorePacket;
pub const @"serverbound/play/spectator_action" = ignorePacket;
pub const @"serverbound/play/teleport_to_entity" = ignorePacket;
pub const @"serverbound/play/use_item" = ignorePacket;
pub const @"serverbound/play/use_item_on" = ignorePacket;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(LoginConnection);
}
