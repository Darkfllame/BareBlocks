const Server = @This();
const std = @import("std");
const coro = @import("coro");
const net = @import("net");
const utils = @import("utils");
const registries = @import("registries");
const packets = @import("packets");
const crypto = @import("crypto");
const core = @import("core.zig");

const Io = std.Io;
const Connection = net.Connection;
const Allocator = std.mem.Allocator;

const logger = std.log.scoped(.@"core/server");

const static_io = coro.AnyCoroutine.static_io;
const current_version = net.packets.StatusResponse.Version.@"26.2";

const assert = std.debug.assert;

const CoroAccpetError = Allocator.Error || coro.polling.AddError || error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    NetworkDown,
    ConnectionAborted,
    BlockedByFirewall,
    ProtocolFailure,
    Canceled,
    SocketUnconnected,
    Timeout,
    Unexpected,
};

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

const PolledInfo = union(enum) {
    server,
    serverv6,
    client: *Connection,

    pub fn format(self: PolledInfo, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .server => try writer.writeAll(".server"),
            .client => |conn| try writer.print("({f})", .{conn}),
        }
    }
};

const OwnedConnection = struct {
    owner: *Server,
    connection: Connection,
    data: union(enum) {
        none,
        login: *LoginConnection,
        config: *ConfigConnection,
    },
};

const LoginConnection = struct {
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
            allocator.destroy(comp);
        }
    }

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        assert(owned.data == .login);

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

const ConfigPlayCommon = struct {
    const keepalive_timeout_ms = 15_000;

    fn getKeepAliveValue() u64 {
        return @bitCast(Io.Timestamp.now(static_io, .boot).toMilliseconds());
    }
    fn getPingValue() u32 {
        return @truncate(getKeepAliveValue());
    }

    keep_alive: ?u64,
    ping: ?u32,
    latency: u64,

    fn keepAlive(self: *ConfigPlayCommon, conn: *Connection) net.Connection.WritePacketError!void {
        const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
        
        const now = getKeepAliveValue();
        if (self.keep_alive) |ka| {
            if (now - ka >= keepalive_timeout_ms) {
                try conn.disconnect(&.timeout);
            }
        } else {
            self.keep_alive = now;

            var arena: std.heap.ArenaAllocator = undefined;
            const apair = net.PacketType.AllocPair.newFromGpa(owned.owner.allocator, &arena);
            defer arena.deinit();

            try conn.sendPacket(apair, "keep_alive", net.packets.keep_alive, now);
        }
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
            .none ,
            .login => unreachable,
            .config => |c| &c.common,
        };

        if (common.keep_alive) |ka| {
            if (pack != ka) return conn.disconnect(&.timeout);
            const diff = getKeepAliveValue() - ka;
            common.latency = (common.latency * 3 + diff) / 4;
            common.keep_alive = null;
        }
    }
};

const ConfigConnection = struct {
    const vtable = Connection.VTable{
        .deinit = LoginConnection.deinitImpl,
        .disconnect = disconnectImpl,
    };

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
    encryption: *Connection.Encryption,
    compression: *Connection.Compression,
};

fn coro_acceptConnection(co: *coro.AnyCoroutine, self: *Server, which: enum { v4, v6 }) CoroAccpetError!void {
    const coio = co.io();

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

    while (true) {
        var stream: ?Io.net.Stream = sock.accept(coio) catch |err| switch (err) {
            error.Unexpected, error.WouldBlock => unreachable,
            error.Canceled => break,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.SocketNotListening,
            error.NetworkDown,
            error.ConnectionAborted,
            error.BlockedByFirewall,
            error.ProtocolFailure,
            => |e| return e,
        };
        errdefer if (stream) |s| s.close(coio);

        try self.connections.ensureUnusedCapacity(self.allocator, 1);

        const owned = try self.allocator.create(OwnedConnection);
        errdefer self.allocator.destroy(owned);
        owned.* = .{
            .owner = self,
            .connection = undefined,
            .data = .none,
        };
        const conn = &owned.connection;

        conn.init(self.allocator, .{
            .packet_registry = self.packet_registry,
            .stream = stream.?,
            .target_side = .client,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                logger.err("Couldn't add connection to {f}: {t}", .{ stream.?.socket.address, e });
                stream.?.close(coio);
                self.allocator.destroy(owned);
                continue;
            },
        };
        stream = null;
        errdefer conn.deinit(self.allocator);

        try self.poller.addSocket(self.allocator, conn.getSocket(), .rw, .{ .client = conn });

        const gop = self.connections.getOrPutAssumeCapacity(conn);
        if (gop.found_existing) {
            logger.debug("Threw {f}: duplicate connection", .{conn.ip_address});
            self.destroyConnection(conn);
        }
    }
}

