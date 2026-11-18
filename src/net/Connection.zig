//! An intrusive interface (like `std.Io.Reader/Writer`) that handles all the operations related to a
//! minecraft connection in either way. Use `.init()` to initalize it with specific options.
//!
//! TODO: doc
const Connection = @This();
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const zio = @import("zio");
const utils = @import("utils");
const crypto = @import("crypto");
const lm = @import("math");
const net = @import("net.zig");

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const logger = net.logger;
const ReadParams = net.PacketType.ReadParams;
const AllocPair = net.PacketType.AllocPair;
const PacketType = net.PacketType;
const flate = std.compress.flate;
const TextComponent = utils.TextComponent;
const NetworkingPhase = net.NetworkingPhase;
const NetworkingSide = net.NetworkingSide;
const PacketRegistry = net.PacketRegistry;
const Atomic = std.atomic.Value;

const cache_line_size = std.atomic.cache_line;
const assert = std.debug.assert;

const reader_vtable = Io.Reader.VTable{
    .stream = streamImpl,
    .readVec = readVec,
};
const decrypt_reader_vtable = Io.Reader.VTable{
    .stream = decryptStream,
};
const writer_vtable = Io.Writer.VTable{
    .drain = drain,
};

const reader_buffer_size = 1024;
const writer_buffer_size = 1024;

const CoroState = enum(u8) {
    waiting,
    alive,
    closing,
    closed,
};

const Packet = struct {
    length: usize,

    fn getBytes(self: *Packet) []align(@alignOf(Packet)) const u8 {
        return @as([*]align(@alignOf(Packet)) const u8, @ptrCast(self))[0 .. @sizeOf(Packet) + self.length];
    }

    fn getData(self: *Packet) []const u8 {
        return @as([*]const u8, @ptrCast(self))[@sizeOf(Packet)..][0..self.length];
    }
};

const ReaderState = struct {
    _: void align(cache_line_size) = {},

    state: Atomic(CoroState),
    buffer: [reader_buffer_size]u8,
    reader: Io.Reader,
    decrypt_reader: Io.Reader,
    read_error: ?StreamReadError,
    handler_error: ?ReadCallbackError,
    last_packet_timestamp: Io.Timestamp,
};

const WriterState = struct {
    _: void align(cache_line_size) = {},

    state: Atomic(CoroState),
    buffer: [writer_buffer_size]u8,
    writer: Io.Writer,
    @"error": ?StreamWriteError,
};

const HandlerSelectResult = union(enum) {
    read: CoroReadError!void,
    write: CoroWriteError!void,
    tick: TickError!void,
};

/// Disable Naggle's algorithm, which consists of grouping small packets together
/// to reduce inefficient networking. Kinda useless in our case since we already buffer small
/// packets sent within the same tick together.
fn setNoDelay(self: *Connection) error{ SocketUnconnected, ConnectionTimedOut, Unexpected }!void {
    const value: [4]u8 = @bitCast(@as(u32, 1));
    while (true) {
        const res = posix.system.setsockopt(
            self.stream_handle,
            posix.IPPROTO.TCP,
            posix.TCP.NODELAY,
            &value,
            value.len,
        );
        return switch (posix.errno(res)) {
            .SUCCESS => {},
            .INTR => continue,
            .PIPE => error.SocketUnconnected,
            .TIMEDOUT => error.ConnectionTimedOut,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(io_r, &data);
    io_w.advance(n);
    return n;
}

fn decryptStream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const state: *ReaderState = @alignCast(@fieldParentPtr("decrypt_reader", io_r));
    const conn: *Connection = @alignCast(@fieldParentPtr("reader_state", state));
    if (limit == .nothing) return 0;

    const reader = &state.reader;

    const dest = try io_w.writableSliceGreedy(1);
    const encrypted = try reader.peekGreedy(1);

    const len = @min(dest.len, encrypted.len, @backingInt(limit));

    conn.lockUncancelable();
    const enc = conn.encryption.?;

    var c_n: c_int = undefined;
    const res = crypto.EVP_DecryptUpdate(
        enc.decrypt.ctx,
        dest.ptr,
        &c_n,
        encrypted.ptr,
        @intCast(len),
    );
    conn.unlock();
    if (res <= 0) {
        state.read_error = error.DecryptionFailed;
        return error.ReadFailed;
    }
    assert(c_n > 0);
    const n: usize = @intCast(c_n);
    io_w.advance(n);
    reader.toss(n);

    return n;
}

fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const max_iovecs_len = 8;

    const state: *ReaderState = @alignCast(@fieldParentPtr("reader", io_r));
    const conn: *Connection = @alignCast(@fieldParentPtr("reader_state", state));
    const io = conn.runtime.io();
    var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
    const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];
    assert(dest[0].len > 0);

    switch (state.state.load(.monotonic)) {
        .waiting, .alive => {},
        .closing, .closed => return error.EndOfStream,
    }

    const n = blk: {
        const res = io.operate(.{ .net_read = .{
            .socket_handle = conn.stream_handle,
            .data = dest,
        } }) catch |err| {
            state.read_error = err;
            return error.ReadFailed;
        };

        const read_res = res.net_read catch |err| {
            state.read_error = err;
            return error.ReadFailed;
        };
        break :blk read_res.data_len;
    };
    if (n == 0) {
        return error.EndOfStream;
    }

    if (n > data_size) {
        io_r.end += n - data_size;
        return data_size;
    }

    return n;
}

