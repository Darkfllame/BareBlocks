const Player = @This();
const std = @import("std");
const zio = @import("zio");
const net = @import("net");
const utils = @import("utils");
const core = @import("core.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Server = core.Server;
const Connection = net.Connection;
const PacketType = net.PacketType;
const AllocPair = net.PacketType.AllocPair;
const Atomic = std.atomic.Value;

const assert = std.debug.assert;

const logger = std.log.scoped(.@"core/Player");

const SetEidError = Allocator.Error || error{ DuplicateId, DuplicateUUId };

const ConnectionImpl = struct {
    const OwnedConnection = Server.OwnedConnection;
    const ConfigPlayCommon = Server.ConfigPlayCommon;
    const LoginConnection = Server.LoginConnection;

    const vtable = Connection.VTable{
        .deinit = &deinitImpl,
        .disconnect = disconnectImpl,
        .tick = tickImpl,
    };

    fn deinitImpl(conn: *Connection, allocator: Allocator) void {
        const plr = fromConnectionPtr(conn);
        plr.deinit();
        LoginConnection.deinitImpl(conn, allocator);
    }

    fn disconnectImpl(conn: *Connection, reason: *const utils.TextComponent) Connection.WritePacketError!void {
        const plr = fromConnectionPtr(conn);

        const owned = plr.connection.owned;
        const owner = owned.owner;
        const playing = owned.data.play;

        var arena: std.heap.ArenaAllocator = undefined;
        const apair = net.PacketType.AllocPair.newFromGpa(owner.allocator, &arena);
        defer arena.deinit();

        try conn.sendPacket(apair, "disconnect", net.packets.disconnect_s2c, reason.*);

        zio.beginShield();
        defer zio.endShield();
        owner.player_man.remove(playing) catch unreachable;
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

const EIDState = struct {
    /// Zig's hashmap implementation uses tombstones and needs rehashing ever so often
    /// to keep optimal performances.
    ///
    /// This is the number of `removeEID/UUID` calls required before triggering a rehashing of both
    /// EID -> UUID and UUID -> EID hashmaps.
    const eid_deletes_for_rehash = 1024;

    fn lock(self: *EIDState) Io.Cancelable!void {
        return self.rw.lock();
    }
    fn lockUncancelable(self: *EIDState) void {
        return self.rw.lockUncancelable();
    }
    fn lockShared(self: *EIDState) Io.Cancelable!void {
        return self.rw.lockShared();
    }
    fn lockSharedUncancelable(self: *EIDState) void {
        return self.rw.lockSharedUncancelable();
    }
    fn unlock(self: *EIDState) void {
        return self.rw.unlock();
    }
    fn unlockShared(self: *EIDState) void {
        return self.rw.unlockShared();
    }

    fn set(self: *EIDState, gpa: Allocator, eid: EntityID, uuid: utils.UUID) SetEidError!void {
        if (@backingInt(eid) > self.mask.bit_length) {
            try self.mask.resize(gpa, @backingInt(eid), false);
        }

        try self.id2unique.ensureUnusedCapacity(gpa, 1);
        try self.unique2id.ensureUnusedCapacity(gpa, 1);

        const id_gop = self.id2unique.getOrPutAssumeCapacity(eid);
        if (id_gop.found_existing) return error.DuplicateId;
        id_gop.value_ptr.* = uuid;
        errdefer self.id2unique.removeByPtr(id_gop.key_ptr);

        const uuid_gop = self.unique2id.getOrPutAssumeCapacity(uuid);
        if (uuid_gop.found_existing) return error.DuplicateUUId; // On a side note, i you truly get a duplicate uuid i'm genuinely curious to know how
        uuid_gop.value_ptr.* = eid;
    }

    fn getFromEID(self: *const EIDState, eid: EntityID) ?utils.UUID {
        return self.id2unique.get(eid);
    }

    fn getFromUUID(self: *const EIDState, uuid: utils.UUID) ?EntityID {
        return self.unique2id.get(uuid);
    }

    fn nextEID(self: *EIDState) error{OutOfEId}!EntityID {
        const ret = self.next_eid orelse return error.OutOfEId;

        var it = self.mask.iterator(.{ .kind = .unset });
        const idx = it.next() orelse self.mask.bit_length;
        self.next_eid = if (idx > std.math.maxInt(u32)) null else @fromBackingInt(@intCast(idx));

        return ret;
    }

    fn removeEID(self: *EIDState, eid: EntityID) void {
        const nm = @as(*const Player, @alignCast(@fieldParentPtr("eid_state", self))).getUsername();

        if (!self.mask.isSet(@backingInt(eid))) std.debug.panic("[{s}] Entity id '{d}' was not set", .{ nm, eid });

        self.mask.unset(@backingInt(eid));
        const uuid = self.id2unique.fetchRemove(eid) orelse
            std.debug.panic("[{s}] Couldn't find uuid for id '{d}'", .{ nm, eid });
        if (!self.unique2id.remove(uuid.value)) std.debug.panic("[{s}] Couldn't find back id({d}) from uuid({f})", .{ nm, eid, uuid.value });

        // Make sure to not soft-lock entity id's
        self.next_eid = self.next_eid orelse eid;

        self.deletes += 1;
        if (self.deletes >= eid_deletes_for_rehash) {
            self.id2unique.rehash(std.hash_map.AutoContext(EntityID){});
            self.unique2id.rehash(utils.UUID.HashCtx{});
            self.deletes = 0;
        }
    }

    fn removeUUID(self: *EIDState, uuid: utils.UUID) void {
        const eid = self.unique2id.get(uuid) orelse
            std.debug.panic("[{s}] Attempted to remove unknown uuid: {f}", .{ @as(*const Player, @alignCast(@fieldParentPtr("eid_state", self))).getUsername(), uuid });
        return self.removeEID(eid);
    }

    fn deinit(self: *EIDState, gpa: Allocator) void {
        self.mask.deinit(gpa);
        self.id2unique.deinit(gpa);
        self.unique2id.deinit(gpa);
    }

    rw: zio.RwLock = .init,
    mask: std.bit_set.Dynamic = .{},
    next_eid: ?EntityID = @fromBackingInt(2),
    deletes: std.math.IntFittingRange(0, eid_deletes_for_rehash) = 0,
    id2unique: std.AutoHashMapUnmanaged(EntityID, utils.UUID) = .empty,
    unique2id: std.HashMapUnmanaged(utils.UUID, EntityID, utils.UUID.HashCtx, std.hash_map.default_max_load_percentage) = .empty,
};

fn fromConnectionPtr(conn: *Connection) *Player {
    const owned: *ConnectionImpl.OwnedConnection = @fieldParentPtr("connection", conn);
    return owned.data.play;
}

connection: ConnectionImpl,
profile: utils.GameProfile,

eid_state: EIDState = .{},

pub const GetOrAddEntityIdError = Allocator.Error || error{OutOfEId};

pub const EntityID = enum(u32) {
    /// Invalid EID number.
    ///
    /// The UUID linked to this value is `UUID.null`, will crash clients if sent to them.
    null = 0,
    /// The own player's EID must always remain this.
    player_self = 1,
    _,
};

pub const InitOptions = struct {
    owned: *Server.OwnedConnection,
    profile: utils.GameProfile,
    common: Server.ConfigPlayCommon,
};

pub fn init(self: *Player, options: InitOptions) Allocator.Error!void {
    const gpa = options.owned.owner.allocator;
    self.* = .{
        .connection = .{
            .owned = options.owned,
            .common = options.common,
        },
        .profile = options.profile,
    };

    {
        self.eid_state.lockUncancelable();
        defer self.eid_state.unlock();

        self.eid_state.set(gpa, .null, .null) catch |e| switch (e) {
            error.DuplicateId, error.DuplicateUUId => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };

        self.eid_state.set(gpa, .player_self, self.profile.uuid) catch |e| switch (e) {
            error.DuplicateId, error.DuplicateUUId => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
}

pub fn deinit(self: *Player) void {
    const owner = self.getOwner();
    self.eid_state.deinit(owner.allocator);
}

pub fn reconfigureForPlay(conn: *Connection) void {
    conn.reconfigure(.{
        .in_phase = .play,
        .out_phase = .play,
        .vtable = &ConnectionImpl.vtable,
    });
}

pub fn getOwner(self: *const Player) *Server {
    return self.connection.owned.owner;
}

pub fn getConnection(self: *const Player) *Connection {
    return &self.connection.owned.connection;
}

pub fn getGameProfile(self: *const Player) utils.GameProfile {
    return self.profile;
}

pub fn getUsername(self: *const Player) []const u8 {
    return self.profile.username();
}

pub fn getLatency(self: *const Player) u64 {
    return self.connection.common.latency;
}

/// Returns `self`.
pub fn acquire(self: *Player) *Player {
    _ = self.getConnection().acquire();
    return self;
}

pub fn release(self: *Player) void {
    return self.getConnection().release(self.getOwner().allocator);
}

pub fn lock(self: *Player) Io.Cancelable!void {
    return self.getConnection().lock();
}

pub fn lockUncancelable(self: *Player) void {
    return self.getConnection().lockUncancelable();
}

pub fn tryLock(self: *Player) bool {
    return self.getConnection().tryLock();
}

pub fn unlock(self: *Player) void {
    return self.getConnection().unlock();
}

pub fn disconnect(self: *Player, reason: Connection.DisconnectReason) void {
    return self.getConnection().disconnect(reason);
}

pub fn getEntityId(self: *Player, uuid: utils.UUID) ?EntityID {
    if (uuid.eql(.null)) return .null; // fast path
    if (self.profile.uuid.eql(uuid)) return .player_self; // fast path

    self.eid_state.lockSharedUncancelable();
    defer self.eid_state.unlockShared();

    return self.eid_state.getFromUUID(uuid);
}

pub fn getOrAddEntityId(self: *Player, uuid: utils.UUID) GetOrAddEntityIdError!?EntityID {
    if (uuid.eql(.null)) return .null;
    if (self.profile.uuid.eql(uuid)) return .player_self; // fast path

    self.eid_state.lockSharedUncancelable();
    const maybe_eid = self.eid_state.getFromUUID(uuid);
    self.eid_state.unlockShared();

    const eid = maybe_eid orelse blk: {
        self.eid_state.lockUncancelable();
        defer self.eid_state.unlock();

        const eid = try self.eid_state.nextEID();
        self.eid_state.set(self.getOwner().allocator, eid, uuid) catch |e| switch (e) {
            error.DuplicateId, error.DuplicateUUId => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };

        break :blk eid;
    };

    return eid;
}

/// Panics on missing values.
///
/// TODO: Figure out if panicking is a good solution or just really bad.
pub fn removeEntityId(self: *Player, uuid: utils.UUID) void {
    if (self.profile.uuid.eql(uuid)) std.debug.panic("[{s}] Why the fuck do you wanna remove yourself idiot", .{self.getUsername()});

    self.eid_state.lockUncancelable();
    defer self.eid_state.unlock();

    self.eid_state.removeUUID(uuid);
}

pub fn sendPacket(self: *const Player, apair: AllocPair, resource: []const u8, comptime @"type": PacketType, value: @"type".getZigType()) Connection.WritePacketError!void {
    return self.getConnection().sendPacket(apair, resource, @"type", value);
}

pub fn sendPackets(self: *const Player, apair: AllocPair, packets: anytype) Connection.WritePacketError!void {
    return self.getConnection().sendPackets(apair, packets);
}

pub fn batchSend(self: *const Player, apair: AllocPair) Connection.PacketSendState {
    return self.getConnection().batchSend(apair);
}

test {
    std.testing.refAllDecls(Player);
}
