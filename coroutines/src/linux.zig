const std = @import("std");
const private = @import("private.zig");

const linux = std.os.linux;
const posix = std.posix;
const system = posix.system;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;

const assert = std.debug.assert;
const timestampToPosix = private.timestampToPosix;
const clockToPosix = private.clockToPosix;
const errno = system.errno;

const do_epoll = private.is_linux;

fn close_fd(fd: i32) void {
    return switch (errno(system.close(fd))) {
        .SUCCESS, .INTR => {},
        else => unreachable,
    };
}

pub const EPollFD = enum(posix.fd_t) {
    _,

    pub const CreateError = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources };
    pub const ControlError = error{ Duplicate, NotFound, SystemResources };

    pub fn create(cloexec: bool) CreateError!EPollFD {
        while (true) {
            const rc = system.epoll_create1(@intFromBool(cloexec) * linux.EPOLL.CLOEXEC);
            return switch (errno(rc)) {
                .SUCCESS => @enumFromInt(rc),
                .INTR => continue,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => unreachable,
            };
        }
    }

    pub inline fn close(self: EPollFD) void {
        return close_fd(@intFromEnum(self));
    }

    pub fn control(
        self: EPollFD,
        op: enum(u8) {
            add = linux.EPOLL.CTL_ADD,
            delete = linux.EPOLL.CTL_DEL,
            modify = linux.EPOLL.CTL_MOD,
        },
        fd: posix.fd_t,
        event: linux.epoll_event,
    ) ControlError!void {
        while (true) {
            return switch (errno(system.epoll_ctl(
                @intFromEnum(self),
                @intFromEnum(op),
                fd,
                @constCast(&event),
            ))) {
                .SUCCESS => {},
                .INTR => continue,
                .EXIST => error.Duplicate,
                .NOENT => error.NotFound,
                .NOMEM => error.SystemResources,
                else => unreachable,
            };
        }
    }

    pub fn wait(self: EPollFD, events: []linux.epoll_event, timeout_ms: i32) usize {
        while (true) {
            const rc = system.epoll_wait(
                @intFromEnum(self),
                events.ptr,
                @intCast(events.len),
                timeout_ms,
            );
            return switch (errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                else => unreachable,
            };
        }
    }
};

pub const TimerFD = struct {
    fd: posix.fd_t,
    clock: if (private.is_debug) Io.Clock else void,

    pub const CreateError = error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        NoDevice,
        PermissionDenied,
    };

    pub fn create(clock: Io.Clock, cloexec: bool) TimerFD {
        var res: TimerFD = undefined;
        if (private.is_debug) {
            res.clock = clock;
        }
        while (true) {
            const rc = system.timerfd_create(clockToPosix(clock), linux.TFD{ .CLOEXEC = cloexec });
            return switch (errno(rc)) {
                .SUCCESS => {
                    res.fd = rc;
                    return res;
                },
                .INTR => continue,

                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NODEV => error.NoDevice,
                .NOMEM => error.SystemResources,
                .PERM => error.PermissionDenied,

                else => unreachable,
            };
        }
    }

    pub inline fn close(self: EPollFD) void {
        return close_fd(self.fd);
    }

    pub fn setTime(self: TimerFD, timeout: Io.Timeout, interval: Io.Duration) void {
        var tspec: linux.itimerspec = .{
            .it_interval = timestampToPosix(interval.nanoseconds),
            .it_value = undefined,
        };
        var flags: linux.TFD.TIMER = .{};
        switch (timeout) {
            .none => {
                tspec.it_value = .{
                    .sec = 0,
                    .nsec = 0,
                };
            },
            .duration => |d| {
                if (private.is_debug) assert(self.clock == d.clock);
                tspec.it_value = timestampToPosix(d.raw.nanoseconds);
            },
            .deadline => |d| {
                if (private.is_debug) assert(self.clock == d.clock);
                tspec.it_value = timestampToPosix(d.raw.nanoseconds);
                flags.ABSTIME = true;
            },
        }
        while (true) {
            const rc = system.timerfd_settime(@intFromEnum(self), flags, &tspec, null);
            return switch (errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,

                else => unreachable,
            };
        }
    }

    pub fn getTime(self: TimerFD) Io.Duration {
        var tspec: linux.itimerspec = undefined;
        while (true) {
            const rc = system.timerfd_gettime(@intFromEnum(self), &tspec);
            return switch (errno(rc)) {
                .SUCCESS => .{ .nanoseconds = private.nanosecondsFromPosix(&tspec.it_value) },
                .INTR => continue,

                else => unreachable,
            };
        }
    }
};