fn netWrite(self: *Connection, header: []const u8, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const io = self.runtime.io();

    const n = blk: {
        const res = io.operate(.{ .net_write = .{
            .socket_handle = self.stream_handle,
            .header = header,
            .data = data,
            .splat = splat,
        } }) catch |err| {
            self.writer_state.@"error" = err;
            return error.WriteFailed;
        };

        break :blk res.net_write catch |err| {
            self.writer_state.@"error" = err;
            return error.WriteFailed;
        };
    };
    return self.writer_state.writer.consume(n);
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const state: *WriterState = @alignCast(@fieldParentPtr("writer", io_w));
    switch (state.state.load(.monotonic)) {
        .waiting, .alive => {},
        .closing, .closed => {
            state.@"error" = error.SocketUnconnected;
            return error.WriteFailed;
        },
    }

    const conn: *Connection = @alignCast(@fieldParentPtr("writer_state", state));
    const buffered = io_w.buffered();

    if (conn.encryption) |enc| {
        var total_len: usize = 0;

        var len: c_int = undefined;
        var res = crypto.EVP_EncryptUpdate(
            enc.encrypt.ctx,
            &enc.encrypt.buffer,
            &len,
            buffered.ptr,
            @intCast(buffered.len),
        );
        if (res <= 0) {
            state.@"error" = error.EncryptionFailed;
            return error.WriteFailed;
        }
        total_len += @as(usize, @intCast(len));
        for (data) |d| {
            const available_len = enc.encrypt.buffer.len - total_len;
            if (available_len == 0) break;

            res = crypto.EVP_EncryptUpdate(
                enc.encrypt.ctx,
                @as([*]u8, &enc.encrypt.buffer)[total_len..],
                &len,
                d.ptr,
                @intCast(@min(d.len, available_len)),
            );
            if (res <= 0) {
                state.@"error" = error.EncryptionFailed;
                return error.WriteFailed;
            }
            total_len += @as(usize, @intCast(len));
        }

        return conn.netWrite(enc.encrypt.buffer[0..total_len], &.{""}, 0);
    }

    return conn.netWrite(buffered, data, splat);
}

fn connectionHandler(self: *Connection, allocator: Allocator) Io.Cancelable!void {
    defer {
        self.release(allocator);
        logger.info("Connection handler out", .{});
    }

    self.connectionHandlerInner(allocator) catch |e| switch (e) {
        error.Canceled => {},
        error.ConcurrencyUnavailable => {
            logger.err("[{f}] TODO: Handle concurrency unavailable on connection handler startup", .{self.alt()});
        },
    };
}

fn readEntry(self: *Connection, allocator: Allocator, start_event: *zio.Event) CoroReadError!void {
    defer {
        logger.debug("[{f}] Ended reading", .{self.alt()});
        self.reader_state.state.store(.closed, .monotonic);
        self.shutdown(.recv) catch {}; // tells the os to not accept data in anymore
    }

    start_event.wait() catch return;
    if (self.reader_state.state.cmpxchgStrong(.waiting, .alive, .acquire, .monotonic)) |old| switch (old) {
        else => unreachable, // Dude you can only set to .closing
        .closing => return,
    };

    logger.debug("[{f}] Started reading", .{self.alt()});

    var read_arena = std.heap.ArenaAllocator.init(allocator);
    defer read_arena.deinit();

    while (true) : ({
        if (!read_arena.reset(.{ .retain_with_limit = max_packet_length })) {
            @branchHint(.unlikely);
            logger.warn("[{f}] Failed to reset arena allocator", .{self.alt()});
        }
    }) {
        self.readConnection(allocator, &read_arena) catch |e| {
            const err = megaswitch: switch (e) {
                error.ReadFailed => if (self.reader_state.read_error) |rerr| switch (rerr) {
                    error.AccessDenied, error.Unexpected => unreachable,
                    error.Canceled => continue :megaswitch error.Canceled,
                    error.SocketUnconnected,
                    error.NetworkDown,
                    error.SystemResources,
                    error.ConnectionResetByPeer,
                    error.ConnectionTimedOut,
                    error.DecryptionFailed,
                    => |err| err,
                } else error.CallbackHandlerFailed,
                error.Canceled, error.EndOfStream => switch (self.reader_state.state.load(.monotonic)) {
                    .waiting, .alive => error.EndOfStream,
                    .closing, .closed => error.Disconnected,
                },
                error.Disconnected,
                error.CallbackHandlerFailed,
                error.DecompressionFailed,
                error.LegacyHandshake,
                error.PacketTooSmall,
                error.PacketTooLarge,
                error.InvalidLength,
                error.InvalidPacketID,
                error.OutOfMemory,
                => |err| err,
            };
            if (err == error.Disconnected) break;
            logger.debug("[{f}] Error while reading: {t}", .{ self.alt(), err });
            return err;
        };
    }
}

fn writeEntry(self: *Connection, allocator: Allocator, start_event: *zio.Event) CoroWriteError!void {
    defer {
        logger.debug("[{f}] Ended writing", .{self.alt()});
        self.send_state.channel.close(.graceful);
        self.writer_state.state.store(.closed, .monotonic);
        self.shutdown(.send) catch {};
    }

    start_event.wait() catch return;
    if (self.writer_state.state.cmpxchgStrong(.waiting, .alive, .acquire, .monotonic)) |old| switch (old) {
        else => unreachable, // Dude you can only set to .closing
        .closing => return,
    };

    logger.debug("[{f}] Started writing", .{self.alt()});

    while (true) {
        self.writeConnection(allocator) catch |e| {
            const err = switch (e) {
                error.WriteFailed => switch (self.writer_state.@"error".?) {
                    error.AddressFamilyUnsupported, error.Unexpected, error.FastOpenAlreadyInProgress, error.Canceled => unreachable,
                    error.SocketUnconnected => |err| switch (self.writer_state.state.load(.monotonic)) {
                        .waiting, .alive => err,
                        .closing, .closed => error.Disconnected,
                    },
                    error.NetworkUnreachable,
                    error.NetworkDown,
                    error.ConnectionRefused,
                    error.SocketNotBound,
                    error.HostUnreachable,
                    error.ConnectionTimedOut,
                    error.ConnectionResetByPeer,
                    error.SystemResources,
                    error.EncryptionFailed,
                    => |err| err,
                },
                error.Canceled, error.Disconnected => error.Disconnected,
            };
            if (err == error.Disconnected) break;
            return err;
        };
    }
}

