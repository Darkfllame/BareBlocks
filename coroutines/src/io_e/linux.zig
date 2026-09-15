const std = @import("std");
const builtin = @import("builtin");
const private = @import("../private.zig");

const AnyCoroutine = @import("../AnyCoroutine.zig");

const Io = std.Io;
const net = Io.net;
const linux = std.os.linux;
const posix = std.posix;
const IpAddress = net.IpAddress;
const Threaded = Io.Threaded;

const native_os = builtin.os.tag;
const socket_flags_unsupported = Threaded.socket_flags_unsupported;
const HostName = net.HostName;
const PosixAddress = Threaded.PosixAddress;
const addressToPosix = Threaded.addressToPosix;
const recoverableOsBugDetected = Threaded.recoverableOsBugDetected;
const errnoBug = Threaded.errnoBug;
const clockToPosix = Threaded.clockToPosix;
const timestampFromPosix = Threaded.timestampFromPosix;
const posixAddressFamily = Threaded.posixAddressFamily;
const closeFd = Threaded.closeFd;
const posixSocketModeProtocol = Threaded.posixSocketModeProtocol;
const addressFromPosix = Threaded.addressFromPosix;
const assert = std.debug.assert;
const timestampToPosix = private.timestampToPosix;

const have_accept4 = !socket_flags_unsupported;
const have_sendmmsg = native_os == .linux;

fn checkCancel(ud: ?*anyopaque) Io.Cancelable!void {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));
    if (co.state.canceled) return error.Canceled;
}

fn operate(ud: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));

    switch (op) {
        else => return Io.failingOperate(ud, op),
        // .net_read => |nr| {
        //     const res = netRead(co, nr.socket_handle, nr.data) catch |e| switch (e) {
        //         error.Canceled => return error.Canceled,
        //         else => |err| err,
        //     };

        //     return .{ .net_read = res };
        // },
        // .net_write => |nw| {
        //     const res = netWrite(co, nw.socket_handle, nw.header, nw.data, nw.splat) catch |e| switch (e) {
        //         error.Canceled => return error.Canceled,
        //         else => |err| err,
        //     };

        //     return .{ .net_write = res };
        // },
        .net_receive => |nr| {
            const res = netReceive(
                co,
                nr.socket_handle,
                &nr.message_buffer[0],
                nr.data_buffer,
                nr.flags,
            );
            return .{ .net_receive = .{
                if (res) null else |e| switch (e) {
                    error.Canceled => |err| return err,
                    else => |err| err,
                },
                1,
            } };
        },
    }
}

//#region Time
fn now(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const clock_id = clockToPosix(clock);
    var timespec: posix.timespec = undefined;
    return switch (posix.errno(posix.system.clock_gettime(clock_id, &timespec))) {
        .SUCCESS => timestampFromPosix(&timespec),
        else => .zero,
    };
}

fn clockResolution(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    const clock_id = Io.Threaded.clockToPosix(clock);
    var timespec: posix.timespec = undefined;
    return switch (posix.errno(posix.system.clock_getres(clock_id, &timespec))) {
        .SUCCESS => .fromNanoseconds(Io.Threaded.nanosecondsFromPosix(&timespec)),
        .INVAL => error.ClockUnavailable,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn sleep(ud: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));

    const clock = switch (timeout) {
        .none => .awake,
        inline .duration, .deadline => |d| d.clock,
    };
    const clock_id = clockToPosix(clock);
    const deadline = switch (timeout) {
        .none => while (true) try co.yield(),
        .duration => |d| now(undefined, clock).nanoseconds + d.raw.nanoseconds,
        .deadline => |d| d.raw.nanoseconds,
    };
    while (true) {
        const _now = now(undefined, clock).nanoseconds;
        if (_now >= deadline) break;

        const remaining = deadline - _now;
        const sleep_time = @min(0, co.state.max_sleep_time, remaining);
        if (sleep_time > 0) {
            var timespec = timestampToPosix(sleep_time);
            while (true) {
                const rc = posix.system.clock_nanosleep(clock_id, .{ .ABSTIME = false }, &timespec, &timespec);
                switch (if (builtin.link_libc) @as(posix.E, @enumFromInt(rc)) else posix.errno(rc)) {
                    .INTR => continue,
                    else => return,
                }
            }
        }

        try co.yield();
    }
}
//#endregion Time