fn destroyConnection(self: *Server, conn: *Connection) void {
    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

    conn.deinit(self.allocator);
    switch (owned.data) {
        .none => {},
        .login => |loginging| self.allocator.destroy(loginging),
        .config => |configing| self.allocator.destroy(configing),
    }
    self.allocator.destroy(owned);
}

packet_registry: *const net.PacketRegistry,
allocator: Allocator,
io: Io,
accept_options: Io.net.Server.AcceptOptions,
v6_enabled: bool,
sockv4_handle: Io.net.Socket.Handle,
sockv6_handle: Io.net.Socket.Handle,
ipv4: Io.net.Ip4Address,
ipv6: Io.net.Ip6Address,
connections: std.HashMapUnmanaged(*Connection, void, Connection.HashContext, std.hash_map.default_max_load_percentage),
poller: coro.polling.Poller(PolledInfo),
accept_coro: coro.Coroutine(CoroAccpetError!void),
acceptv6_coro: coro.Coroutine(CoroAccpetError!void),

server_id: [20]u8,
rsa_key: *crypto.EVP_PKEY,
public_key_bytes: []u8,

compression_threshold: u31,

pub const server_id_header = "gecko_";

pub const InitError = error{
    EncryptionSetupFailed,
} || Io.net.IpAddress.ListenError || Allocator.Error || coro.polling.CreateError || coro.polling.AddError;