fn tickEntry(self: *Connection, allocator: Allocator, start_event: *zio.Event) TickError!void {
    defer {
        logger.debug("[{f}] Ended ticking", .{self.alt()});
        self.disconnect(.{ .static = &.disconnect_generic });
    }

    try start_event.wait();

    logger.debug("[{f}] Started ticking", .{self.alt()});

    const io = self.runtime.io();
    // TODO: Tick synchronization
    while (io.sleep(.fromMilliseconds(50), .boot)) {
        try self.lock();
        defer self.unlock();

        self.tick() catch |e| return switch (e) {
            error.Canceled => break,
            error.OutOfMemory, error.SystemResources => |err| err,
            else => |err| {
                if (err != error.Disconnected) {
                    var buf: [100]u8 = undefined;
                    var w = Io.Writer.fixed(&buf);
                    w.print("Error on connection tick: {t}", .{e}) catch {};
                    self.disconnect(.{ .copied = .{
                        allocator, &.text(w.buffered(), .{}),
                    } });
                }
                break;
            },
        };
    } else |_| {}
}

fn connectionHandlerInner(self: *Connection, allocator: Allocator) !void {
    const io = self.runtime.io();

    var start_ev = zio.Event.init;
    var res_buf: [3]HandlerSelectResult = undefined;
    var select = Io.Select(HandlerSelectResult).init(io, &res_buf);
    errdefer select.cancelDiscard();

    try select.concurrent(.read, readEntry, .{ self, allocator, &start_ev });
    try select.concurrent(.write, writeEntry, .{ self, allocator, &start_ev });
    try select.concurrent(.tick, tickEntry, .{ self, allocator, &start_ev });

    try self.start.wait();

    start_ev.set();

    var res: ?HandlerSelectResult = select.await() catch select.cancel().?;

    if (res.? == .read and res.?.read == error.LegacyHandshake) {
        self.disconnect(.{ .static = comptime &.text("LegacyHandshake", .{}) });
    }

    while (res) |result| : (res = select.cancel()) {
        switch (result) {
            inline else => |value, tag| logger.debug("[{f}] Result on {t}: {!}", .{ self.alt(), tag, value }),
        }
    }
}

fn readConnection(self: *Connection, gpa: Allocator, arena_alloc: *std.heap.ArenaAllocator) !void {
    const arena = arena_alloc.allocator();
    var rparams = ReadParams{
        .gpa = gpa,
        .arena = arena_alloc,
        .input_mode = .full,
    };

    const reader = if (self.encryption != null) &self.reader_state.decrypt_reader else &self.reader_state.reader;
    const next_byte = reader.peekByte() catch |e| return switch (e) {
        error.ReadFailed => |err| err,
        error.EndOfStream => {
            self.disconnect(.normal);
            return error.Disconnected;
        },
    };

    {
        try self.lock();
        defer self.unlock();

        if (self.in_phase == .handshake and next_byte == 0xFE) { // legacy handshake
            return error.LegacyHandshake;
        }
    }

    const packet_length: i32 = PacketType.readNoAlloc(.var_int, reader) catch |e| switch (e) {
        error.Overflow => return error.PacketTooLarge,
        error.EndOfStream, error.ReadFailed => |err| return err,
        else => unreachable,
    };
    // std.log.debug("[{f}] Got packet length: {d}", .{ self.alt(), packet_length });
    if (packet_length <= 0) return error.PacketTooSmall;
    if (packet_length > max_packet_length) return error.PacketTooLarge;
    const length: usize = @intCast(packet_length);
    const packet_bytes = try if (reader.buffer.len >= length)
        reader.take(length)
    else
        reader.readAlloc(arena, length);
    // std.debug.dumpHex(packet_bytes);

    var raw_reader = Io.Reader.fixed(packet_bytes);
    var decomp: flate.Decompress = undefined;

    const packet_reader = if (self.compression) |comp| blk: {
        @branchHint(.likely);

        const uncompressed_length = PacketType.readNoAlloc(.var_int, &raw_reader) catch |e| return switch (e) {
            error.Overflow, error.EndOfStream => error.InvalidLength,
            else => unreachable,
        };
        if (uncompressed_length < 0) return error.InvalidLength;
        if (uncompressed_length == 0) {
            @branchHint(.unlikely);
            break :blk &raw_reader;
        }
        if (uncompressed_length > max_uncompressed_packet_length) return error.PacketTooLarge;
        rparams.input_mode = .streamed;

        decomp = .init(&raw_reader, .zlib, &comp.decompression.buffer);
        break :blk &decomp.reader;
    } else &raw_reader;

    const packet_id = PacketType.readNoAlloc(.var_int, packet_reader) catch |e| return switch (e) {
        error.Overflow => error.InvalidPacketID,
        error.EndOfStream => error.InvalidLength,
        error.ReadFailed => {
            self.compression.?.decompression.@"error" = decomp.err;
            return error.DecompressionFailed;
        },
        else => unreachable,
    };
    self.lockUncancelable();
    defer self.unlock();

    self.addReadPacket();

    const curr_side = self.target_side.opposite();
    const pid = self.packet_registry.getPacketID(curr_side, self.in_phase, packet_id) orelse {
        var buf: [100]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        w.print("Couldn't read packet: Unknown packet id: {t}#{d}", .{ self.in_phase, packet_id }) catch {};
        self.disconnect(.{ .copied = .{
            gpa, &.text(w.buffered(), .{}),
        } });
        return error.InvalidPacketID;
    };
    const entry = self.packet_registry.getEntry(curr_side, self.in_phase, pid);
    // logger.debug("  - Packet resource: {t}bound/{t}/{s} (id: 0x{x:0>2})", .{ curr_side, self.in_phase, entry.resource, pid });

    const pkcb = entry.callback orelse {
        // at least 79 characters required + the size of the resource string so
        // 100 seems nice
        var buf: [100]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        w.print("Couldn't read packet: \"{t}bound/{t}/{s}\" (id: 0x{x:0>2}): Work In Progress", .{
            curr_side, self.in_phase, entry.resource, pid,
        }) catch {};
        self.disconnect(.{ .copied = .{
            gpa, &.text(w.buffered(), .{}),
        } });
        return error.InvalidPacketID;
    };

    pkcb(self, packet_reader, rparams) catch |e| {
        const err = switch (e) {
            error.ReadFailed => {
                self.compression.?.decompression.@"error" = decomp.err;
                return error.DecompressionFailed;
            },
            error.CallbackHandlerFailed, error.OutOfMemory, error.EndOfStream => |err| err,
            else => error.ReadFailed,
        };
        self.reader_state.handler_error = err;
        return err;
    };
    if (raw_reader.end != length or packet_reader.bufferedLen() != 0) return error.PacketTooLarge;
}

