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

const LogScope = struct {
    rwl: Io.RwLock = .init,
    /// At best should only be comparable with a simple `==`
    name: [:0]const u8,
    last_activity: Io.Timestamp,
};

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

fn logFnInner(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) !void {
    _ = level; // autofix
    _ = scope; // autofix
    _ = format; // autofix
    _ = args; // autofix
    const self = @atomicLoad(?*tui, &instance, .monotonic) orelse return error.LogFailed;
    try self.ready.wait(self.io);

    // TODO: Logging
}

fn getScope(self: *tui, name: [:0]const u8) !*LogScope {
    const next_scope = self.used_scopes.fetchAdd(1, .monotonic);
    if (next_scope < self.config.max_scopes_count) @compileError("TODO");

    while (true) {
        try self.scope_lock.lockShared(self.io);
        defer self.scope_lock.unlockShared(self.io);

        var oldest_scope: ?*LogScope = null;

        for (self.scopes) |*scope| {
            try scope.rwl.lockShared(self.io);
            defer scope.rwl.unlockShared(self.io);
            
            if (scope.name.ptr == name.ptr) {
                scope.last_activity.nanoseconds = std.math.maxInt(i96);
                return scope;
            }
            if (oldest_scope == null or scope.last_activity.nanoseconds < oldest_scope.?.last_activity.nanoseconds) {
                oldest_scope = scope;
            }
        }

        const old = oldest_scope.?;
        try old.rwl.lock(self.io);
        defer old.rwl.unlock(self.io);

        if (scope.name.ptr != name.ptr) continue;


    }
}

fn initInner(self: *tui, io: Io, allocator: Allocator, config: Config) !void {
    self.* = .{
        .io = io,
        .allocator = allocator,

        .stdin = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .config = config,
    };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
}

fn deinitInner(self: *tui) void {
    _ = self; // autofix

}

io: Io,
allocator: Allocator,

draw: Io.Event = .unset,
ready: Io.Event = .unset,

mutex: Io.Mutex = .init,
stdin: Io.File,
stdout: Io.File,
stderr: Io.File,
config: Config,

scope_lock: Io.RwLock,
used_scopes: std.atomic.Value(usize),
scopes: []LogScope,

pub const Config = struct {
    /// The maximum number of bytes a single command line can be.
    max_input_length: usize = 1024,
    /// The maximum number of commands the input can remember before deleting older ones.
    max_input_history: usize = 64,
    /// The maximum of std.log.scoped(.<scope>) that can be active at the same time.
    max_scopes_count: usize = 32,
};

pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    return logFnInner(level, scope, format, args) catch std.log.defaultLog(level, scope, format, args);
}

pub fn init(io: Io, allocator: Allocator, config: Config) !void {
    const self = try allocator.create(tui);
    errdefer allocator.destroy(self);
    try self.initInner(io, allocator, config);
    errdefer self.deinitInner();

    if (@cmpxchgStrong(?*tui, &instance, null, self, .acquire, .monotonic)) |old| {
        _ = old; // autofix
        return error.AlreadyInitialized;
    }
}

pub fn deinit() void {
    const self = @atomicLoad(?*tui, &instance, .monotonic) orelse return;
    assert(self.ready.isSet());

    if (@cmpxchgStrong(?*tui, &instance, self, null, .acquire, .monotonic)) |old| {
        assert(old == null);
        return;
    }

    // TODO: deinit
}

test {
    std.testing.refAllDecls(@This());
}