pub const InitOptions = struct {
    // packet_registry: *const net.PacketRegistry,
    allocator: Allocator,
    io: Io,
    bind_port: u16 = 25565,
    bind_port_v6: ?u16 = null,
    max_connections: u31 = Io.net.default_kernel_backlog,
    compression_threshold: u31 = 256,
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

pub fn init(self: *Server, options: InitOptions) InitError!void {
    const addr = Io.net.IpAddress{ .ip4 = .loopback(options.bind_port) };
    const listen_opt = Io.net.IpAddress.ListenOptions{
        .kernel_backlog = options.max_connections,
        .reuse_address = true,
    };
    var sock = try addr.listen(static_io, listen_opt);
    errdefer sock.deinit(static_io);
    var sockv6 = if (options.bind_port_v6) |port|
        try Io.net.IpAddress.listen(&.{ .ip6 = .loopback(port) }, static_io, listen_opt)
    else
        null;
    errdefer if (sockv6) |*s| s.deinit(static_io);

    var poller = try @FieldType(Server, "poller").init();
    errdefer poller.deinit(options.allocator);
    try poller.addSocket(options.allocator, sock.socket, .readonly, .server);
    if (sockv6) |s| {
        try poller.addSocket(options.allocator, s.socket, .readonly, .serverv6);
    }

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

    self.* = .{
        .packet_registry = &packets.registry,
        .allocator = options.allocator,
        .io = options.io,
        .accept_options = sock.options,
        .v6_enabled = sockv6 != null,
        .sockv4_handle = sock.socket.handle,
        .sockv6_handle = if (sockv6) |s| s.socket.handle else undefined,
        .ipv4 = sock.socket.address.ip4,
        .ipv6 = if (sockv6) |s| s.socket.address.ip6 else undefined,
        .connections = .empty,
        .poller = poller,
        .accept_coro = undefined,
        .acceptv6_coro = undefined,

        .server_id = undefined,
        .rsa_key = key.?,
        .public_key_bytes = der,

        .compression_threshold = options.compression_threshold,
    };

    {
        var id_writer = Io.Writer.fixed(&self.server_id);
        id_writer.writeAll(server_id_header) catch {};
        var hex_buffer: [@divFloor(self.server_id.len - server_id_header.len + 1, 2)]u8 = undefined;
        options.io.random(&hex_buffer);
        for (hex_buffer) |b| {
            id_writer.writeAll(&std.fmt.hex(b)) catch {};
        }
    }

    try self.accept_coro.init(.{}, coro_acceptConnection, .{ self, .v4 });
    errdefer self.accept_coro.deinit();
    if (self.v6_enabled) {
        try self.acceptv6_coro.init(.{}, coro_acceptConnection, .{ self, .v6 });
    } else {
        self.acceptv6_coro = .initFinished({});
    }
    errdefer self.acceptv6_coro.deinit();
}

pub fn deinit(self: *Server) void {
    // TODO: Race conditions ?
    crypto.EVP_PKEY_free(self.rsa_key);
    self.allocator.free(self.public_key_bytes);

    self.accept_coro.await(.cancel) catch |e| {
        logger.err("Caught error while closing server: {t}", .{e});
    };
    self.acceptv6_coro.await(.cancel) catch |e| {
        logger.err("Caught error while closing server: {t}", .{e});
    };

    Io.net.Socket.close(&.{
        .handle = self.sockv4_handle,
        .address = .{ .ip4 = self.ipv4 },
    }, static_io);
    if (self.v6_enabled) {
        Io.net.Socket.close(&.{
            .handle = self.sockv6_handle,
            .address = .{ .ip6 = self.ipv6 },
        }, static_io);
    }

    var conn_it = self.connections.keyIterator();
    while (conn_it.next()) |conn_ptr| {
        const conn = conn_ptr.*;

        self.destroyConnection(conn);
    }
    self.connections.deinit(self.allocator);
    self.poller.deinit(self.allocator);
}

pub fn tick(self: *Server) !void {
    var it = try self.poller.wait(1_000);
    while (it.next()) |ev| {
        // logger.debug("Event: {t}, {f}", .{ ev.data, ev.events });
        switch (ev.data) {
            .server => if (try self.accept_coro.@"resume"()) {
                return error.ServerClosed;
            },
            .serverv6 => if (try self.acceptv6_coro.@"resume"()) {
                return error.ServerClosed;
            },
            .client => |conn| {
                const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
                assert(owned.owner == self);

                // logger.debug("[{f}] Event: {f}", .{ conn, ev.events });
                var handled_disc= false;
                if (ev.events.in) {
                    const res = conn.read_coro.@"resume"();
                    // logger.debug("[{f}] Read result: {!}", .{ conn, res });
                    if (res) |finished| {
                        assert(!finished or conn.read_closed);
                    } else |err| {
                        const err2 = conn.handler_error orelse err;

                        switch (err2) {
                            error.CallbackHandlerFailed => {
                                const mixed_err = switch (owned.data) {
                                    .none, .config => error.Unknown,
                                    .login => |l| l.@"error".?,
                                };

                                logger.err("[{f}] Connection closed: {t}", .{ conn, mixed_err });
                            },
                            error.Disconnected => logger.info("[{f}] Disconnected", .{conn}),
                            else => logger.err("[{f}] Connection closed: {t}", .{ conn, err2 }),
                        }

                        conn.read_coro.deinit();
                        conn.read_coro = .initFinished({});
                        conn.shutdown(.recv) catch |e| {
                            logger.err("[{f}] Failed to shutdown connection: {t}", .{ conn, e });
                        };
                        handled_disc = true;
                    }
                }

                if (ev.events.out) {
                    // if (tagged.tag == .login) @breakpoint();
                    if (conn.write_coro.@"resume"()) |finished| {
                        assert(!finished or conn.write_closed);
                    } else |err| {
                        logger.err("[{f}] Connection closed: {t}", .{ conn, err });
                        conn.write_coro.deinit();
                        conn.write_coro = .initFinished({});
                        conn.shutdown(.send) catch |e| {
                            logger.err("[{f}] Failed to shutdown connection: {t}", .{ conn, e });
                        };
                        handled_disc = true;
                    }
                }

                const time_since_last_packet = conn.last_packet_timestamp.untilNow(self.io, .boot);
                const timedout = time_since_last_packet.nanoseconds > conn.timeout.nanoseconds;

                if (timedout and !handled_disc) {
                    logger.err("[{f}] Disconnected: Timeout", .{conn});
                }

                if (ev.events.err or (conn.read_closed and conn.send_queue.last == null) or timedout) {
                    assert(self.connections.remove(conn));
                    _ = self.poller.removeSocket(conn.getSocket());
                    self.destroyConnection(conn);
                    continue;
                }
            },
        }
    }
}

pub fn addressAlt(self: *const Server) AddressAlt {
    return .{
        .v4 = self.ipv4,
        .v6 = if (self.v6_enabled) self.ipv6 else null,
    };
}

pub fn handleHandshake(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const hs = net.packets.handshake_c2s;
    const pack = try hs.readRoot(params, reader);
    logger.debug("[{f}] Hanshake: {f}", .{ conn, hs.formatted(pack, params.toAllocPair()) });
    switch (pack.intent) {
        .invalid => return error.InvalidEnumTag,
        .status => conn.reconfigure(.{
            .in_phase = .status,
            .out_phase = .status,
        }),
        .login => {
            conn.reconfigure(.{ .out_phase = .login });
            if (pack.protocol_version != current_version.protocol) {
                try conn.disconnect(&.translate("multiplayer.status.incompatible", .{}));
                return error.CallbackHandlerFailed;
            }
            conn.reconfigure(.{ .in_phase = .login });
        },
        .transfer,
        => {
            conn.reconfigure(.{ .out_phase = .login });
            try conn.disconnect(&.transfers_disabled); // TODO: transfers ?
            return error.CallbackHandlerFailed;
        },
    }
}

pub fn handleStatus(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const status = net.packets.status_request_c2s;
    const pack = try status.readRoot(params, reader);
    logger.debug("[{f}] Status: {f}", .{ conn, status.formatted(pack, params.toAllocPair()) });
    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);

    try conn.sendPacket(
        params.toAllocPair(),
        "status_response",
        net.packets.status_response_s2c,
        net.packets.StatusResponse{
            .version = current_version,
            .description = .text("Minecraft on crack", .{}),
            .players = .{
                .online = @intCast(owned.owner.connections.count()),
                .max = 20,
            },
        },
    );
}

