//! An intrusive interface (like `std.Io.Reader/Writer`) that handles all the operations related to a
//! minecraft connection in either way. Use `.init()` to initalize it with specific options.
//!
//! TODO: doc
const Connection = @This();
const std = @import("std");
const coro = @import("coro");
const utils = @import("utils");
const crypto = @import("crypto");
const net = @import("net.zig");

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

const static_io = coro.AnyCoroutine.static_io;

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

const reader_buffer_size = 128;
const writer_buffer_size = 128;

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
    Timeout,
    InvalidLength,
    DecompressionFailed,
    DecryptionFailed,
};
const CoroWriteError = error{
    Disconnected,
    ConnectionResetByPeer,
    SystemResources,
    ConnectionTimedOut,
    EncryptionFailed,
};
const StreamReadError = Io.net.Stream.Reader.Error || error{DecryptionFailed};
const StreamWriteError = Io.net.Stream.Writer.Error || error{EncryptionFailed};

const PacketNode = struct {
    node: std.DoublyLinkedList.Node,
    length: usize,
    close: bool,

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

fn decryptStream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const conn: *Connection = @alignCast(@fieldParentPtr("decrypt_reader", io_r));
    const enc = conn.encryption.?;
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    const tmp = limit.slice(io_r.buffer);

    const tmp_n = try conn.reader.readSliceShort(tmp);
    const len = @min(dest.len, tmp_n);

    var c_n: c_int = undefined;
    const res = crypto.EVP_DecryptUpdate(
        enc.decrypt,
        dest.ptr,
        &c_n,
        tmp.ptr,
        @intCast(len),
    );
    if (res == 0) {
        conn.read_error = error.DecryptionFailed;
        return error.ReadFailed;
    }
    const n: usize = @intCast(c_n);
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

    const start_time = Io.Timestamp.now(static_io, .boot);
    // const res = io.operate(.{ .net_read = .{
    //     .socket_handle = self.stream_handle,
    //     .data = data,
    // } }) catch |err| {
    //     self.read_error = err;
    //     return error.ReadFailed;
    // };

    // return res.net_read catch |err| {
    //     self.read_error = err;
    //     return error.ReadFailed;
    // };
    const n = io.vtable.netRead(io.userdata, conn.stream_handle, data) catch |err| {
        conn.read_error = err;
        return error.ReadFailed;
    };
    if (start_time.untilNow(static_io, .boot).nanoseconds >= conn.timeout.nanoseconds) {
        conn.read_error = error.Timeout;
        return error.ReadFailed;
    }
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
    const io = self.write_coro.any.io();

    // const n = blk: {
    //     const res = io.operate(.{ .net_write = .{
    //         .socket_handle = self.stream_handle,
    //         .header = buffered,
    //         .data = data,
    //         .splat = splat,
    //     } }) catch |err| {
    //         self.write_error = err;
    //         return error.WriteFailed;
    //     };

    //     break :blk res.net_write catch |err| {
    //         self.write_error = err;
    //         return error.WriteFailed;
    //     };
    // };
    const n = io.vtable.netWrite(io.userdata, self.stream_handle, header, data, splat) catch |err| {
        self.write_error = err;
        return error.WriteFailed;
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
        if (res == 0) {
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
                @intCast(available_len),
            );
            if (res == 0) {
                conn.write_error = error.EncryptionFailed;
                return error.WriteFailed;
            }
            total_len += @as(usize, @intCast(len));
        }

        return conn.netWrite(enc.encrypt_buffer[0..total_len], &.{}, 0);
    }

    return conn.netWrite(buffered, data, splat);
}

fn coro_readConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) CoroReadError!void {
    _ = co;

    var read_arena = std.heap.ArenaAllocator.init(allocator);
    defer read_arena.deinit();

    while (true) : ({
        if (!read_arena.reset(.{ .retain_with_limit = max_packet_length })) {
            @branchHint(.unlikely);
            logger.warn("Failed to reset arena allocator for {f}", .{self.ip_address});
        }
    }) {
        self.readConnection(allocator, &read_arena) catch |e| switch (e) {
            error.ReadFailed => return switch (self.read_error.?) {
                error.SocketUnconnected, error.Canceled => break,
                error.NetworkDown => error.Disconnected,
                error.SystemResources, error.ConnectionResetByPeer, error.Timeout, error.DecryptionFailed => |err| err,
                error.AccessDenied, error.Unexpected => unreachable,
            },
            error.DecompressionFailed,
            error.LegacyHandshake,
            error.PacketTooSmall,
            error.PacketTooLarge,
            error.InvalidLength,
            error.EndOfStream,
            error.InvalidPacketID,
            error.OutOfMemory,
            => |err| return err,
        };
    }
}