fn writeConnection(self: *Connection, allocator: Allocator) !void {
    const writer = &self.writer_state.writer;

    var pnode: ?*Packet = self.send_state.channel.receive() catch |e| switch (e) {
        error.Canceled => |err| return err,
        error.Closed => return error.Disconnected,
    };
    while (pnode) |packet| : (pnode = self.send_state.channel.tryReceive() catch null) {
        defer allocator.free(packet.getBytes());
        const bytes = packet.getData();

        assert(bytes.len <= max_packet_length);

        // logger.debug("[{f}] Sending packet: {Bi}", .{ self.alt(), bytes.len });
        // std.debug.dumpHex(bytes);

        PacketType.writerNoAlloc(.var_int, writer, @intCast(bytes.len)) catch |e| switch (e) {
            error.WriteFailed => |err| return err,
            else => unreachable,
        };
        try writer.writeAll(bytes);
        self.addWritePacket();
    }

    zio.beginShield();
    defer zio.endShield();

    try writer.flush();
}

fn addReadPacket(self: *Connection) void {
    self.reader_state.last_packet_timestamp = Io.Timestamp.now(std.Options.debug_io, .boot);

    if (self.rate_limited.load(.monotonic)) |rl| {
        _ = rl.received.fetchAdd(1, .monotonic);
    }
}

fn addWritePacket(self: *Connection) void {
    if (self.rate_limited.load(.monotonic)) |rl| {
        _ = rl.sent.fetchAdd(1, .monotonic);
    }
}

/// Handshake and Status don't have this.
fn noDisconnectMessage(self: *Connection, reason: *const TextComponent) Allocator.Error!void {
    _ = self;
    _ = reason;
}

fn noDeinit(self: *Connection, allocator: Allocator) void {
    _ = self;
    _ = allocator;
}

fn noTick(self: *Connection, delta: u8) TickError!void {
    _ = self;
    _ = delta;
}

fn deinit(self: *Connection, allocator: Allocator) void {
    logger.debug("Destroying {f}", .{self.altLocked()});
    const io = self.runtime.io();

    io.vtable.netClose(io.userdata, (&self.getSocket())[0..1]);
    self.send_state.channel.close(.graceful);
    while (self.send_state.channel.tryReceive()) |packet| {
        allocator.free(packet.getBytes());
    } else |_| {}
    switch (self.disconnection_reason) {
        .none => logger.err("[{f}] Disconnected", .{self.altLocked()}),
        .normal => logger.info("[{f}] Disconnected", .{self.altLocked()}),
        .reason => |tc| {
            logger.err("[{f}] Disconnected: {f}", .{ self.altLocked(), tc });
            tc.deinit(allocator);
        },
    }

    self.vtable.deinit(self, allocator);
}

// TODO: Read timeout
// TODO: Bandwidth monitor ?

// NOTE: Big fat note which I don't know were to place:
// NOTE: - Read/Write/Tick can all lock the connection.
// NOTE: - Both Read and Write need it for rate limiting. Might need to use atomics instead.
// TODO: Make so that write doesn't need connection lock. So sendPacket() doesn't require the `conn` to be
// TODO: unlocked.

packet_registry: *const PacketRegistry,
stream_handle: Io.net.Socket.Handle,
ip_address: Io.net.IpAddress,
runtime: *zio.Runtime,

mutex: zio.Mutex.Recursive,
refcount: core.RefCount,
start: zio.Event,

//#region Shared members
/// Will replace the ip when this connection gets formatted to the console.
name: ?[]const u8 = null,
vtable: *const VTable,

in_phase: NetworkingPhase,
out_phase: NetworkingPhase,
target_side: NetworkingSide,

rate_limited: Atomic(?*RateLimited),
compression: ?*Compression,
encryption: ?*Encryption,
timeout: Io.Duration,

tick_count: u8,
disconnection_reason: union(enum) { none, normal, reason: TextComponent },
//#endregion

reader_state: ReaderState,
writer_state: WriterState,

send_state: struct {
    _: void align(cache_line_size) = {},

    buffer: [128]*Packet,
    channel: zio.Channel(*Packet),
},

/// Maximum value of `u21`, roughly 2MiB
pub const max_packet_length = (2 * 1024 * 1024) - 1;
pub const max_uncompressed_packet_length = 8 * 1024 * 1024;

pub const CoroReadError = error{
    SystemResources,
    ConnectionResetByPeer,
    LegacyHandshake,
    PacketTooSmall,
    PacketTooLarge,
    EndOfStream,
    InvalidPacketID,
    OutOfMemory,
    Disconnected,
    ConnectionTimedOut,
    InvalidLength,
    DecompressionFailed,
    DecryptionFailed,
    CallbackHandlerFailed,
    SocketUnconnected,
    NetworkDown,
    HostUnreachable,
};
pub const CoroWriteError = error{
    Disconnected,
    ConnectionResetByPeer,
    SystemResources,
    ConnectionTimedOut,
    EncryptionFailed,
    SocketUnconnected,
    NetworkDown,
    NetworkUnreachable,
    ConnectionRefused,
    SocketNotBound,
    HostUnreachable,
};
pub const StreamReadError = Io.net.Stream.Reader.Error || error{DecryptionFailed};
pub const StreamWriteError = Io.net.Stream.Writer.Error || error{EncryptionFailed};
pub const InitError = Io.ConcurrentError || Allocator.Error || error{ SocketUnconnected, ConnectionTimedOut, Unexpected };

