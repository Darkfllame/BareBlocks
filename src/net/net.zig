const std = @import("std");
const coro = @import("coro");
const utils = @import("utils");

const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const static_io = coro.AnyCoroutine.always_yield.io();

const logger = std.log.scoped(.net);

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
        callback: *const CallbackFn,
    };

    pub const CallbackFn = fn (
        reader: *Io.Reader,
        /// Memory allocated with this allocator is only meant to be used
        /// WITHIN this function call and may be freed after it returns.
        arena: Allocator,
        data: *anyopaque,
    ) Io.Reader.Error!void;

    /// Placeholder, just `@sizeOf(usize)` bytes of data.
    pub const CallbackData = [@sizeOf(usize)]u8;

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

    pub fn getCallback(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?*const CallbackFn {
        const list = self.entries.getPtrConst(side).getPtrConst(phase);
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.resource, resource)) return entry.callback;
        }
        return null;
    }

    pub fn getPacketID(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, resource: []const u8) ?PacketID {
        const list = self.entries.getPtrConst(side).getPtrConst(phase);
        for (list.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.resource, resource)) return @enumFromInt(i);
        }
        return null;
    }

    pub fn getEntry(self: *const PacketRegistry, side: NetworkingSide, phase: NetworkingPhase, id: PacketID) *const Entry {
        return &self.entries.getPtrConst(side).getPtrConst(phase).items[@intFromEnum(id)];
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

    fn coro_readConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) void {
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
            self.readConnection(read_arena.allocator()) catch |e| switch (e) {};
        }
    }

    fn coro_writeConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) void {
        _ = co;
        _ = allocator;
        self.writer = .{
            .vtable = &writer_vtable,
            .buffer = &self.write_buffer,
            .end = 0,
        };
        self.writeConnection();
    }

    fn readConnection(self: *Connection, allocator: Allocator) !void {
        _ = allocator;
        if (self.phase == .handshake and (try self.reader.peekByte()) == 0xFE) { // legacy handshake
            return error.LegacyHandshake;
        }
    }

    phase: NetworkingPhase,

    packet_registry: *const PacketRegistry,

    stream_handle: net.Socket.Handle,
    ip_address: net.IpAddress,

    read_buffer: [128]u8,
    reader: Io.Reader,
    read_error: ?net.Stream.Reader.Error,
    parsing_error: ?PacketType.ReadError,
    read_coro: coro.Coroutine(void),

    write_buffer: [128]u8,
    writer: Io.Writer,
    write_error: ?net.Stream.Writer.Error,
    write_coro: coro.Coroutine(void),

    send_queue: std.DoublyLinkedList,

    /// Maximum value of `u21`, roughly 2MiB
    pub const max_packet_length = (2 * 1024 * 1024) - 1;

    /// `allocator` must remain valid until this connection is deinitalized
    pub fn init(self: *Connection, allocator: Allocator, packet_registry: *const PacketRegistry, stream: net.Stream) Allocator.Error!void {
        self.* = .{
            .phase = .handshake,

            .packet_registry = packet_registry,

            .stream_handle = stream.socket.handle,
            .ip_address = stream.socket.address,

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
        self.read_coro.await(.cancel);
        self.write_coro.await(.cancel);
        while (self.popPacket()) |packet| packet.deinit(allocator);
        static_io.vtable.netClose(static_io.userdata, (&self.stream_handle)[0..1]);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Connection);
    std.testing.refAllDecls(PacketRegistry);
}