fn coro_writeConnection(co: *coro.AnyCoroutine, self: *Connection, allocator: Allocator) CoroWriteError!void {
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
                //error.ConnectionTimedOut,
                error.ConnectionResetByPeer, error.SystemResources, error.EncryptionFailed => |err| err,
                error.AddressFamilyUnsupported, error.Unexpected, error.FastOpenAlreadyInProgress => unreachable,
            };
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
    if (self.phase == .handshake and (try reader.peekByte()) == 0xFE) { // legacy handshake
        return error.LegacyHandshake;
    }

    const packet_length: i32 = PacketType.readNoAlloc(.var_int, reader) catch |e| switch (e) {
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
        reader.readAlloc(arena, length);

    var raw_reader = Io.Reader.fixed(packet_bytes);
    var decomp: flate.Decompress = undefined;

    const packet_reader = if (self.compression) |comp| blk: {
        const uncompressed_length = PacketType.readNoAlloc(.var_int, &raw_reader) catch |e| return switch (e) {
            error.Overflow, error.EndOfStream => error.InvalidLength,
            else => unreachable,
        };
        if (uncompressed_length < 0) return error.InvalidLength;
        if (uncompressed_length == 0) break :blk &raw_reader;
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

    const pid = self.packet_registry.getPacketID(self.target_side, self.phase, packet_id) orelse
        return error.InvalidPacketID;
    const entry = self.packet_registry.getEntry(self.target_side, self.phase, pid);

    entry.callback(self, packet_reader, rparams) catch |e| {
        const err = switch (e) {
            error.ReadFailed => {
                self.compression.?.decompression_error = decomp.err;
                return error.DecompressionFailed;
            },
            error.OutOfMemory, error.EndOfStream => |err| err,
            else => error.ReadFailed,
        };
        self.parsing_error = err;
        return err;
    };
    if (raw_reader.end != length or packet_reader.bufferedLen() != 0) return error.PacketTooLarge;
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

    PacketType.writerNoAlloc(.var_int, writer, @intCast(bytes.len)) catch |e| switch (e) {
        error.WriteFailed => |err| return err,
        else => unreachable,
    };
    try writer.writeAll(bytes);
    self.addWritePacket();
}

fn popPacket(self: *Connection) ?*PacketNode {
    const pack = self.send_queue.pop() orelse return null;
    return @fieldParentPtr("node", pack);
}

fn addReadPacket(self: *const Connection) void {
    if (self.rate_limited) |rl| {
        rl.received +|= 1; // Realistically these shouldn't overflow but just in case
    }
}

fn addWritePacket(self: *const Connection) void {
    if (self.rate_limited) |rl| {
        rl.sent +|= 1; // Realistically these shouldn't overflow but just in case
    }
}

/// Handshake and Status don't have this.
fn noDisconnectMessage(self: *Connection, reason: *const TextComponent) Allocator.Error!void {
    _ = self;
    _ = reason;
}

// TODO: Bandwidth monitor ?

/// Will replace the ip when this connection gets formatted to the console.
name: ?[]const u8 = null,
phase: NetworkingPhase,
target_side: NetworkingSide,
timeout: Io.Duration,
rate_limited: ?*RateLimited,
packet_registry: *const PacketRegistry,
compression: ?*Compression,
encryption: ?*Encryption,

read_closed: bool,
write_closed: bool,
stream_handle: Io.net.Socket.Handle,
ip_address: Io.net.IpAddress,

read_buffer: [reader_buffer_size]u8,
reader: Io.Reader,
decrypt_reader: Io.Reader,
read_error: ?StreamReadError,
parsing_error: ?PacketType.ReadError,
read_coro: coro.Coroutine(CoroReadError!void),

write_buffer: [writer_buffer_size]u8,
writer: Io.Writer,
write_error: ?StreamWriteError,
write_coro: coro.Coroutine(CoroWriteError!void),

send_queue: std.DoublyLinkedList,

// Connection-specific callbacks
disconnect_callback: *const DisconnectCallbackFn,

/// Maximum value of `u21`, roughly 2MiB
pub const max_packet_length = (2 * 1024 * 1024) - 1;

pub const ReadCallbackError = Io.Reader.Error || Allocator.Error || PacketType.ReadError;
pub const WritePacketError = Allocator.Error || PacketType.WriteError || error{
    PacketIDNotFound,
    PacketTooLarge,
};
pub const SetEncryptionError = error{SetupFailed};

/// The data in `reader` will never move, as such the `StructuredPacket` API is useable with it.
///
/// The memory allocated by the arena allocator passed in this function will only stay valid for this call
/// **only**. Any data that is wished to stay persitent must be copied to a new location.
pub const ReadCallbackFn = fn (conn: *Connection, reader: *Io.Reader, params: ReadParams) ReadCallbackError!void;
pub const DisconnectCallbackFn = fn (conn: *Connection, reason: *const TextComponent) Allocator.Error!void;

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
    phase: NetworkingPhase = .handshake,
    /// Sets a timeout on the reading end, if exceeded it automatically
    /// closes the connection.
    timeout: Io.Duration = .fromSeconds(30),
    /// Include `RateLimited` within your implementation struct
    /// and pass it here or in `reconfigure()` to limit packet
    /// rate.
    rate_limited: ?*RateLimited = null,
    /// Defaults with a callback that does nothing.
    disconnect_callback: *const DisconnectCallbackFn = &noDisconnectMessage,
    compression: ?*Compression = null,
    encryption: ?*Encryption = null,
};