pub const ReadCallbackError = PacketType.ReadError || WritePacketError || Io.net.ShutdownError || Io.ConcurrentError || error{CallbackHandlerFailed};
pub const WritePacketError = Io.Cancelable || Allocator.Error || PacketType.WriteError || error{
    PacketIDNotFound,
    PacketTooLarge,
    ConnectionClosed,
};
pub const TickError = Io.Cancelable || Allocator.Error || Io.net.ShutdownError || WritePacketError;
pub const SetEncryptionError = error{SetupFailed};

/// The data in `reader` will never move, as such the `StructuredPacket` API is useable with it.
///
/// The memory allocated by the arena allocator passed in this function will only stay valid for this call
/// **only**. Any data that is wished to stay persitent must be copied to a new location.
pub const ReadCallbackFn = fn (conn: *Connection, reader: *Io.Reader, params: ReadParams) ReadCallbackError!void;
pub const DisconnectCallbackFn = fn (conn: *Connection, reason: *const TextComponent) WritePacketError!void;
pub const DeinitCallbackFn = fn (conn: *Connection, allocator: Allocator) void;
pub const TickCallbackFn = fn (conn: *Connection, delta: u8) TickError!void;

pub const RateLimited = struct {
    received: Atomic(Count) align(cache_line_size) = .init(0),
    sent: Atomic(Count) align(cache_line_size) = .init(0),

    /// Constant value.
    limit: Count,

    average_received: Average = 0,
    average_sent: Average = 0,

    pub const Average = f32;
    pub const Count = usize;

    /// Sugar function.
    ///
    /// Allows you to init and return this pointer in a single line.
    pub inline fn init(self: *RateLimited, limit: Count) *RateLimited {
        self.* = .{ .limit = limit };
        return self;
    }
};

pub const Compression = struct {
    /// Data is always locked by the parent `Connection`.
    fn getCompressionBuffer(self: *Compression, allocator: Allocator) Allocator.Error!*[flate.max_window_len]u8 {
        var it = self.compression.mask.iterator(.{ .kind = .unset });
        if (it.next()) |idx| {
            // Mark it as used, `redeemCompressionBuffer` only looks at used buffers
            self.compression.mask.set(idx);
            return self.compression.buffers[idx];
        }

        const old_len = self.compression.mask.bit_length;
        try self.compression.mask.resize(allocator, old_len + 1, false);
        errdefer self.compression.mask.resize(.failing, old_len, false) catch unreachable;

        if (self.compression.buffers.len < (old_len + 1)) {
            self.compression.buffers = try allocator.realloc(self.compression.buffers, old_len + 1);
        }

        var aa = self.compression.state.promote(allocator);
        defer self.compression.state = aa.state;

        const new_buffer = try aa.allocator().create([flate.max_window_len]u8);

        self.compression.mask.set(old_len);
        self.compression.buffers[old_len] = new_buffer;
        return new_buffer;
    }

    /// Data is always locked by the parent `Connection`.
    fn redeemCompressionBuffer(self: *Compression, buf: *[flate.max_window_len]u8) void {
        var it = self.compression.mask.iterator(.{});
        while (it.next()) |idx| {
            const current = self.compression.buffers[idx];
            if (current == buf) {
                self.compression.mask.unset(idx);
                return;
            }
        }

        std.debug.panic("Invalid buffer: {*}", .{buf});
    }

    threshold: usize,
    decompression: struct {
        _: void align(cache_line_size) = {},
        @"error": ?flate.Decompress.Error,
        buffer: [flate.max_window_len]u8,
    },
    /// Data is always locked by the parent `Connection`.
    compression: struct {
        _: void align(cache_line_size) = {},
        mask: std.bit_set.Dynamic,
        state: std.heap.ArenaAllocator.State,
        buffers: []*[flate.max_window_len]u8,
    },

    pub fn init(self: *Compression, allocator: Allocator, threshold: usize, compress_buffers: usize) Allocator.Error!void {
        self.* = .{
            .threshold = threshold,
            .decompression = .{
                .@"error" = null,
                .buffer = undefined,
            },
            .compression = .{
                .mask = .{},
                .state = .init,
                .buffers = &.{},
            },
        };
        try self.compression.mask.resize(allocator, compress_buffers, false);
        errdefer self.compression.mask.deinit(allocator);

        self.compression.buffers = try allocator.alloc(*[flate.max_window_len]u8, compress_buffers);
        errdefer allocator.free(self.compression.buffers);

        var aa = self.compression.state.promote(allocator);
        errdefer aa.deinit();

        const arena = aa.allocator();
        const data = try arena.alloc(u8, compress_buffers * flate.max_window_len);
        for (self.compression.buffers, 0..) |*buf, i| {
            buf.* = data[i * flate.max_window_len ..][0..flate.max_window_len];
        }

        self.compression.state = aa.state;
    }

    pub fn deinit(self: *Compression, allocator: Allocator) void {
        self.compression.state.promote(allocator).deinit();
        self.compression.mask.deinit(allocator);
        allocator.free(self.compression.buffers);
    }
};

pub const Encryption = struct {
    shared_secret: [16]u8,

    encrypt: struct {
        _: void align(cache_line_size) = {},
        ctx: *crypto.EVP_CIPHER_CTX,
        buffer: [reader_buffer_size]u8,
    },
    decrypt: struct {
        _: void align(cache_line_size) = {},
        ctx: *crypto.EVP_CIPHER_CTX,
        // Should have more bytes, but AES128/CFB8 doesn't buffer, so encryption and decryption is
        // N bytes for N bytes
        buffer: [writer_buffer_size]u8,
    },

    pub fn init(self: *Encryption, shared_secret_src: union(enum) { random_secret: std.Random, fixed_secret }) SetEncryptionError!void {
        self.encrypt.ctx = crypto.EVP_CIPHER_CTX_new() orelse return error.SetupFailed;
        errdefer crypto.EVP_CIPHER_CTX_free(self.encrypt.ctx);

        self.decrypt.ctx = crypto.EVP_CIPHER_CTX_new() orelse return error.SetupFailed;
        errdefer crypto.EVP_CIPHER_CTX_free(self.decrypt.ctx);

        if (shared_secret_src == .random_secret) {
            shared_secret_src.random_secret.bytes(&self.shared_secret);
        }

        const cipher = crypto.EVP_aes_128_cfb8().?;

        var res = crypto.EVP_EncryptInit_ex(
            self.encrypt.ctx,
            cipher,
            null,
            &self.shared_secret,
            &self.shared_secret,
        );
        if (res == 0) return error.SetupFailed;
        res = crypto.EVP_DecryptInit_ex(
            self.decrypt.ctx,
            cipher,
            null,
            &self.shared_secret,
            &self.shared_secret,
        );
        if (res == 0) return error.SetupFailed;
    }

    pub fn deinit(self: *Encryption) void {
        crypto.EVP_CIPHER_CTX_free(self.encrypt.ctx);
        crypto.EVP_CIPHER_CTX_free(self.decrypt.ctx);
    }
};