//#region net
const UnixAddress = extern union {
    any: posix.sockaddr,
    un: posix.sockaddr.un,
};

fn addressUnixToPosix(a: *const net.UnixAddress, storage: *UnixAddress) posix.socklen_t {
    @memcpy(storage.un.path[0..a.path.len], a.path);
    storage.un.family = posix.AF.UNIX;
    storage.un.path[a.path.len] = 0;
    return @sizeOf(posix.sockaddr.un);
}

fn fcntl(
    fd: posix.fd_t,
    cmd: enum(i32) { dupfd = 0, getfd = 1, setfd = 2, getfl = 3, setfl = 4 },
    arg: usize,
) error{Unexpected}!usize {
    while (true) {
        return switch (posix.errno(posix.system.fcntl(fd, @intFromEnum(cmd), arg))) {
            .SUCCESS => {},
            .INTR => continue,
            .INVAL => |err| posix.unexpectedErrno(err),
            else => recoverableOsBugDetected(),
        };
    }
}

fn setSockFlags(fd: posix.fd_t) !void {
    _ = try fcntl(fd, .setfd, posix.FD_CLOEXEC);
    var flags = try fcntl(fd, .getfl, undefined);
    flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try fcntl(fd, .setfl, flags);
}

fn setSocketOption(fd: posix.fd_t, level: i32, opt_name: u32, option: u32) !void {
    const o: []const u8 = @ptrCast(&option);
    while (true) {
        return switch (posix.errno(posix.system.setsockopt(fd, level, opt_name, o.ptr, @intCast(o.len)))) {
            .SUCCESS => {},
            .INTR => continue,

            .BADF, // File descriptor used after closed.
            .NOTSOCK,
            .INVAL,
            .FAULT,
            => |err| errnoBug(err),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn getSocketOption(fd: posix.fd_t, level: i32, opt_name: u32) !u32 {
    var len: u32 = @sizeOf(u32);
    var res: u32 = undefined;
    while (true) {
        return switch (posix.errno(posix.system.getsockopt(fd, level, opt_name, @ptrCast(&res), &len))) {
            .SUCCESS => res,
            .INTR => continue,

            .BADF, // File descriptor used after closed.
            .NOTSOCK,
            .INVAL,
            .FAULT,
            => |err| errnoBug(err),

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn openSocketPosix(family: posix.sa_family_t, options: IpAddress.BindOptions) !posix.socket_t {
    if (options.ip6_only and posix.IPV6 == void) return error.OptionUnsupported;

    const mode, const protocol = try posixSocketModeProtocol(family, options.mode, options.protocol);
    const flags: u32 = mode | if (socket_flags_unsupported)
        0
    else
        (posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
    const socket_fd = while (true) {
        const rc = posix.system.socket(family, flags, protocol);
        return switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(rc);
                errdefer closeFd(fd);
                if (socket_flags_unsupported) try setSockFlags(fd);
                break fd;
            },
            .INTR => continue,
            .AFNOSUPPORT, .PROTONOSUPPORT => error.AddressFamilyUnsupported,
            .INVAL => error.ProtocolUnsupportedBySystem,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            .PROTOTYPE => error.SocketModeUnsupported,
            else => |err| posix.unexpectedErrno(err),
        };
    };
    errdefer closeFd(socket_fd);

    if (options.ip6_only) {
        try setSocketOption(
            socket_fd,
            posix.IPPROTO.IPV6,
            posix.IPV6.V6ONLY,
            1,
        );
    }

    return socket_fd;
}

fn bind(socket_fd: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
    while (true) {
        return switch (posix.errno(posix.system.bind(socket_fd, addr, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,

            .ADDRINUSE => error.AddressInUse,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ADDRNOTAVAIL => error.AddressUnavailable,
            .NOMEM => error.SystemResources,

            .BADF, // File descriptor used after closed.
            .INVAL, // invalid parameters
            .NOTSOCK, // invalid `sockfd`
            .FAULT,
            => |err| errnoBug(err), // invalid `addr` pointer
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn posixGetSockName(socket_fd: posix.fd_t, addr: *posix.sockaddr, addr_len: *posix.socklen_t) !void {
    while (true) {
        switch (posix.errno(posix.system.getsockname(socket_fd, addr, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOBUFS => return error.SystemResources,

            .BADF, // File descriptor used after closed.
            .FAULT,
            .INVAL, // invalid parameters
            .NOTSOCK, // always a race condition
            => |err| return errnoBug(err),

            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn bindUnix(fd: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
    while (true) {
        return switch (posix.errno(posix.system.bind(fd, addr, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,

            .ACCES => error.AccessDenied,
            .ADDRINUSE => error.AddressInUse,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ADDRNOTAVAIL => error.AddressUnavailable,
            .NOMEM => error.SystemResources,

            .LOOP => error.SymLinkLoop,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .ROFS => error.ReadOnlyFileSystem,
            .PERM => error.PermissionDenied,

            .BADF, // File descriptor used after closed.
            .INVAL, // invalid parameters
            .NOTSOCK, // invalid `sockfd`
            .FAULT, // invalid `addr` pointer
            .NAMETOOLONG,
            => |err| errnoBug(err),

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn pollConnect(co: *AnyCoroutine, fd: posix.socket_t, clock: Io.Clock, deadline: i96) !posix.E {
    var pfd = posix.pollfd{
        .fd = fd,
        .events = posix.POLL.OUT,
        .revents = undefined,
    };
    const max_timeout: i32 = @intCast(std.math.clamp(
        co.state.max_sleep_time,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
    while ((try posix.poll((&pfd)[0..1], max_timeout)) != 1) {
        try co.yield();
        if (now(undefined, clock).nanoseconds > deadline) return error.Timeout;
    }
    const err = try getSocketOption(fd, posix.SOL.SOCKET, posix.SO.ERROR);
    return posix.errno(err);
}

fn connect(
    co: *AnyCoroutine,
    socket_fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
    timeout: Io.Timeout,
) !void {
    const clock, const deadline = switch (timeout) {
        .none => .{ Io.Clock.boot, std.math.maxInt(i96) },
        .deadline => |d| .{ d.clock, d.raw.nanoseconds },
        .duration => |d| .{ d.clock, now(undefined, d.clock).nanoseconds + d.raw.nanoseconds },
    };

    while (true) {
        return sw: switch (posix.errno(posix.system.connect(socket_fd, addr, addr_len))) {
            .SUCCESS => return,
            .INTR => continue,

            // TODO: Integrate this into pollers
            .AGAIN => {
                if (addr.family == posix.AF.UNIX) {
                    continue :sw try pollConnect(co, socket_fd, clock, deadline);
                }

                try co.yield();
                if (now(undefined, clock).nanoseconds > deadline) return error.Timeout;
                continue;
            },
            .INPROGRESS => continue :sw try pollConnect(co, socket_fd, clock, deadline),

            .ADDRNOTAVAIL => error.AddressUnavailable,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ALREADY => error.ConnectionPending,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .HOSTUNREACH => error.HostUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .TIMEDOUT => error.Timeout,
            .ACCES => error.AccessDenied,
            .NETDOWN => error.NetworkDown,

            .BADF, // File descriptor used after closed.
            .CONNABORTED,
            .FAULT,
            .ISCONN,
            .NOENT,
            .NOTSOCK,
            .PERM,
            .PROTOTYPE,
            => |err| errnoBug(err),

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn connectUnix(
    co: *AnyCoroutine,
    fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) !void {
    while (true) {
        return sw: switch (posix.errno(posix.system.connect(fd, addr, addr_len))) {
            .SUCCESS => {},
            .INTR => continue,

            .AGAIN => {
                var pfd = posix.pollfd{
                    .fd = fd,
                    .events = posix.POLL.OUT,
                    .revents = undefined,
                };
                const max_timeout: i32 = @intCast(std.math.clamp(
                    co.state.max_sleep_time,
                    std.math.minInt(i32),
                    std.math.maxInt(i32),
                ));
                while ((try posix.poll((&pfd)[0..1], max_timeout)) != 1) try co.yield();

                const err = try getSocketOption(fd, posix.SOL.SOCKET, posix.SO.ERROR);
                continue :sw posix.errno(err);
            },

            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ACCES => error.AccessDenied,
            .LOOP => error.SymLinkLoop,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .ROFS => error.ReadOnlyFileSystem,
            .PERM => error.PermissionDenied,

            .BADF, // File descriptor used after closed.
            .CONNABORTED,
            .FAULT,
            .ISCONN,
            .NOTSOCK,
            .PROTOTYPE,
            => |err| errnoBug(err),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn addBuf(v: []posix.iovec_const, i: *@FieldType(posix.msghdr_const, "iovlen"), bytes: []const u8) void {
    // OS checks ptr addr before length so zero length vectors must be omitted.
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
    i.* += 1;
}

fn netListenIp(_: ?*anyopaque, address: *const IpAddress, options: IpAddress.ListenOptions) IpAddress.ListenError!net.Socket {
    const family = posixAddressFamily(address);
    const socket_fd = try openSocketPosix(family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer closeFd(socket_fd);

    if (options.reuse_address) {
        try setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
        if (@hasDecl(posix.SO, "REUSEPORT"))
            try setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, 1);
    }

    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try bind(socket_fd, &storage.any, addr_len);

    while (true) {
        switch (posix.errno(posix.system.listen(socket_fd, options.kernel_backlog))) {
            .SUCCESS => break,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    try posixGetSockName(socket_fd, &storage.any, &addr_len);
    return .{
        .handle = socket_fd,
        .address = addressFromPosix(&storage),
    };
}

fn netListenUnix(_: ?*anyopaque, address: *const net.UnixAddress, options: net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const socket_fd = openSocketPosix(posix.AF.UNIX, .{ .mode = .stream }) catch |err| switch (err) {
        error.ProtocolUnsupportedBySystem => return error.AddressFamilyUnsupported,
        error.SocketModeUnsupported => return error.AddressFamilyUnsupported,
        else => |e| return e,
    };
    errdefer closeFd(socket_fd);

    var storage: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(address, &storage);
    try bindUnix(socket_fd, &storage.any, addr_len);

    while (true) {
        return switch (posix.errno(posix.system.listen(socket_fd, options.kernel_backlog))) {
            .SUCCESS => break,
            .INTR => continue,

            .ADDRINUSE => error.AddressInUse,

            .BADF => |err| errnoBug(err), // File descriptor used after closed.

            else => |err| posix.unexpectedErrno(err),
        };
    }

    return socket_fd;
}

fn netAccept(userdata: ?*anyopaque, listen_fd: net.Socket.Handle, _: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
    const co: *AnyCoroutine = @ptrCast(@alignCast(userdata));

    var storage: PosixAddress = undefined;
    var addr_len: posix.socklen_t = @sizeOf(PosixAddress);

    const fd = while (true) {
        const rc = if (have_accept4)
            posix.system.accept4(
                listen_fd,
                &storage.any,
                &addr_len,
                posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            )
        else
            posix.system.accept(listen_fd, &storage.any, &addr_len);
        return switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(rc);
                errdefer closeFd(fd);
                if (!have_accept4) try setSockFlags(fd);
                break fd;
            },
            .INTR => continue,
            .AGAIN => {
                try co.yield();
                continue;
            },

            .CONNABORTED => error.ConnectionAborted,
            .INVAL => error.SocketNotListening,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .PROTO => error.ProtocolFailure,
            .PERM => error.BlockedByFirewall,

            .BADF, // File descriptor used after closed.
            .FAULT,
            .NOTSOCK,
            .OPNOTSUPP,
            => |err| errnoBug(err),

            else => |err| posix.unexpectedErrno(err),
        };
    };
    return .{
        .handle = fd,
        .address = addressFromPosix(&storage),
    };
}

fn netBindIp(_: ?*anyopaque, address: *const IpAddress, options: IpAddress.BindOptions) IpAddress.BindError!net.Socket {
    const family = posixAddressFamily(address);
    const socket_fd = try openSocketPosix(family, options);
    errdefer closeFd(socket_fd);

    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try bind(socket_fd, &storage.any, addr_len);
    if (options.allow_broadcast) try setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.BROADCAST, 1);
    try posixGetSockName(socket_fd, &storage.any, &addr_len);

    return .{
        .handle = socket_fd,
        .address = addressFromPosix(&storage),
    };
}

fn netConnectIp(userdata: ?*anyopaque, address: *const IpAddress, options: IpAddress.ConnectOptions) IpAddress.ConnectError!net.Socket {
    const co: *AnyCoroutine = @ptrCast(@alignCast(userdata));
    const family = posixAddressFamily(address);
    const socket_fd = try openSocketPosix(family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer closeFd(socket_fd);
    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try connect(co, socket_fd, &storage.any, addr_len, options.timeout);
    try posixGetSockName(socket_fd, &storage.any, &addr_len);
    return .{
        .handle = socket_fd,
        .address = addressFromPosix(&storage),
    };
}

fn netConnectUnix(userdata: ?*anyopaque, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const co: *AnyCoroutine = @ptrCast(@alignCast(userdata));
    const socket_fd = openSocketPosix(posix.AF.UNIX, .{ .mode = .stream }) catch |err| switch (err) {
        else => |e| return e,
    };
    errdefer closeFd(socket_fd);
    var storage: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(address, &storage);
    try connectUnix(co, socket_fd, &storage.any, addr_len);
    return socket_fd;
}

fn netSocketCreatePair(_: ?*anyopaque, options: net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket {
    if (@TypeOf(posix.system.socketpair) == void) return error.OperationUnsupported;

    const family: posix.sa_family_t = switch (options.family) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const mode, const protocol = try posixSocketModeProtocol(family, options.mode, options.protocol);
    const flags: u32 = mode | if (socket_flags_unsupported) 0 else (posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);

    var sockets: [2]posix.socket_t = undefined;
    while (true) {
        return switch (posix.errno(posix.system.socketpair(family, flags, protocol, &sockets))) {
            .SUCCESS => {
                errdefer {
                    closeFd(sockets[0]);
                    closeFd(sockets[1]);
                }
                if (socket_flags_unsupported) {
                    try setSockFlags(sockets[0]);
                    try setSockFlags(sockets[1]);
                }
                var storages: [2]PosixAddress = undefined;
                var addr_len: posix.socklen_t = @sizeOf(PosixAddress);
                try posixGetSockName(sockets[0], &storages[0].any, &addr_len);
                try posixGetSockName(sockets[1], &storages[1].any, &addr_len);
                return .{
                    .{ .handle = sockets[0], .address = addressFromPosix(&storages[0]) },
                    .{ .handle = sockets[1], .address = addressFromPosix(&storages[1]) },
                };
            },
            .INTR => continue,

            .ACCES => error.AccessDenied,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .INVAL => error.ProtocolUnsupportedBySystem,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            .PROTONOSUPPORT => error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => error.SocketModeUnsupported,

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn netClose(_: ?*anyopaque, handles: []const net.Socket.Handle) void {
    for (handles) |handle| closeFd(handle);
}

fn netShutdown(_: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    const posix_how: i32 = switch (how) {
        .recv => posix.SHUT.RD,
        .send => posix.SHUT.WR,
        .both => posix.SHUT.RDWR,
    };

    while (true) {
        return switch (posix.errno(posix.system.shutdown(handle, posix_how))) {
            .SUCCESS => {},
            .INTR => continue,

            .NOTCONN => return error.SocketUnconnected,
            .NOBUFS => return error.SystemResources,

            .BADF, .NOTSOCK, .INVAL => |err| errnoBug(err),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn netRead(ud: ?*anyopaque, fd: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));

    var iovecs_buffer: [Threaded.max_iovecs_len]posix.iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    const dest = iovecs_buffer[0..i];
    assert(dest[0].len > 0);

    while (true) {
        const rc = posix.system.readv(fd, dest.ptr, @intCast(dest.len));
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,

            .AGAIN => {
                try co.yield();
                continue;
            },

            .NOBUFS, .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.Timeout,
            .PIPE => error.SocketUnconnected,
            .NETDOWN => error.NetworkDown,
            .INVAL, .FAULT, .BADF => |err| errnoBug(err), // File descriptor used after closed.

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn netWrite(ud: ?*anyopaque, fd: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));

    var iovecs: [Threaded.max_iovecs_len]posix.iovec_const = undefined;
    var msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = 0,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    addBuf(&iovecs, &msg.iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &msg.iovlen, bytes);
    const pattern = data[data.len - 1];

    var splat_backup_buffer: [Threaded.splat_buffer_size]u8 = undefined;
    if (iovecs.len - msg.iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &msg.iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &splat_backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(&iovecs, &msg.iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - msg.iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(&iovecs, &msg.iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(&iovecs, &msg.iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                addBuf(&iovecs, &msg.iovlen, pattern);
            },
        },
    };
    const flags = posix.MSG.NOSIGNAL;

    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, flags);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .AGAIN => {
                try co.yield();
                continue;
            },

            .ALREADY => error.FastOpenAlreadyInProgress,
            .CONNRESET => error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => error.SystemResources,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .HOSTUNREACH => error.HostUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .PIPE, .NOTCONN => error.SocketUnconnected,
            .NETDOWN => error.NetworkDown,

            .ACCES,
            .BADF, // File descriptor used after closed.
            .DESTADDRREQ, // The socket is not connection-mode, and no peer address is set.
            .FAULT, // An invalid user space address was specified for an argument.
            .INVAL, // Invalid argument passed.
            .ISCONN, // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE,
            .NOTSOCK, // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP,
            => |err| errnoBug(err), // Some bit in the flags argument is inappropriate for the socket type.

            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn netWriteFileUnimplemented(
    ud: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    reader: *Io.File.Reader,
    limit: Io.Limit,
) net.Stream.Writer.WriteFileError!usize {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));
    _ = co;
    _ = handle;
    _ = header;
    _ = reader;
    _ = limit;
    @panic("TODO: Implement netWriteFile");
}

fn netSendOne(co: *AnyCoroutine, socket_handle: net.Socket.Handle, message: *net.OutgoingMessage, flags: u32) net.Socket.SendError!void {
    var addr: PosixAddress = undefined;
    var iovec: posix.iovec_const = .{ .base = @constCast(message.data_ptr), .len = message.data_len };
    const msg: posix.msghdr_const = .{
        .name = &addr.any,
        .namelen = addressToPosix(message.address, &addr),
        .iov = (&iovec)[0..1],
        .iovlen = 1,
        // OS returns EINVAL if this pointer is invalid even if controllen is zero.
        .control = if (message.control.len == 0) null else @constCast(message.control.ptr),
        .controllen = @intCast(message.control.len),
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.sendmsg(socket_handle, &msg, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                message.data_len = @intCast(rc);
                return;
            },
            .INTR => continue,
            .AGAIN => {
                try co.yield();
                continue;
            },

            .ACCES => return error.AccessDenied,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .CONNRESET => return error.ConnectionResetByPeer,
            .MSGSIZE => return error.MessageOversize,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PIPE => return error.SocketUnconnected,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketUnconnected,
            .NETDOWN => return error.NetworkDown,

            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .DESTADDRREQ => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ISCONN => |err| return errnoBug(err),
            .NOTSOCK => |err| return errnoBug(err),
            .OPNOTSUPP => |err| return errnoBug(err),
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn netSendMany(co: *AnyCoroutine, socket_handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: u32) net.Socket.SendError!usize {
    var msg_buffer: [64]posix.system.mmsghdr = undefined;
    var addr_buffer: [msg_buffer.len]PosixAddress = undefined;
    var iovecs_buffer: [msg_buffer.len]posix.iovec = undefined;
    const min_len: usize = @min(messages.len, msg_buffer.len);
    const clamped_messages = messages[0..min_len];
    const clamped_msgs = (&msg_buffer)[0..min_len];
    const clamped_addrs = (&addr_buffer)[0..min_len];
    const clamped_iovecs = (&iovecs_buffer)[0..min_len];

    for (clamped_messages, clamped_msgs, clamped_addrs, clamped_iovecs) |*message, *msg, *addr, *iovec| {
        iovec.* = .{ .base = @constCast(message.data_ptr), .len = message.data_len };
        msg.* = .{
            .hdr = .{
                .name = &addr.any,
                .namelen = addressToPosix(message.address, addr),
                .iov = iovec[0..1],
                .iovlen = 1,
                .control = @constCast(message.control.ptr),
                .controllen = message.control.len,
                .flags = 0,
            },
            .len = undefined, // Populated by calling sendmmsg below.
        };
    }

    while (true) {
        const rc = posix.system.sendmmsg(socket_handle, clamped_msgs.ptr, @intCast(clamped_msgs.len), flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                for (clamped_messages[0..n], clamped_msgs[0..n]) |*message, *msg| {
                    message.data_len = msg.len;
                }
                return n;
            },
            .INTR => continue,
            .AGAIN => {
                try co.yield();
                continue;
            },

            .ACCES => return error.AccessDenied,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .CONNRESET => return error.ConnectionResetByPeer,
            .MSGSIZE => return error.MessageOversize,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PIPE => return error.SocketUnconnected,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketUnconnected,
            .NETDOWN => return error.NetworkDown,

            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .DESTADDRREQ => |err| return errnoBug(err), // The socket is not connection-mode, and no peer address is set.
            .FAULT => |err| return errnoBug(err), // An invalid user space address was specified for an argument.
            .INVAL => |err| return errnoBug(err), // Invalid argument passed.
            .ISCONN => |err| return errnoBug(err), // connection-mode socket was connected already but a recipient was specified
            .NOTSOCK => |err| return errnoBug(err), // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => |err| return errnoBug(err), // Some bit in the flags argument is inappropriate for the socket type.

            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn netSend(ud: ?*anyopaque, handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    const co: *AnyCoroutine = @ptrCast(@alignCast(ud));

    const posix_flags: u32 =
        @as(u32, if (@hasDecl(posix.MSG, "CONFIRM") and flags.confirm) posix.MSG.CONFIRM else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "DONTROUTE") and flags.dont_route) posix.MSG.DONTROUTE else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "EOR") and flags.eor) posix.MSG.EOR else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "OOB") and flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "FASTOPEN") and flags.fastopen) posix.MSG.FASTOPEN else 0) |
        posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT;

    var i: usize = 0;
    while (messages.len - i != 0) {
        if (have_sendmmsg) {
            i += netSendMany(co, handle, messages[i..], posix_flags) catch |err| return .{ err, i };
            continue;
        }
        netSendOne(co, handle, &messages[i], posix_flags) catch |err| return .{ err, i };
        i += 1;
    }
    return .{ null, i };
}

fn netReceive(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    message: *net.IncomingMessage,
    data_buffer: []u8,
    flags: net.ReceiveFlags,
) net.Socket.ReceiveError!void {
    const co: *AnyCoroutine = @ptrCast(@alignCast(userdata));

    // recvmmsg is useless, here's why:
    // * [timeout bug](https://bugzilla.kernel.org/show_bug.cgi?id=75371)
    // * it wants iovecs for each message but we have a better API: one data
    //   buffer to handle all the messages. The better API cannot be lowered to
    //   the split vectors though because reducing the buffer size might make
    //   some messages unreceivable.
    const posix_flags: u32 =
        @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (flags.peek) posix.MSG.PEEK else 0) |
        @as(u32, if (flags.trunc) posix.MSG.TRUNC else 0) |
        posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT;

    var storage: PosixAddress = undefined;
    var iov: posix.iovec = .{ .base = data_buffer.ptr, .len = data_buffer.len };
    var msg: posix.msghdr = .{
        .name = &storage.any,
        .namelen = @sizeOf(PosixAddress),
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = message.control.ptr,
        .controllen = @intCast(message.control.len),
        .flags = undefined,
    };

    while (true) {
        const rc = posix.system.recvmsg(handle, &msg, posix_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const data = data_buffer[0..@intCast(rc)];
                message.* = .{
                    .from = addressFromPosix(&storage),
                    .data = data,
                    .control = if (msg.control) |ptr| @as([*]u8, @ptrCast(ptr))[0..msg.controllen] else message.control,
                    .flags = .{
                        .eor = (msg.flags & posix.MSG.EOR) != 0,
                        .trunc = (msg.flags & posix.MSG.TRUNC) != 0,
                        .ctrunc = (msg.flags & posix.MSG.CTRUNC) != 0,
                        .oob = (msg.flags & posix.MSG.OOB) != 0,
                        .errqueue = if (@hasDecl(posix.MSG, "ERRQUEUE")) (msg.flags & posix.MSG.ERRQUEUE) != 0 else false,
                    },
                };
                return;
            },
            .INTR => continue,
            .AGAIN => {
                try co.yield();
                continue;
            },

            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .MSGSIZE => return error.MessageOversize,
            .PIPE => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NETDOWN => return error.NetworkDown,

            .BADF => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .NOTSOCK => |err| return errnoBug(err),
            .OPNOTSUPP => |err| return errnoBug(err),
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn netInterfaceNameResolve(_: ?*anyopaque, name: *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface {
    const sock_fd = openSocketPosix(posix.AF.UNIX, .{ .mode = .dgram }) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded => return error.SystemResources,
        error.SystemFdQuotaExceeded => return error.SystemResources,
        error.AddressFamilyUnsupported => return error.Unexpected,
        error.ProtocolUnsupportedBySystem => return error.Unexpected,
        error.SocketModeUnsupported => return error.Unexpected,
        else => |e| return e,
    };
    defer closeFd(sock_fd);

    var ifr: posix.ifreq = .{
        .ifrn = .{ .name = @bitCast(name.bytes) },
        .ifru = undefined,
    };

    while (true) {
        return switch (posix.errno(posix.system.ioctl(sock_fd, posix.SIOCGIFINDEX, @intFromPtr(&ifr)))) {
            .SUCCESS => .{ .index = @bitCast(ifr.ifru.ivalue) },
            .INTR => continue,
            .NODEV => error.InterfaceNotFound,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn netInterfaceNameUnimplemented(
    userdata: ?*anyopaque,
    interface: net.Interface,
) net.Interface.NameError!net.Interface.Name {
    _ = userdata;
    _ = interface;
    @panic("TODO: Implemente netInterfaceName");
}

fn netLookupUnimplemented(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) net.HostName.LookupError!void {
    const co: *AnyCoroutine = @ptrCast(@alignCast(userdata));
    _ = co;
    _ = host_name;
    _ = resolved;
    _ = options;
    @panic("TODO: Implement netLookup");
}
//#endregion net

pub const vtable = blk: {
    var res: Io.VTable = Io.failing.vtable.*;
    res.checkCancel = checkCancel;
    res.operate = operate;
    res.now = now;
    res.clockResolution = clockResolution;
    res.sleep = sleep;
    res.netListenIp = netListenIp;
    res.netListenUnix = netListenUnix;
    res.netAccept = netAccept;
    res.netBindIp = netBindIp;
    res.netConnectIp = netConnectIp;
    res.netConnectUnix = netConnectUnix;
    res.netSocketCreatePair = netSocketCreatePair;
    res.netRead = netRead;
    res.netWrite = netWrite;
    res.netClose = netClose;
    res.netSend = netSend;
    res.netShutdown = netShutdown;
    res.netWriteFile = netWriteFileUnimplemented;
    res.netInterfaceNameResolve = netInterfaceNameResolve;
    res.netInterfaceName = netInterfaceNameUnimplemented;
    res.netLookup = netLookupUnimplemented;
    break :blk res;
};

pub fn cancel(self: *@This()) void {
    self.canceled = true;
}