pub fn handleStatusPing(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
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

pub fn handleLoginHello(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const hello = net.packets.login_start_c2s;
    const pack = try hello.readRoot(params, reader);
    logger.debug("[{f}] Login Start: {f}", .{ conn, hello.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    if (owned.data != .none) {
        const logingin = owned.data.login;
        try conn.disconnect(&.translate("disconnect.packetError", .{ .common = .{
            .children = &.{
                .text(": ", .{}),
                .text("Double hello", .{}),
            },
        } }));
        logingin.@"error" = error.DoubleHello;
        return error.CallbackHandlerFailed;
    }
    const owner = owned.owner;

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
    owner.io.random(&loginging.verify_token);

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

pub fn handleLoginKey(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const encryption_setup_failed_tc = &utils.TextComponent.text("Internal Error: couldn't setup encryption", .{ .color = .red });

    const key = net.packets.key;
    const set_compression = net.packets.set_compression_s2c;
    const login_success = net.packets.login_success_s2c;

    const pack = try key.readRoot(params, reader);
    logger.debug("[{f}] Login Key: {f}", .{ conn, key.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const logingin = switch (owned.data) {
        .config => unreachable,
        .none => {
            try conn.disconnect(&.text("Client didn't initialize login", .{ .color = .red }));
            return;
        },
        .login => |l| l,
    };
    if (logingin.encryption != null) {
        try conn.disconnect(encryption_setup_failed_tc);
        logingin.@"error" = error.EncryptionAlreadySet;
        return error.CallbackHandlerFailed;
    }

    logingin.setupEncryption(owner, pack.shared_secret, pack.verify_token) catch |e| {
        logingin.encryption = null;
        try conn.disconnect(encryption_setup_failed_tc);
        logingin.@"error" = e;
        return error.CallbackHandlerFailed;
    };

    logingin.compression = try owner.allocator.create(Connection.Compression);
    errdefer owner.allocator.destroy(logingin.compression.?);
    logingin.compression.?.* = .{
        .threshold = owner.compression_threshold,
        .decompression_error = null,
        .decompress_buffer = undefined,
        .compress_buffer = undefined,
    };

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
        .session_id = utils.UUID.makeVersion4(owner.io),
    });

    conn.reconfigure(.{ .out_phase = .configuration });
}

pub fn handleLoginAck(conn: *Connection, reader: *Io.Reader, params: net.PacketType.ReadParams) net.Connection.ReadCallbackError!void {
    const ack = net.packets.login_acknowledged_c2s;
    const pack = try ack.readRoot(params, reader);
    logger.debug("[{f}] Login Ack: {f}", .{ conn, ack.formatted(pack, params.toAllocPair()) });

    const owned: *OwnedConnection = @fieldParentPtr("connection", conn);
    const owner = owned.owner;
    const loginging = owned.data.login;

    if (loginging.encryption == null) {
        try conn.disconnect(&.translate("disconnect.packetError", .{ .common = .{
            .children = &.{
                .text(": ", .{}),
                .text("Hello packet wasn't sent", .{}),
            },
        } }));
        loginging.@"error" = error.HelloMissing;
        return error.CallbackHandlerFailed;
    }

    const configing = try owner.allocator.create(ConfigConnection);
    errdefer comptime unreachable;

    configing.* = .{
        .owned = owned,
        .common = .{
            .keep_alive = null,
            .ping = null,
            .latency = 0,
        },
        .encryption = loginging.encryption.?,
        .compression = loginging.compression.?,
    };
    owned.data = .{ .config = configing };
    owner.allocator.destroy(loginging);
    conn.reconfigure(.{
        .in_phase = .configuration,
        .vtable = &ConfigConnection.vtable,
    });
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(LoginConnection);
}