pub const InitOptions = struct {
    /// The packet registry used to callback function to read and
    /// handle incomming packets.
    packet_registry: *const PacketRegistry,
    runtime: *zio.Runtime,
    stream: Io.net.Stream,
    /// Whether the other end of this connection will be a server or
    /// client.
    target_side: NetworkingSide,
    /// Optional name of this connection to be logged.
    ///
    /// If `null` the ip of the other end of the connection will be
    /// printed instead.
    name: ?[]const u8 = null,
    /// I figured this could be useful if one (for example), makes a plugin/mod/whatever
    /// that automatically reconnect players in a certain phase.
    in_phase: NetworkingPhase = .handshake,
    /// I figured this could be useful if one (for example), makes a plugin/mod/whatever
    /// that automatically reconnect players in a certain phase.
    out_phase: NetworkingPhase = .handshake,
    /// Sets a timeout on the reading end, if exceeded it automatically
    /// closes the connection.
    timeout: Io.Duration = .fromSeconds(30),
    /// Include `RateLimited` within your implementation struct
    /// and pass it here or in `reconfigure()` to limit packet
    /// rate.
    rate_limited: ?*RateLimited = null,
    /// Defaults with a callback that does nothing.
    vtable: *const VTable = &.{},
    compression: ?*Compression = null,
    encryption: ?*Encryption = null,
};

pub const ReconfigureOptions = struct {
    fn empty(self: ReconfigureOptions) bool {
        const info = @typeInfo(ReconfigureOptions).@"struct";
        inline for (info.field_names, info.field_types) |fname, ftype| {
            comptime if (@typeInfo(ftype) != .optional) continue;
            if (@field(self, fname) != null) return false;
        }
        return true;
    }

    name: ?[]const u8 = null,
    in_phase: ?NetworkingPhase = null,
    out_phase: ?NetworkingPhase = null,
    timeout: ?Io.Duration = null,
    rate_limited: ?*RateLimited = null,
    vtable: ?*const VTable = null,
    compression: ?*Compression = null,
    encryption: ?*Encryption = null,
};

pub const HashContext = struct {
    pub fn hash(_: HashContext, v: *Connection) u64 {
        var wh = std.hash.Wyhash.init(0);
        wh.update(@ptrCast(&v.ip_address));
        return wh.final();
    }

    pub fn eql(_: HashContext, a: *Connection, b: *Connection) bool {
        return a == b or a.ip_address.eql(&b.ip_address);
    }
};

pub const VTable = struct {
    /// Called when the server needs to inform the client why they're getting disconnected.
    /// 
    /// Only called once.
    disconnect: *const DisconnectCallbackFn = noDisconnectMessage,
    /// Called once work with the `Connection` is done, so that the implementation can free its data.
    deinit: *const DeinitCallbackFn = noDeinit,
    /// Called every ~50ms.
    tick: *const TickCallbackFn = noTick,
};

pub const Alt = struct {
    ptr: *Connection,
    do_unlock: bool = true,

    pub fn format(_alt: Alt, writer: *Io.Writer) Io.Writer.Error!void {
        const self = _alt.ptr;
        defer if (_alt.do_unlock) self.unlock();

        try if (self.name) |nm|
            writer.writeAll(nm)
        else
            self.ip_address.format(writer);
        if (self.in_phase == self.out_phase) {
            try writer.print("({t})->{t}", .{ self.in_phase, self.target_side });
        } else {
            try writer.print("({t})->{t}({t})", .{ self.in_phase, self.target_side, self.out_phase });
        }
    }
};

pub const DisconnectReason = union(enum) {
    normal,
    static: *const TextComponent,
    copied: struct { Allocator, *const TextComponent },
};

/// `allocator` must remain valid until this connection is deinitalized
pub fn init(self: *Connection, allocator: Allocator, group: *Io.Group, options: InitOptions) InitError!void {
    self.* = .{
        .stream_handle = options.stream.socket.handle,
        .ip_address = options.stream.socket.address,
        .runtime = options.runtime,

        .mutex = .init,
        .refcount = .{},
        .start = .init,

        .packet_registry = options.packet_registry,
        .name = options.name,
        .vtable = options.vtable,

        .in_phase = options.in_phase,
        .out_phase = options.out_phase,
        .target_side = options.target_side,

        .rate_limited = .init(options.rate_limited),
        .encryption = options.encryption,
        .compression = options.compression,
        .timeout = options.timeout,

        .tick_count = 0,
        .disconnection_reason = .none,

        .reader_state = .{
            .state = .init(.waiting),
            .buffer = undefined,
            .reader = .{
                .vtable = &reader_vtable,
                .buffer = &self.reader_state.buffer,
                .seek = 0,
                .end = 0,
            },
            .decrypt_reader = if (options.encryption) |enc| .{
                .buffer = &enc.encrypt.buffer,
                .vtable = &decrypt_reader_vtable,
                .seek = 0,
                .end = 0,
            } else .failing,
            .read_error = null,
            .handler_error = null,
            .last_packet_timestamp = Io.Timestamp.now(std.Options.debug_io, .boot),
        },

        .writer_state = .{
            .state = .init(.waiting),
            .buffer = undefined,
            .writer = .{
                .vtable = &writer_vtable,
                .buffer = &self.writer_state.buffer,
                .end = 0,
            },
            .@"error" = null,
        },

        .send_state = .{
            .buffer = undefined,
            .channel = .init(&self.send_state.buffer),
        },
    };
    try self.setNoDelay();
    const io = self.runtime.io();

    try group.concurrent(io, connectionHandler, .{ self.acquire(), allocator });
}

