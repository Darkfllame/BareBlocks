const tui = @This();
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");

const atomic = std.atomic;
const Io = std.Io;
const posix = std.posix;
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

var instance: ?*tui = null;

fn swapStdHandle(which: enum { in, out, err }, new: Io.File) error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected }!Io.File {
    if (builtin.target.os.tag == .windows) {
        const proc_params = windows.peb().ProcessParameters;
        const ptr = switch (which) {
            .in => &proc_params.hStdInput,
            .out => &proc_params.hStdOutput,
            .err => &proc_params.hStdError,
        };
        const old = Io.File{
            .handle = @atomicRmw(windows.HANDLE, ptr, .Xchg, new.handle, .monotonic),
            .flags = .{ .nonblocking = false },
        };
        return old;
    }

    const orig_fd = switch (which) {
        .in => Io.File.stdin().handle,
        .out => Io.File.stdout().handle,
        .err => Io.File.stderr().handle,
    };
    const duped_fd: posix.fd_t = dup: while (true) {
        const res = posix.system.dup(orig_fd);
        switch (posix.errno(res)) {
            .SUCCESS => break :dup @intCast(res),
            .BUSY, .INTR => continue,
            .FAULT => unreachable,
            .BADF => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| posix.unexpectedErrno(err),
        }
    };
    errdefer Io.Threaded.closeFd(duped_fd);
    while (true) switch (posix.errno(posix.system.dup2(new.handle, orig_fd))) {
        .SUCCESS => break,
        .BUSY, .INTR => continue,
        .FAULT => unreachable,
        .BADF => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };

    return .{
        .handle = duped_fd,
        .flags = .{ .nonblocking = false },
    };
}

refc: atomic.Value(usize) = .init(1),
ready: Io.Event = .unset,

io: Io,
allocator: Allocator,

mutex: Io.Mutex = .init,
stdin: Io.File,
stdout: Io.File,
stderr: Io.File,

pub fn init(io: Io, allocator: Allocator) !void {
    if (@atomicLoad(?*tui, &instance, .seq_cst)) |old| {
        _=old.refc.fetchAdd(1, .monotonic);
        return;
    }

    const self = try allocator.create(tui);
    errdefer allocator.destroy(self);
    self.* = .{
        .io = io,
        .allocator = allocator,

        .stdin = undefined,
        .stdout = undefined,
        .stderr = undefined,
    };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (@cmpxchgStrong(?*tui, &instance, null, self, .acquire, .monotonic)) |old| {
        _=old.?.refc.fetchAdd(1, .monotonic);
        allocator.destroy(self);
        return;
    }

    // TODO: init
}

pub fn deinit() void {
    const self = @atomicLoad(?*tui, &instance, .monotonic) orelse return;
    self.ready.waitUncancelable(self.io);

    if (self.refc.fetchSub(1, .acquire) > 1) return;
    if (@cmpxchgStrong(?*tui, &instance, self, null, .acquire, .monotonic)) |old| {
        assert(old == null);
        return;
    }

    // TODO: deinit
}

test {
    std.testing.refAllDecls(@This());
}
