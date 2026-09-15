const EventLoop = @This();
const std = @import("std");
const net = @import("net");
const coro = @import("coro");
const core = @import("../core.zig");

const Io = std.Io;
const Connection = net.Connection;
const Allocator = std.mem.Allocator;

const logger = std.log.scoped(.@"core/server/EventLoop");
const static_io = coro.AnyCoroutine.static_io;

const CoroAccpetError = Allocator.Error || coro.polling.AddError || error{
    SystemResources,
    SocketNotListening,
    NetworkDown,
    ProtocolFailure,
    Canceled,
    SocketUnconnected,
    Timeout,
    Unexpected,
};

const BroadcastCoroError = Allocator.Error || error{SystemResources};

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

io: Io,

v6_enabled: bool,
accept_options: Io.net.Server.AcceptOptions,

ipv4: Io.net.Ip4Address,
sockv4_handle: Io.net.Socket.Handle,
accept_coro: coro.Coroutine(CoroAccpetError!void),

ipv6: Io.net.Ip6Address,
sockv6_handle: Io.net.Socket.Handle,
acceptv6_coro: coro.Coroutine(CoroAccpetError!void),

broadcast: struct {
    enabled: bool,
    socket: Io.net.Socket,
    last_broadcast: Io.Timestamp,
    coro: coro.Coroutine(BroadcastCoroError!void),
},

connections: std.HashMapUnmanaged(*Connection, void, Connection.HashContext, std.hash_map.default_max_load_percentage),
poller_mutex: Io.Mutex,
poller: coro.polling.Poller(PolledInfo),

test {
    std.testing.refAllDecls(@This());
}