pub fn acquire(self: *Connection) *Connection {
    // freezes, thanks bro
    // var buf: [4]usize = undefined;
    // const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &buf);
    // logger.debug("{d} frames, {d} skipped", .{ st.return_addresses.len, st.skipped });
    // logger.debug("acquire at: {f}", .{std.debug.FormatStackTrace{ .stack_trace = st, .terminal_mode = .escape_codes }});
    self.refcount.acquire();
    return self;
}

pub fn release(self: *Connection, allocator: Allocator) void {
    // var buf: [4]usize = undefined;
    // const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &buf);
    // logger.debug("{d} frames, {d} skipped", .{ st.return_addresses.len, st.skipped });
    // logger.debug("acquire at: {f}", .{std.debug.FormatStackTrace{ .stack_trace = st, .terminal_mode = .escape_codes }});
    if (self.refcount.release()) {
        assert(self.tryLock()); // Nice lifetimes management bro...
        self.deinit(allocator);
    }
}

pub fn lock(self: *Connection) Io.Cancelable!void {
    return self.mutex.lock();
}

pub fn lockUncancelable(self: *Connection) void {
    return self.mutex.lockUncancelable();
}

pub fn tryLock(self: *Connection) bool {
    return self.mutex.tryLock();
}

pub fn unlock(self: *Connection) void {
    return self.mutex.unlock();
}

pub fn disconnect(self: *Connection, reason: DisconnectReason) void {
    self.lockUncancelable();
    defer self.unlock();

    if (self.disconnection_reason != .none) return;
    switch (self.writer_state.state.load(.monotonic)) {
        .alive, .waiting => {
            self.vtable.disconnect(self, switch (reason) {
                .normal => &TextComponent.disconnect_generic,
                .static => |tc| tc,
                .copied => |p| p[1],
            }) catch {};
            self.shutdown(.recv) catch {};
        },
        .closing, .closed => {},
    }
    self.disconnection_reason = switch (reason) {
        .normal => .normal,
        .static => |tc| .{ .reason = tc.* },
        .copied => |p| .{ .reason = p[1].clone(p[0]) catch TextComponent.disconnect_generic },
    };
    // more than one second of timeout is useless
    self.timeout = .fromSeconds(1);
}

/// Doesn't reallocate/duplicate anything.
///
/// Asserts that `options` actually does stuff, otherwise this might
/// mean a bad design.
pub fn reconfigure(self: *Connection, options: ReconfigureOptions) void {
    assert(!options.empty()); // Pointless reconfigure

    self.lockUncancelable();
    defer self.unlock();

    self.name = self.name orelse options.name;
    if (options.in_phase) |p| self.in_phase = p;
    if (options.out_phase) |p| self.out_phase = p;
    if (options.timeout) |to| self.timeout = to;
    if (options.rate_limited) |rl| self.rate_limited.store(rl, .monotonic);
    if (options.vtable) |cb| self.vtable = cb;
    if (options.compression) |c| self.compression = c;
    if (options.encryption) |c| {
        self.encryption = c;
        self.reader_state.decrypt_reader = .{
            .buffer = &c.decrypt.buffer,
            .vtable = &decrypt_reader_vtable,
            .seek = 0,
            .end = 0,
        };
    }
}

/// Directly calling `format()` on a `Connection` is now deprecated in favor of `.alt()`
/// or `.altLocked()`
pub fn format(self: *Connection, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = self;
    _ = writer;
    @compileError("Directly calling 'format()' on a Connection is now deprecated in favor of 'alt()'" ++
        " or 'altLocked()'");
}

/// Allows this connection to be printed to `std.Io.Writer`s as: `[ip-or-name]<[phase]>->[target-side]`
/// (excluding `[]`s).
///
/// The function all will also call `.lock()` and once the value is printed, `.unlock()` will be called.
///
/// If you wish to reuse the format argument, consider using `.altReusable(n)` instead.
///
/// Or lock the connection yourself and use `.altLocked()` once.
pub fn alt(self: *Connection) Alt {
    return self.altReusable(1);
}

/// Allows this connection to be printed to `std.Io.Writer`s as: `[ip-or-name]<[phase]>->[target-side]`
/// (excluding `[]`s).
///
/// The function all will also call `.lock()` `lock_count` tules and once a value is printed, `.unlock()` will be called once.
///
/// Use this if you wish to reuse the format argument.
pub fn altReusable(self: *Connection, lock_count: usize) Alt {
    for (0..lock_count) |_| self.lockUncancelable();
    return .{ .ptr = self };
}

/// Allows this connection to be printed to `std.Io.Writer`s as: `[ip-or-name]<[phase]>->[target-side]`
/// (excluding `[]`s).
///
/// The function assumes `self` to be already locked.
pub fn altLocked(self: *Connection) Alt {
    return .{ .ptr = self, .do_unlock = false };
}

