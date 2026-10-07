//! An intrusive interface (like `std.Io.Reader/Writer`) that handles all the operations related to a
//! minecraft connection in either way. Use `.init()` to initalize it with specific options.
//!
//! TODO: doc
const Connection = @This();
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const coro = @import("coro");
const zio = @import("zio");
const utils = @import("utils");
const crypto = @import("crypto");
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
const math = std.math;

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

const Packet = struct {
    length: usize,

    fn getBytes(self: *Packet) []align(@alignOf(Packet)) const u8 {
        return @as([*]align(@alignOf(Packet)) const u8, @ptrCast(self))[0 .. @sizeOf(Packet) + self.length];
    }

    fn getData(self: *Packet) []const u8 {
        return @as([*]const u8, @ptrCast(self))[@sizeOf(Packet)..][0..self.length];
    }
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
            4,
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
    const conn: *Connection = @alignCast(@fieldParentPtr("decrypt_reader", io_r));
    const enc = conn.encryption.?;
    if (limit == .nothing) return 0;
    if (conn.read_closed.load(.monotonic)) return error.EndOfStream;

    const dest = try io_w.writableSliceGreedy(1);
    const encrypted = try conn.reader.peekGreedy(1);

    const len = @min(dest.len, encrypted.len, @backingInt(limit));

    var c_n: c_int = undefined;
    const res = crypto.EVP_DecryptUpdate(
        enc.decrypt,
        dest.ptr,
        &c_n,
        encrypted.ptr,
        @intCast(len),
    );
    if (res <= 0) {
        conn.read_error = error.DecryptionFailed;
        return error.ReadFailed;
    }
    assert(c_n > 0);
    const n: usize = @intCast(c_n);
    io_w.advance(n);
    conn.reader.toss(n);

    return n;
}

fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const max_iovecs_len = 8;

    const conn: *Connection = @alignCast(@fieldParentPtr("reader", io_r));
    const io = conn.runtime.io();
    var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
    const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];
    assert(dest[0].len > 0);

    if (conn.read_closed.load(.monotonic)) return error.EndOfStream;

    // logger.debug("[{f}] Querying more data", .{conn});
    const n = blk: {
        const res = io.operate(.{ .net_read = .{
            .socket_handle = conn.stream_handle,
            .data = data,
        } }) catch |err| {
            conn.read_error = err;
            return error.ReadFailed;
        };

        const read_res = res.net_read catch |err| {
            conn.read_error = err;
            return error.ReadFailed;
        };
        break :blk read_res.data_len;
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

fn netWrite(self: *Connection, header: []const u8, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const io = self.runtime.io();

    const n = blk: {
        const res = io.operate(.{ .net_write = .{
            .socket_handle = self.stream_handle,
            .header = header,
            .data = data,
            .splat = splat,
        } }) catch |err| {
            self.write_error = err;
            return error.WriteFailed;
        };

        break :blk res.net_write catch |err| {
            self.write_error = err;
            return error.WriteFailed;
        };
    };
    return self.writer.consume(n);
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const conn: *Connection = @alignCast(@fieldParentPtr("writer", io_w));
    const buffered = io_w.buffered();

    if (conn.encryption) |enc| {
        var total_len: usize = 0;

        var len: c_int = undefined;
        var res = crypto.EVP_EncryptUpdate(
            enc.encrypt,
            &enc.encrypt_buffer,
            &len,
            buffered.ptr,
            @intCast(buffered.len),
        );
        if (res <= 0) {
            conn.write_error = error.EncryptionFailed;
            return error.WriteFailed;
        }
        total_len += @as(usize, @intCast(len));
        for (data) |d| {
            const available_len = enc.encrypt_buffer.len - total_len;
            if (available_len == 0) break;

            res = crypto.EVP_EncryptUpdate(
                enc.encrypt,
                @as([*]u8, &enc.encrypt_buffer)[total_len..],
                &len,
                d.ptr,
                @intCast(@min(d.len, available_len)),
            );
            if (res <= 0) {
                conn.write_error = error.EncryptionFailed;
                return error.WriteFailed;
            }
            total_len += @as(usize, @intCast(len));
        }

        return conn.netWrite(enc.encrypt_buffer[0..total_len], &.{""}, 0);
    }

    return conn.netWrite(buffered, data, splat);
}

fn coro_readConnection(self: *Connection, allocator: Allocator) CoroReadError!void {
    defer _ = self.read_closed.swap(true, .monotonic);
    self.start.wait() catch return;

    var read_arena = std.heap.ArenaAllocator.init(allocator);
    defer read_arena.deinit();

    while (true) : ({
        if (!read_arena.reset(.{ .retain_with_limit = max_packet_length })) {
            @branchHint(.unlikely);
            logger.warn("[{f}] Failed to reset arena allocator", .{self});
        }
    }) {
        self.readConnection(allocator, &read_arena) catch |e| return switch (e) {
            error.Canceled => break,
            error.ReadFailed => if (self.read_error) |rerr| switch (rerr) {
                error.Canceled => break,
                error.SocketUnconnected, error.NetworkDown => error.Disconnected,
                error.SystemResources, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.DecryptionFailed => |err| err,
                error.AccessDenied, error.Unexpected => unreachable,
            } else error.CallbackHandlerFailed,
            error.EndOfStream => if (self.read_closed.load(.monotonic)) break else error.EndOfStream,
            error.CallbackHandlerFailed,
            error.Disconnected,
            error.DecompressionFailed,
            error.LegacyHandshake,
            error.PacketTooSmall,
            error.PacketTooLarge,
            error.InvalidLength,
            error.InvalidPacketID,
            error.OutOfMemory,
            => |err| err,
        };
    }
}

fn coro_writeConnection(self: *Connection, allocator: Allocator) CoroWriteError!void {
    defer self.send_channel.close(.graceful);

    self.start.wait() catch return;

    while (true) {
        self.writeConnection(allocator) catch |e| switch (e) {
            error.Canceled => break,
            error.WriteFailed => return switch (self.write_error.?) {
                error.Canceled => break,
                error.SocketUnconnected,
                error.NetworkUnreachable,
                error.NetworkDown,
                error.ConnectionRefused,
                error.SocketNotBound,
                error.HostUnreachable,
                => error.Disconnected,
                error.ConnectionTimedOut, error.ConnectionResetByPeer, error.SystemResources, error.EncryptionFailed => |err| err,
                error.AddressFamilyUnsupported, error.Unexpected, error.FastOpenAlreadyInProgress => unreachable,
            },
        };
    }
}

fn readConnection(self: *Connection, gpa: Allocator, arena_alloc: *std.heap.ArenaAllocator) !void {
    const arena = arena_alloc.allocator();
    var rparams = ReadParams{
        .gpa = gpa,
        .arena = arena_alloc,
        .input_mode = .full,
    };

    const reader = if (self.encryption != null) &self.decrypt_reader else &self.reader;
    if (self.read_closed.load(.monotonic)) return error.EndOfStream;
    try self.runtime.io().checkCancel();
    const next_byte = reader.peekByte() catch |e| switch (e) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.Disconnected,
    };

    if (self.in_phase == .handshake and next_byte == 0xFE) { // legacy handshake
        return error.LegacyHandshake;
    }

    const packet_length: i32 = PacketType.readNoAlloc(.var_int, reader) catch |e| switch (e) {
        error.Overflow => return error.PacketTooLarge,
        error.EndOfStream, error.ReadFailed => |err| return err,
        else => unreachable,
    };
    // std.log.debug("[{f}] Got packet length: {d}", .{ self, packet_length });
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
        rparams.input_mode = .streamed;

        decomp = .init(&raw_reader, .zlib, &comp.decompress_buffer);
        break :blk &decomp.reader;
    } else &raw_reader;

    const packet_id = PacketType.readNoAlloc(.var_int, packet_reader) catch |e| return switch (e) {
        error.Overflow => error.InvalidPacketID,
        error.EndOfStream => error.InvalidLength,
        error.ReadFailed => {
            self.compression.?.decompression_error = decomp.err;
            return error.DecompressionFailed;
        },
        else => unreachable,
    };
    self.addReadPacket();

    const curr_side = self.target_side.opposite();
    const pid = self.packet_registry.getPacketID(curr_side, self.in_phase, packet_id) orelse
        return error.InvalidPacketID;
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
                self.compression.?.decompression_error = decomp.err;
                return error.DecompressionFailed;
            },
            error.CallbackHandlerFailed, error.OutOfMemory, error.EndOfStream => |err| err,
            else => error.ReadFailed,
        };
        self.handler_error = err;
        return err;
    };
    if (raw_reader.end != length or packet_reader.bufferedLen() != 0) return error.PacketTooLarge;
}

