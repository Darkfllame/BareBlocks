const std = @import("std");
const builtin = @import("builtin");
const coro = @import("coro");
const utils = @import("utils");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const logger = std.log.scoped(logger_scope);

const assert = std.debug.assert;

const static_io = coro.AnyCoroutine.static_io;

const logger_scope = .net;

pub const StructuredPacket = @import("StructuredPacket.zig");
pub const packets = @import("packets.zig");

pub const PacketType = StructuredPacket.Type;

pub const NetworkingSide = enum { client, server };
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

pub const Connection = struct {
    const reader_vtable = Io.Reader.VTable{
        .stream = streamImpl,
        .readVec = readVec,
    };
    const writer_vtable = Io.Writer.VTable{
        .drain = drain,
    };

    const CoroReadError = error{
        SystemResources,
        ConnectionResetByPeer,
        LegacyHandshake,
        PacketTooSmall,
        PacketTooLarge,
        EndOfStream,
        InvalidPacketID,
        OutOfMemory,
        Disconnected,
    };
    const CoroWriteError = error{ Disconnected, ConnectionResetByPeer, SystemResources };

    const PacketNode = struct {
        node: std.DoublyLinkedList.Node,
        length: usize,

        fn getBytes(self: *PacketNode) []const u8 {
            return @as([*]const u8, @ptrCast(self))[0 .. @sizeOf(PacketNode) + self.length];
        }

        fn getData(self: *PacketNode) []const u8 {
            return @as([*]const u8, @ptrCast(self))[@sizeOf(PacketNode)..][0..self.length];
        }
    };

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const max_iovecs_len = 8;

        const conn: *Connection = @alignCast(@fieldParentPtr("reader", io_r));
        const io = conn.read_coro.any.io();
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        assert(dest[0].len > 0);
        const n = io.vtable.netRead(io.userdata, conn.stream_handle, dest) catch |err| {
            conn.read_error = err;
            return error.ReadFailed;
        };
        if (n == 0) {
            return error.EndOfStream;
        }
        if (n > data_size) {
            conn.reader.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const conn: *Connection = @alignCast(@fieldParentPtr("writer", io_w));
        const io = conn.write_coro.any.io();
        const buffered = io_w.buffered();
        const n = io.vtable.netWrite(io.userdata, conn.stream_handle, buffered, data, splat) catch |err| {
            conn.write_error = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }

    fn coro_readConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) CoroReadError!void {
        _ = co;
        self.reader = .{
            .vtable = &reader_vtable,
            .buffer = &self.read_buffer,
            .seek = 0,
            .end = 0,
        };

        var read_arena = std.heap.ArenaAllocator.init(allocator);
        defer read_arena.deinit();

        while (true) : ({
            if (!read_arena.reset(.{ .retain_with_limit = max_packet_length })) {
                @branchHint(.unlikely);
                logger.warn("Failed to reset arena allocator for {f}", .{self.ip_address});
            }
        }) {
            self.readConnection(read_arena.allocator()) catch |e| switch (e) {
                error.ReadFailed => return switch (self.read_error.?) {
                    error.SocketUnconnected, error.Canceled => break,
                    error.NetworkDown => error.Disconnected,
                    error.SystemResources, error.ConnectionResetByPeer => |err| err,
                    error.AccessDenied, error.Timeout, error.Unexpected => unreachable,
                },
                error.LegacyHandshake,
                error.PacketTooSmall,
                error.PacketTooLarge,
                error.EndOfStream,
                error.InvalidPacketID,
                error.OutOfMemory,
                => |err| return err,
            };
        }
    }

    fn coro_writeConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) CoroWriteError!void {
        self.writer = .{
            .vtable = &writer_vtable,
            .buffer = &self.write_buffer,
            .end = 0,
        };

        while (true) {
            self.writeConnection(co, allocator) catch {
                return switch (self.write_error.?) {
                    error.SocketUnconnected, error.Canceled => break,
                    error.NetworkUnreachable,
                    error.NetworkDown,
                    error.ConnectionRefused,
                    error.SocketNotBound,
                    error.HostUnreachable,
                    => error.Disconnected,
                    error.ConnectionResetByPeer, error.SystemResources => |err| err,
                    error.AddressFamilyUnsupported, error.Unexpected, error.FastOpenAlreadyInProgress => unreachable,
                };
            };
        }
    }

    fn readConnection(self: *Connection, allocator: Allocator) !void {
        const reader = &self.reader;
        if (self.phase == .handshake and (try reader.peekByte()) == 0xFE) { // legacy handshake
            return error.LegacyHandshake;
        }

        const packet_length: i32 = PacketType.readRoot(.var_int, .failing, reader) catch |e| switch (e) {
            error.Overflow => return error.PacketTooLarge,
            error.ReadFailed, error.EndOfStream => |err| return err,
            else => unreachable,
        };
        if (packet_length <= 0) return error.PacketTooSmall;
        if (packet_length > max_packet_length) return error.PacketTooLarge;
        const length: usize = @intCast(packet_length);
        const packet_bytes = try if (reader.buffer.len >= length)
            reader.take(length)
        else
            reader.readAlloc(allocator, length);
        var preader = Io.Reader.fixed(packet_bytes);
        const packet_id = PacketType.readRoot(.var_int, .failing, &preader) catch |e| switch (e) {
            error.Overflow => return error.InvalidPacketID,
            error.ReadFailed, error.EndOfStream => |err| return err,
            else => unreachable,
        };

        const pid = self.packet_registry.getPacketID(self.target_side, self.phase, packet_id) orelse
            return error.InvalidPacketID;
        const entry = self.packet_registry.getEntry(self.target_side, self.phase, pid);

        entry.callback(self, &preader, allocator) catch |e| switch (e) {
            error.ReadFailed => switch (builtin.mode) {
                .Debug, .ReleaseSafe => std.debug.panic("[{f}] impossible error.ReadFailed occured while reading packet", .{self}),
                .ReleaseFast, .ReleaseSmall => unreachable,
            },
            error.OutOfMemory, error.EndOfStream => |err| return err,
        };
    }

    fn writeConnection(self: *Connection, co: *coro.AnyCoroutine, allocator: Allocator) Io.Writer.Error!void {
        const writer = &self.writer;

        const pnode = self.popPacket() orelse {
            try writer.flush();
            co.yield() catch {};
            return;
        };
        defer allocator.free(pnode.getBytes());
        const bytes = pnode.getData();

        assert(bytes.len <= max_packet_length);

        PacketType.write(.var_int, .failing, writer, @intCast(bytes.len)) catch |e| switch (e) {
            error.WriteFailed => |err| return err,
            else => unreachable,
        };
        try writer.writeAll(bytes);
    }

    fn popPacket(self: *Connection) ?*PacketNode {
        const pack = self.send_queue.pop() orelse return null;
        return @fieldParentPtr("node", pack);
    }

    /// Will replace the ip when this connection gets formatted to the console.
    name: ?[]const u8 = null,
    phase: NetworkingPhase,
    target_side: NetworkingSide,

    packet_registry: *const PacketRegistry,

    stream_handle: net.Socket.Handle,
    ip_address: net.IpAddress,

    read_buffer: [128]u8,
    reader: Io.Reader,
    read_error: ?net.Stream.Reader.Error,
    parsing_error: ?PacketType.ReadError,
    read_coro: coro.Coroutine(CoroReadError!void),

    write_buffer: [128]u8,
    writer: Io.Writer,
    write_error: ?net.Stream.Writer.Error,
    write_coro: coro.Coroutine(CoroWriteError!void),

    send_queue: std.DoublyLinkedList,

    /// Maximum value of `u21`, roughly 2MiB
    pub const max_packet_length = (2 * 1024 * 1024) - 1;

    pub const ReadCallbackError = Io.Reader.Error || Allocator.Error;

    /// Because `Connection` is supposed to be embedded like `std.Io.Reader`,
    /// it should only return errors possible from an `std.Io.Reader` and `std.mem.Allocator`
    /// (for copying data) More detailed error codes should be set inside a parent structure
    /// and retreive when neccesary.
    ///
    /// The data in `reader` will never move, as such the `StructuredPacket` API is useable with it.
    ///
    /// The memory allocated by the allocator passed in this function will only stay valid for this call
    /// **only**. Any data that is wished to stay persitent must be copied to a new location.
    ///
    /// Note: `error.ReadFailed` is technically impossible, but is here mainly for convenience, so you can
    /// just call functions within `reader` with `try` directly.
    pub const ReadCallbackFn = fn (conn: *Connection, reader: *Io.Reader, arena: Allocator) ReadCallbackError!void;

    pub const InitOptions = struct {
        packet_registry: *const PacketRegistry,
        stream: net.Stream,
        target_side: NetworkingSide,
    };

    /// `allocator` must remain valid until this connection is deinitalized
    pub fn init(self: *Connection, allocator: Allocator, options: InitOptions) Allocator.Error!void {
        self.* = .{
            .phase = .handshake,
            .target_side = options.target_side,

            .packet_registry = options.packet_registry,

            .stream_handle = options.stream.socket.handle,
            .ip_address = options.stream.socket.address,

            .read_buffer = undefined,
            .reader = .failing,
            .read_error = null,
            .parsing_error = null,
            .read_coro = undefined,

            .write_buffer = undefined,
            .writer = .failing,
            .write_error = null,
            .write_coro = undefined,

            .send_queue = .{},
        };

        try self.read_coro.init(.{}, coro_readConnection, .{ self, allocator });
        errdefer self.read_coro.deinit();
        try self.write_coro.init(.{}, coro_writeConnection, .{ self, allocator });
        errdefer self.write_coro.deinit();
    }

    pub fn deinit(self: *Connection, allocator: Allocator) void {
        self.read_coro.await(.cancel) catch |e| {
            logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
        };
        self.write_coro.await(.cancel) catch |e| {
            logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
        };
        while (self.popPacket()) |packet| allocator.free(packet.getBytes());
        static_io.vtable.netClose(static_io.userdata, (&self.stream_handle)[0..1]);
    }

    pub fn format(self: *const Connection, writer: *Io.Writer) Io.Writer.Error!void {
        try if (self.name) |nm|
            writer.writeAll(nm)
        else
            self.ip_address.format(writer);
        try writer.print("<{t}>->{t}", .{ self.phase, self.target_side });
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Connection);
    std.testing.refAllDecls(PacketRegistry);
}