pub const ReconfigureOptions = struct {
    fn empty(self: ReconfigureOptions) bool {
        const info = @typeInfo(ReconfigureOptions).@"struct";
        inline for (info.fields) |f| {
            comptime if (@typeInfo(f.type) != .optional) continue;
            if (@field(self, f.name) != null) return false;
        }
        return true;
    }

    name: ?[]const u8 = null,
    phase: ?NetworkingPhase = null,
    timeout: ?Io.Duration = null,
    rate_limited: ?*RateLimited = null,
    disconnect_callback: ?*const DisconnectCallbackFn = null,
    compression: ?*Compression = null,
    encryption: ?*Encryption = null,
};

/// `allocator` must remain valid until this connection is deinitalized
pub fn init(self: *Connection, allocator: Allocator, options: InitOptions) Allocator.Error!void {
    self.* = .{
        .phase = options.phase,
        .target_side = options.target_side,
        .timeout = options.timeout,
        .rate_limited = options.rate_limited,
        .compression = options.compression,
        .encryption = options.encryption,

        .packet_registry = options.packet_registry,

        .read_closed = false,
        .write_closed = false,
        .stream_handle = options.stream.socket.handle,
        .ip_address = options.stream.socket.address,

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
        .parsing_error = null,
        .read_coro = undefined,

        .write_buffer = undefined,
        .writer = .{
            .vtable = &writer_vtable,
            .buffer = &self.write_buffer,
            .end = 0,
        },
        .write_error = null,
        .write_coro = undefined,

        .send_queue = .{},

        .disconnect_callback = options.disconnect_callback,
    };

    try self.read_coro.init(.{}, coro_readConnection, .{ self, allocator });
    errdefer self.read_coro.deinit();
    try self.write_coro.init(.{}, coro_writeConnection, .{ self, allocator });
    errdefer self.write_coro.deinit();
}

pub fn deinit(self: *Connection, allocator: Allocator) void {
    self.read_closed = true;
    self.write_closed = true;
    self.read_coro.await(.cancel) catch |e| {
        logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
    };
    self.write_coro.await(.cancel) catch |e| {
        logger.debug("[{f}] Error occured when closing connection: {t}", .{ self, e });
    };
    while (self.popPacket()) |packet| allocator.free(packet.getBytes());
    static_io.vtable.netClose(static_io.userdata, (&self.stream_handle)[0..1]);
}