fn writeConnection(self: *Connection, allocator: Allocator) !void {
    const writer = &self.writer;

    var pnode: ?*Packet = self.send_channel.receive() catch |e| switch (e) {
        error.Canceled => |err| return err,
        error.Closed => {
            self.write_error = error.SocketUnconnected;
            return error.WriteFailed;
        },
    };
    while (pnode) |packet| : ({
        pnode = self.send_channel.tryReceive() catch |e| switch (e) {
            error.Closed => {
                self.write_error = error.SocketUnconnected;
                return error.WriteFailed;
            },
            error.WouldBlock => null,
        };
    }) {
        defer allocator.free(packet.getBytes());
        const bytes = packet.getData();

        assert(bytes.len <= max_packet_length);

        PacketType.writerNoAlloc(.var_int, writer, @intCast(bytes.len)) catch |e| switch (e) {
            error.WriteFailed => |err| return err,
            else => unreachable,
        };
        try writer.writeAll(bytes);
        self.addWritePacket();
    }

    try writer.flush();
}

fn addReadPacket(self: *Connection) void {
    self.lockUncancelable();
    defer self.unlock();

    self.last_packet_timestamp = Io.Timestamp.now(std.Options.debug_io, .boot);

    if (self.rate_limited) |rl| {
        rl.received +|= 1; // Realistically these shouldn't overflow but just in case
    }
}

fn addWritePacket(self: *Connection) void {
    self.lockUncancelable();
    defer self.unlock();

    if (self.rate_limited) |rl| {
        rl.sent +|= 1; // Realistically these shouldn't overflow but just in case
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
    logger.debug("Destroying {f}", .{self});
    const io = self.runtime.io();

    self.read_coro.cancel(io) catch |e| {
        logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
    };
    self.write_coro.cancel(io) catch |e| {
        logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
    };
    self.send_channel.close(.graceful);
    while (self.send_channel.tryReceive()) |packet| {
        allocator.free(packet.getBytes());
    } else |_| {}
    io.vtable.netClose(io.userdata, (&self.getSocket())[0..1]);
    switch (self.disconnection_reason) {
        .none, .normal => {},
        .reason => |dc| dc.deinit(allocator),
    }

    self.vtable.deinit(self, allocator);
}

// TODO: Bandwidth monitor ?
// TODO: Rewrite ts for multithreading, bro i hate this so much it's just like
// i can't do anything, can't understand anything, it's genuinely pissing me off

/// Will replace the ip when this connection gets formatted to the console.
packet_registry: *const PacketRegistry,
name: ?[]const u8 = null,
vtable: *const VTable,
mutex: zio.Mutex,
refcount: core.RefCount,
start: zio.Event,

runtime: *zio.Runtime,
tick_count: u8,

in_phase: NetworkingPhase,
out_phase: NetworkingPhase,
target_side: NetworkingSide,

rate_limited: ?*RateLimited,
compression: ?*Compression,
encryption: ?*Encryption,

disconnection_reason: union(enum) { none, normal, reason: TextComponent },
stream_handle: Io.net.Socket.Handle,
ip_address: Io.net.IpAddress,
timeout: Io.Duration,

read_closed: std.atomic.Value(bool),
read_buffer: [reader_buffer_size]u8,
reader: Io.Reader,
decrypt_reader: Io.Reader,
read_error: ?StreamReadError,
handler_error: ?ReadCallbackError,
read_coro: Io.Future(CoroReadError!void),
last_packet_timestamp: Io.Timestamp,

write_buffer: [writer_buffer_size]u8,
writer: Io.Writer,
write_error: ?StreamWriteError,
write_coro: Io.Future(CoroWriteError!void),

send_buffer: [128]*Packet,
send_channel: zio.Channel(*Packet),

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
};
pub const CoroWriteError = error{
    Disconnected,
    ConnectionResetByPeer,
    SystemResources,
    ConnectionTimedOut,
    EncryptionFailed,
};
pub const StreamReadError = Io.net.Stream.Reader.Error || error{DecryptionFailed};
pub const StreamWriteError = Io.net.Stream.Writer.Error || error{EncryptionFailed};
pub const InitError = Io.ConcurrentError || Allocator.Error || error{ SocketUnconnected, ConnectionTimedOut, Unexpected };

