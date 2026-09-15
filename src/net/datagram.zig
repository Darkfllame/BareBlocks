const std = @import("std");

const Threaded = std.Io.Threaded;
const posix = std.posix;
const Io = std.Io;

const socket_flags_unsupported = Threaded.socket_flags_unsupported;
const PosixAddress = Threaded.PosixAddress;
const recoverableOsBugDetected = Threaded.recoverableOsBugDetected;
const addressToPosix = Threaded.addressToPosix;
const addressFromPosix = Threaded.addressFromPosix;
const closeFd = Threaded.closeFd;
const errnoBug = Threaded.errnoBug;

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

fn bind(socket_fd: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) !void {
    while (true) {
        return switch (posix.errno(posix.system.bind(socket_fd, addr, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,

            .ADDRINUSE => error.AddressInUse,
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

pub const SocketError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    SystemResources,
    AddressInUse,
    AddressUnavailable,
    Unexpected,
};

pub const Socket = Io.net.Socket;

pub fn socket(bind_addr: ?*const Io.net.IpAddress, multicast: bool, broadcast: bool) SocketError!Socket {
    const flags = posix.SOCK.DGRAM | if (socket_flags_unsupported)
        0
    else
        (posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);

    const fd: posix.socket_t = loop: while (true) {
        const rc = posix.system.socket(posix.AF.INET, flags, posix.IPPROTO.UDP);
        return switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(rc);
                errdefer closeFd(fd);
                if (socket_flags_unsupported) try setSockFlags(fd);
                break :loop fd;
            },
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    };
    errdefer closeFd(fd);

    var z_addr = Io.net.IpAddress{.ip4 = .unspecified(0)};

    if (multicast) {
        try setSocketOption(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
        if (@hasDecl(posix.SO, "REUSEPORT"))
            try setSocketOption(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, 1);
    }

    if (broadcast) {
        try setSocketOption(fd, posix.SOL.SOCKET, posix.SO.BROADCAST, 1);
    }

    if (bind_addr) |addr| {
        var storage: PosixAddress = undefined;
        var len = addressToPosix(addr, &storage);
        try bind(fd, &storage.any, len);
        try posixGetSockName(fd, &storage.any, &len);
        z_addr = addressFromPosix(&storage);
    }

    return .{
        .handle = fd,
        .address = z_addr,
    };
}

pub fn close(sock: Socket) void {
    return closeFd(sock.handle);
}