/// Doesn't reallocate/duplicate anything.
///
/// Asserts that `options` actually does stuff, otherwise this might
/// mean a bad design.
pub fn reconfigure(self: *Connection, options: ReconfigureOptions) void {
    assert(!options.empty()); // Pointless reconfigure

    self.name = options.name;
    if (options.phase) |p| self.phase = p;
    if (options.timeout) |to| self.timeout = to;
    if (options.rate_limited) |rl| self.rate_limited = rl;
    if (options.disconnect_callback) |cb| self.disconnect_callback = cb;
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
    try writer.print("<{t}>->{t}", .{ self.phase, self.target_side });
}

pub fn sendPacket(
    self: *Connection,
    apair: AllocPair,
    resource: []const u8,
    comptime @"type": PacketType,
    value: @"type".getZigType(),
) WritePacketError!void {
    const pack_id = self.packet_registry.packedIDFromResource(self.target_side.opposite(), self.phase, resource) orelse
        return error.PacketIDNotFound;
    const entry = self.packet_registry.getEntry(self.target_side.opposite(), self.phase, pack_id);

    var aw = Io.Writer.Allocating.initAligned(apair.gpa, .of(PacketNode));
    defer aw.deinit();
    try aw.ensureTotalCapacity(1 + entry.write_cushion);
    aw.writer.advance(@sizeOf(PacketNode));

    PacketType.writerNoAlloc(.var_int, &aw.writer, @intFromEnum(pack_id)) catch return error.OutOfMemory;

    apair.write(@"type", &aw.writer, value) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |err| err,
    };

    if (aw.written().len >= max_packet_length) return error.PacketTooLarge;

    const bytes_result = res: {
        if (self.compression) |comp| {
            const content = aw.written()[@sizeOf(PacketNode)..];

            var out_w = Io.Writer.Allocating.initAligned(apair.gpa, .of(PacketNode));
            defer out_w.deinit();
            try out_w.ensureTotalCapacity(1 + content.len);
            aw.writer.advance(@sizeOf(PacketNode));

            if (content.len < comp.threshold) {
                PacketType.writerNoAlloc(.var_int, &out_w.writer, 0) catch unreachable;
                out_w.writer.writeAll(content) catch unreachable;
            } else {
                PacketType.writerNoAlloc(.var_int, &out_w.writer, @intCast(content.len)) catch unreachable;
                var compress = flate.Compress.init(&out_w.writer, &comp.compress_buffer, .zlib, .default) catch
                    return error.OutOfMemory;

                compress.writer.writeAll(content) catch return error.OutOfMemory;

                compress.finish() catch return error.OutOfMemory;
            }

            break :res try out_w.toOwnedSlice();
        }

        break :res try aw.toOwnedSlice();
    };
    errdefer comptime unreachable;

    const pnode: *PacketNode = @ptrCast(@alignCast(bytes_result.ptr));
    pnode.* = .{
        .node = undefined,
        .length = bytes_result.len - @sizeOf(PacketNode),
        .close = false,
    };
    self.send_queue.append(&pnode.node);
}

pub fn shutdown(self: *Connection, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    self.read_closed = self.read_closed or how != .send; // recv or both
    self.write_closed = self.write_closed or how != .recv; // send or both
    try static_io.vtable.netShutdown(static_io.userdata, self.stream_handle, how);
}

pub fn tickSecond(self: *Connection) (Allocator.Error || Io.net.ShutdownError)!void {
    if (self.rate_limited) |rl| {
        rl.average_sent = math.lerp(@as(RateLimited.Average, @floatFromInt(rl.sent)), rl.average_sent, 0.75);
        rl.average_received = math.lerp(@as(RateLimited.Average, @floatFromInt(rl.received)), rl.average_received, 0.75);
        rl.sent = 0;
        rl.received = 0;
        if (@as(RateLimited.Count, @trunc(rl.average_received)) >= rl.limit) {
            logger.warn("[{f}] Exceeded rate-limit (sent {d} packets per seconds)", .{ self, rl.average_received });
            try self.disconnect_callback(self, &.exceeded_packet_rate);
            try self.shutdown(.recv);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(PacketNode);
    std.testing.refAllDecls(RateLimited);
    std.testing.refAllDecls(Compression);
    std.testing.refAllDecls(Encryption);
}