pub const ReadCallbackError = PacketType.ReadError || WritePacketError || Io.net.ShutdownError || error{CallbackHandlerFailed};
pub const WritePacketError = Io.Cancelable || Allocator.Error || PacketType.WriteError || error{
    PacketIDNotFound,
    PacketTooLarge,
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
    limit: Count,
    average_received: Average = 0,
    average_sent: Average = 0,
    received: Count = 0,
    sent: Count = 0,

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
    threshold: usize,
    decompression_error: ?flate.Decompress.Error,
    decompress_buffer: [flate.max_window_len]u8,
    compress_buffer: [flate.max_window_len]u8,
};

pub const Encryption = struct {
    encrypt: *crypto.EVP_CIPHER_CTX,
    decrypt: *crypto.EVP_CIPHER_CTX,
    shared_secret: [16]u8,
    // Should have more bytes, but AES128/CFB8 doesn't buffer, so encryption and decryption is
    // N bytes for N bytes
    encrypt_buffer: [writer_buffer_size]u8,
    decrypt_buffer: [reader_buffer_size]u8,

    pub fn init(self: *Encryption, shared_secret_src: union(enum) { random_secret: std.Random, fixed_secret }) SetEncryptionError!void {
        self.encrypt = crypto.EVP_CIPHER_CTX_new() orelse return error.SetupFailed;
        errdefer crypto.EVP_CIPHER_CTX_free(self.encrypt);

        self.decrypt = crypto.EVP_CIPHER_CTX_new() orelse return error.SetupFailed;
        errdefer crypto.EVP_CIPHER_CTX_free(self.decrypt);

        if (shared_secret_src == .random_secret) {
            shared_secret_src.random_secret.bytes(&self.shared_secret);
        }

        const cipher = crypto.EVP_aes_128_cfb8().?;

        var res = crypto.EVP_EncryptInit_ex(
            self.encrypt,
            cipher,
            null,
            &self.shared_secret,
            &self.shared_secret,
        );
        if (res == 0) return error.SetupFailed;
        res = crypto.EVP_DecryptInit_ex(
            self.decrypt,
            cipher,
            null,
            &self.shared_secret,
            &self.shared_secret,
        );
        if (res == 0) return error.SetupFailed;
    }

    pub fn deinit(self: *Encryption) void {
        crypto.EVP_CIPHER_CTX_free(self.encrypt);
        crypto.EVP_CIPHER_CTX_free(self.decrypt);
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
    disconnect: *const DisconnectCallbackFn = noDisconnectMessage,
    deinit: *const DeinitCallbackFn = noDeinit,
    tick: *const TickCallbackFn = noTick,
};

pub const DisconnectReason = union(enum) {
    normal,
    static: *const TextComponent,
    copied: struct { Allocator, *const TextComponent },
};

/// `allocator` must remain valid until this connection is deinitalized
pub fn init(self: *Connection, allocator: Allocator, options: InitOptions) InitError!void {
    self.* = .{
        .packet_registry = options.packet_registry,
        .name = options.name,
        .vtable = options.vtable,
        .mutex = .init,
        .refcount = .{},
        .start = .init,

        .runtime = options.runtime,
        .tick_count = 0,

        .in_phase = options.in_phase,
        .out_phase = options.out_phase,
        .target_side = options.target_side,

        .rate_limited = options.rate_limited,
        .compression = options.compression,
        .encryption = options.encryption,

        .disconnection_reason = .none,
        .stream_handle = options.stream.socket.handle,
        .ip_address = options.stream.socket.address,
        .timeout = options.timeout,

        .read_closed = .init(false),
        .read_buffer = undefined,
        .reader = .{
            .vtable = &reader_vtable,
            .buffer = &self.read_buffer,
            .seek = 0,
            .end = 0,
        },
        .decrypt_reader = if (options.encryption) |enc| .{
            .buffer = &enc.decrypt_buffer,
            .vtable = &decrypt_reader_vtable,
            .seek = 0,
            .end = 0,
        } else .failing,
        .read_error = null,
        .handler_error = null,
        .read_coro = .{ .any_future = null, .result = {} },
        .last_packet_timestamp = Io.Timestamp.now(std.Options.debug_io, .boot),

        .write_buffer = undefined,
        .writer = .{
            .vtable = &writer_vtable,
            .buffer = &self.write_buffer,
            .end = 0,
        },
        .write_error = null,
        .write_coro = .{ .any_future = null, .result = {} },

        .send_buffer = undefined,
        .send_channel = .init(&self.send_buffer),
    };
    try self.setNoDelay();
    const io = self.runtime.io();

    self.read_coro = try io.concurrent(coro_readConnection, .{ self, allocator });
    errdefer self.read_coro.cancel(io) catch {};
    self.write_coro = try io.concurrent(coro_writeConnection, .{ self, allocator });
    errdefer self.write_coro.cancel(io) catch {};
}

pub fn acquire(self: *Connection) void {
    self.refcount.acquire();
}

pub fn release(self: *Connection, allocator: Allocator) void {
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
    if (self.disconnection_reason == .none) return;
    if (blk: {
        self.send_channel.impl.mutex.lockUncancelable();
        defer self.send_channel.impl.mutex.unlock();
        break :blk !self.send_channel.impl.closed;
    }) {
        self.vtable.disconnect(self, switch (reason) {
            .normal => &TextComponent.disconnect_generic,
            .static => |tc| tc,
            .copied => |p| p[1],
        }) catch {};
        self.shutdown(.recv) catch {};
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

    self.name = self.name orelse options.name;
    if (options.in_phase) |p| self.in_phase = p;
    if (options.out_phase) |p| self.out_phase = p;
    if (options.timeout) |to| self.timeout = to;
    if (options.rate_limited) |rl| self.rate_limited = rl;
    if (options.vtable) |cb| self.vtable = cb;
    if (options.compression) |c| self.compression = c;
    if (options.encryption) |c| {
        self.encryption = c;
        self.decrypt_reader = .{
            .buffer = &c.decrypt_buffer,
            .vtable = &decrypt_reader_vtable,
            .seek = 0,
            .end = 0,
        };
    }
}

/// Allows this connection to be printed to `std.Io.Writer`s as: `[ip-or-name]<[phase]>->[target-side]`
/// (excluding `[]`s)
pub fn format(self: *const Connection, writer: *Io.Writer) Io.Writer.Error!void {
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

pub fn sendPacket(
    self: *Connection,
    apair: AllocPair,
    resource: []const u8,
    comptime @"type": PacketType,
    value: @"type".getZigType(),
) WritePacketError!void {
    blk: {
        if (!self.send_channel.impl.mutex.tryLock()) break :blk;
        defer self.send_channel.impl.mutex.unlock();

        if (self.send_channel.impl.closed) return;
    }

    const pack_id = self.packet_registry.packedIDFromResource(self.target_side, self.out_phase, resource) orelse
        return error.PacketIDNotFound;
    const entry = self.packet_registry.getEntry(self.target_side, self.out_phase, pack_id);

    var aw = Io.Writer.Allocating.initAligned(apair.gpa, .of(Packet));
    defer aw.deinit();
    try aw.ensureTotalCapacity(1 + entry.write_cushion);
    aw.writer.advance(@sizeOf(Packet));

    PacketType.writerNoAlloc(.var_int, &aw.writer, @backingInt(pack_id)) catch return error.OutOfMemory;

    @"type".write(apair, &aw.writer, value) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |err| err,
    };

    if (aw.written().len >= max_packet_length) return error.PacketTooLarge;

    const bytes_result: []align(@alignOf(Packet)) u8 = res: {
        if (self.compression) |comp| {
            const content = aw.written()[@sizeOf(Packet)..];

            var out_w = Io.Writer.Allocating.initAligned(apair.gpa, .of(Packet));
            defer out_w.deinit();
            try out_w.ensureTotalCapacity(1 + content.len);
            out_w.writer.advance(@sizeOf(Packet));

            if (content.len < comp.threshold) {
                PacketType.writerNoAlloc(.var_int, &out_w.writer, 0) catch unreachable;
                out_w.writer.writeAll(content) catch unreachable;
            } else {
                @branchHint(.likely);
                PacketType.writerNoAlloc(.var_int, &out_w.writer, @intCast(content.len)) catch unreachable;
                var compress = flate.Compress.init(&out_w.writer, &comp.compress_buffer, .zlib, .default) catch
                    return error.OutOfMemory;

                // Split compression into chunks of 512 bytes to potentially allow other
                // tasks to run.
                var offset: usize = 0;
                while (offset < content.len) {
                    const remaining = content.len - offset;
                    const size = @min(512, remaining);
                    const n = compress.writer.write(content[offset .. offset + size]) catch return error.OutOfMemory;
                    offset += n;
                    try zio.maybeYield();
                }

                compress.finish() catch return error.OutOfMemory;
            }

            break :res @alignCast(try out_w.toOwnedSlice());
        }

        break :res @alignCast(try aw.toOwnedSlice());
    };
    errdefer apair.gpa.free(bytes_result);

    const pnode: *Packet = @ptrCast(@alignCast(bytes_result.ptr));
    pnode.* = .{ .length = bytes_result.len - @sizeOf(Packet) };

    self.send_channel.send(pnode) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => apair.gpa.free(bytes_result),
    };
}

pub fn shutdown(self: *Connection, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    const io = self.runtime.io();

    if (how != .send) { // recv or both
        _ = self.read_closed.swap(true, .monotonic);
    }
    if (how != .recv) { // send or both
        self.send_channel.close(.graceful);
    }

    try io.vtable.netShutdown(io.userdata, self.stream_handle, how);
}

pub fn tick(self: *Connection) TickError!void {
    logger.debug("[{f}] Ticking", .{self});

    const delta = self.tick_count;
    self.tick_count = (self.tick_count + 1) % 1;

    if (delta == 0) {
        if (self.rate_limited) |rl| {
            rl.average_sent = math.lerp(@as(RateLimited.Average, @floatFromInt(rl.sent)), rl.average_sent, 0.75);
            rl.average_received = math.lerp(@as(RateLimited.Average, @floatFromInt(rl.received)), rl.average_received, 0.75);
            rl.sent = 0;
            rl.received = 0;
            if (@as(RateLimited.Count, @trunc(rl.average_received)) >= rl.limit) {
                logger.warn("[{f}] Exceeded rate-limit (sent {d} packets per seconds)", .{ self, rl.average_received });
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
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Packet);
    std.testing.refAllDecls(RateLimited);
    std.testing.refAllDecls(Compression);
    std.testing.refAllDecls(Encryption);
}