/// Needs `self` to be unlocked, otherwise may cause a deadlock when a lot of packets get sent at once.
/// TODO: Remove the lock requirement in writeConnection() in favor of atomics.
/// TODO: Batched packet sending to optimize the use of locking and stuff idk
pub fn sendPacket(
    self: *Connection,
    apair: AllocPair,
    resource: []const u8,
    comptime @"type": PacketType,
    value: @"type".getZigType(),
) WritePacketError!void {
    switch (self.writer_state.state.load(.monotonic)) {
        .waiting, .alive => {},
        .closing, .closed => return error.ConnectionClosed,
    }

    const pack_id, const entry = blk: {
        try self.lock();
        defer self.unlock();

        const pack_id = self.packet_registry.packedIDFromResource(self.target_side, self.out_phase, resource) orelse
            return error.PacketIDNotFound;
        const entry = self.packet_registry.getEntry(self.target_side, self.out_phase, pack_id);

        break :blk .{ pack_id, entry };
    };

    // logger.debug("Sending packet {s} (id: {x})", .{ resource, pack_id });
    var aw = Io.Writer.Allocating.initAligned(apair.gpa, .of(Packet));
    defer aw.deinit();
    // logger.debug("Sending packet {s} (id: {x}) (aw init)", .{ resource, pack_id });
    try aw.ensureTotalCapacity(@sizeOf(Packet) + 1 + entry.write_cushion);
    aw.writer.advance(@sizeOf(Packet));
    // logger.debug("Sending packet {s} (id: {x}) (aw prealloc)", .{ resource, pack_id });

    PacketType.writerNoAlloc(.var_int, &aw.writer, @backingInt(pack_id)) catch return error.OutOfMemory;

    @"type".write(apair, &aw.writer, value) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |err| err,
    };
    // logger.debug("Sending packet {s} (id: {x}) (serialized packet)", .{ resource, pack_id });

    var compressed = false;
    const bytes_result: []align(@alignOf(Packet)) u8 = res: {
        const content = aw.written()[@sizeOf(Packet)..];

        self.lockUncancelable();
        if (self.compression) |comp| {
            @branchHint(.likely);
            self.unlock();

            var out_w = Io.Writer.Allocating.initAligned(apair.gpa, .of(Packet));
            defer out_w.deinit();
            try out_w.ensureTotalCapacity(@sizeOf(Packet) + 1 + content.len);
            out_w.writer.advance(@sizeOf(Packet));

            if (content.len < comp.threshold) {
                // logger.debug("Sending packet {s} (id: {x}) (uncompressed header)", .{ resource, pack_id });
                PacketType.writerNoAlloc(.var_int, &out_w.writer, 0) catch unreachable;
                out_w.writer.writeAll(content) catch unreachable;
            } else {
                @branchHint(.likely);
                // logger.debug("Sending packet {s} (id: {x}) (compressed header)", .{ resource, pack_id });

                if (content.len > max_uncompressed_packet_length) return error.PacketTooLarge;

                const buffer = try comp.getCompressionBuffer(apair.gpa);
                defer comp.redeemCompressionBuffer(buffer);

                PacketType.writerNoAlloc(.var_int, &out_w.writer, @intCast(content.len)) catch unreachable;
                var compress = flate.Compress.init(&out_w.writer, buffer, .zlib, .default) catch
                    return error.OutOfMemory;

                // Split compression into chunks of X bytes to potentially allow other
                // tasks to run.
                const chunk_size = 1024;
                var offset: usize = 0;
                while (offset < content.len) {
                    const remaining = content.len - offset;
                    const size = @min(chunk_size, remaining);
                    const n = compress.writer.write(content[offset .. offset + size]) catch return error.OutOfMemory;
                    offset += n;
                    try zio.maybeYield();
                }

                compress.finish() catch return error.OutOfMemory;
                compressed = true;
            }

            break :res @alignCast(try out_w.toOwnedSlice());
        } else self.unlock();

        break :res @alignCast(try aw.toOwnedSlice());
    };
    errdefer apair.gpa.free(bytes_result);
    // logger.debug("Sending packet {s} (id: {x}) ({d} bytes{s})", .{
    //     resource,         pack_id,
    //     bytes_result.len, if (compressed) ", compressed" else "",
    // });

    const payload_len = bytes_result.len - @sizeOf(Packet);
    if (payload_len > max_packet_length) return error.PacketTooLarge;

    const pnode: *Packet = @ptrCast(@alignCast(bytes_result.ptr));
    pnode.* = .{ .length = payload_len };

    self.send_state.channel.send(pnode) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => {
            apair.gpa.free(bytes_result);
            return error.ConnectionClosed;
        },
    };
}

pub fn shutdown(self: *Connection, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    const io = self.runtime.io();

    if (how != .send) { // recv or both
        self.reader_state.state.store(.closing, .monotonic);
    }
    if (how != .recv) { // send or both
        self.writer_state.state.store(.closing, .monotonic);
    }

    try io.vtable.netShutdown(io.userdata, self.stream_handle, how);
}

/// Assumes `self` to be locked.
pub fn tick(self: *Connection) TickError!void {
    // logger.debug("[{f}] Ticking", .{self.altLocked()});

    const delta = self.tick_count;
    self.tick_count = (self.tick_count + 1) % 20;

    if (delta == 0) {
        if (self.rate_limited.load(.monotonic)) |rl| {
            const sent: RateLimited.Average =  @floatFromInt(rl.sent.swap(0, .monotonic));
            const received: RateLimited.Average =  @floatFromInt(rl.received.swap(0, .monotonic));

            rl.average_sent = lm.lerp(RateLimited.Average, sent, rl.average_sent, 0.75);
            rl.average_received = lm.lerp(RateLimited.Average, received, rl.average_received, 0.75);
            
            if (@as(RateLimited.Count, @trunc(rl.average_received)) >= rl.limit) {
                logger.warn("[{f}] Exceeded rate-limit (sent {d} packets per seconds)", .{ self.altLocked(), rl.average_received });
                self.disconnect(.{ .static = &.exceeded_packet_rate });
            }
        }
    }

    try self.vtable.tick(self, delta);
}

pub fn getSocket(self: *Connection) Io.net.Socket {
    return .{ .handle = self.stream_handle, .address = self.ip_address };
}

test {
    inline for (comptime std.meta.declarations(@This())) |decl_name| {
        // fuck you bro :sob:
        if (comptime std.mem.eql(u8, decl_name, "format")) continue;
        _ = &@field(@This(), decl_name);
    }
    std.testing.refAllDecls(Packet);
    std.testing.refAllDecls(RateLimited);
    std.testing.refAllDecls(Compression);
    std.testing.refAllDecls(Encryption);
}
