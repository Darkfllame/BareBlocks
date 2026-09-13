const std = @import("std");
const builtin = @import("builtin");
const linux_fd = @import("linux.zig");
const private = @import("private.zig");

const posix = std.posix;
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Stream = std.Io.net.Stream;
const Socket = std.Io.net.Socket;
const IpAddress = std.Io.net.IpAddress;
const assert = std.debug.assert;
const POLL = posix.POLL;
const EPOLL = linux.EPOLL;

const do_epoll = private.is_linux;
const EventInt = if (do_epoll) u32 else i16;

const logger = std.log.scoped(.poller);

fn fromPosixEvents(ev: EventInt) Events {
    return .{
        .out = (ev & POLL.OUT) != 0,
        .in = (ev & POLL.IN) != 0,
        .pri = (ev & POLL.PRI) != 0,

        .hang_up = (ev & POLL.HUP) != 0,
        .err = (ev & (POLL.ERR | POLL.NVAL)) != 0,
    };
}

fn toPosixEvents(ev: Events) EventInt {
    return @as(EventInt, @intFromBool(ev.in)) * POLL.IN |
        @as(EventInt, @intFromBool(ev.out)) * POLL.OUT |
        @as(EventInt, @intFromBool(ev.pri)) * POLL.PRI;
}

pub const CreateError = Allocator.Error || error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources };
pub const AddError = Allocator.Error || error{ Duplicate, SystemResources };
pub const WaitError = error{SystemResources};

pub const PollerType = enum {
    /// Uses `poll()` and file descriptors.
    ///
    /// Allow you to use `addFd`, `modifyFd` and `removeFd`.
    posix,
    /// An implementation specific to windows, because polling files
    /// and sockets use different functions, smh.
    windows,
    /// Uses `epoll()` and file descriptors, `epoll()` is only
    /// available on Linux and is generally more efficient than
    /// regular `poll()`.
    ///
    /// Allow you to use `addFd`, `modifyFd` and `removeFd`.
    epoll,
};

pub const Events = packed struct {
    in: bool = false,
    out: bool = false,
    pri: bool = false,

    /// Returned in `PollEvent(T)`
    ///
    /// Peer closed their writing end of the connection.
    ///
    /// Invalid Socket/File
    hang_up: bool = false,
    /// Returned in `PollEvent(T)`
    ///
    /// Invalid Socket/File
    err: bool = false,

    /// Used by `EPoll` as input. Never returned.
    ///
    /// Makes events only trigger when **NEW** data is
    /// available. This means that the user **MUST** read all
    /// data available greedily until `EndOfStream` or `WouldBlock` is
    /// returned.
    ///
    /// Should be used with non-blocking sockets/files
    edge_triggered: bool = false,
    /// Used by `EPoll` as input.
    /// 
    /// Signals the other end closed end of the connection.
    read_hang_up: bool = false,

    pub const rw = Events{ .in = true, .out = true };
    pub const readonly = Events{ .in = true };
    pub const writeonly = Events{ .out = true };

    pub fn format(self: Events, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const info = @typeInfo(@This()).@"struct";
        const BackInt = info.backing_integer.?;
        const max_back = std.math.maxInt(BackInt);
        const bits: BackInt = @bitCast(self);
        try writer.writeAll("{ ");
        inline for (info.fields) |f| {
            const offset = @bitOffsetOf(@This(), f.name);
            const rem_mask = (max_back << (offset + 1)) & max_back;
            const can_have_next = (offset + 1) < @bitSizeOf(BackInt);
            if (@field(self, f.name)) try writer.writeAll(f.name);
            if (can_have_next and bits & rem_mask != 0 and (bits >> (offset + 1)) & 1 != 0) try writer.writeAll(" | ");
        }
        if (bits != 0) try writer.writeByte(' ');
        try writer.writeByte('}');
    }
};

pub fn PollEvent(comptime Userdata: type) type {
    return struct {
        data: Userdata,
        /// If `err` is set, continue with operations as
        /// they will give more information.
        events: Events,
    };
}

pub const Poller = switch (private.os_tag) {
    .linux => EPoll,
    // .freebsd, .netbsd, .macos => PosixPoll,
    else => |tag| @compileError("Not Yet Implemented: " ++ @tagName(tag)),
};

pub fn PosixPoll(comptime Userdata: type) type {
    return struct {
        const Self = @This();

        const elems_per_grow = 8;

        // I'd like to optimize memory usage for this but realistically
        // it should only be instanced at most a few times, so I think this is fine.
        fds: std.ArrayList(posix.pollfd) = .empty,
        used: std.DynamicBitSetUnmanaged = .{},
        datas: std.ArrayList(Userdata) = .empty,

        /// Used to identify the implementation of the current poller,
        /// useful for platform-specific optimizations.
        comptime poller_type: PollerType = .posix,

        /// If `poller_type == .posix`
        pub fn addFd(self: *Self, allocator: Allocator, fd: posix.fd_t, events: Events, data: Userdata) AddError!void {
            var dupe_it = self.used.iterator(.{});
            while (dupe_it.next()) |idx| {
                if (self.fds.items[idx].fd == fd) return error.Duplicate;
            }

            var search_it = self.used.iterator(.{ .kind = .unset });
            const idx = search_it.next() orelse grow: {
                try self.fds.ensureUnusedCapacity(allocator, elems_per_grow);
                try self.datas.ensureUnusedCapacity(allocator, elems_per_grow);
                const idx = self.used.bit_length;
                try self.used.resize(allocator, idx + elems_per_grow, false);
                break :grow idx;
            };

            self.fds.items[idx] = .{
                .fd = fd,
                .events = toPosixEvents(events),
                .revents = undefined,
            };
            self.datas.items[idx] = data;

            self.used.set(idx);
        }

        /// If `poller_type == .posix`
        pub fn modifyFd(self: *Self, fd: posix.fd_t, events: ?Events, data: ?Userdata) void {
            assert(events != null or data != null);

            var iter = self.used.iterator(.{});

            while (iter.next()) |idx| {
                const pfd = &self.fds.items[idx];
                const udp = &self.datas.items[idx];
                if (pfd.fd != fd) continue;

                if (events) |ev| {
                    pfd.events = toPosixEvents(ev);
                }
                if (data) |ud| {
                    udp.* = ud;
                }

                break;
            } else unreachable; // IO Object not found
        }

        /// If `poller_type == .posix`
        pub fn removeFd(self: *Self, fd: posix.fd_t) Userdata {
            var iter = self.used.iterator(.{});

            while (iter.next()) |idx| {
                const pfd = &self.fds.items[idx];
                const ud = self.datas.items[idx];
                if (pfd.fd != fd) continue;

                self.used.unset(idx);
                pfd.fd = -1; // poll() ignores negative fd's

                return ud;
            } else unreachable; // IO Object not found
        }

        //#region Common API

        pub const EventIterator = struct {
            self: *const Self,
            signaled_n: usize,
            count: usize = 0,
            index: usize = 0,

            pub fn next(it: *EventIterator) ?PollEvent(Userdata) {
                const self = it.self;
                const pfds = self.fds.items;

                while (it.count < it.signaled_n) {
                    const idx = it.index;
                    const pfd = pfds[idx];
                    it.index += 1;
                    if (pfd.revents == 0) continue;
                    it.count += 1;

                    if (!self.used.isSet(idx)) continue; // Shouldn't get to here but heh

                    if (pfd.revents & POLL.NVAL != 0) {
                        logger.warn("Invalid file descriptor #{d}: {d}", .{ idx, pfd.fd });
                        pfd.fd = -1;
                        continue;
                    }

                    return .{
                        .data = self.datas.items[idx],
                        .events = fromPosixEvents(pfd.revents),
                    };
                }

                return null;
            }
        };

        pub inline fn init() CreateError!Self {
            return initCapacity(.failing, 0);
        }

        pub fn initCapacity(allocator: Allocator, capacity: usize) CreateError!Self {
            var self: Self = .{};
            errdefer self.deinit(allocator);
            try self.fds.ensureTotalCapacity(allocator, capacity);
            // Technically, self.used.bit_length could server as a capacity for both
            // fds and datas
            try self.used.resize(allocator, capacity, false);
            try self.datas.ensureTotalCapacity(allocator, capacity);
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.fds.deinit(allocator);
            self.used.deinit(allocator);
            self.datas.deinit(allocator);
        }

        pub inline fn addSocket(self: *Self, allocator: Allocator, socket: Socket, events: Events, data: Userdata) AddError!void {
            return self.addFd(allocator, socket.handle, events, data);
        }

        pub inline fn modifySocket(self: *Self, socket: Socket, events: ?Events, data: ?Userdata) void {
            return self.modifyFd(socket.handle, events, data);
        }

        pub inline fn removeSocket(self: *Self, socket: Socket) Userdata {
            return self.removeFd(socket.handle);
        }

        pub inline fn addFile(self: *Self, allocator: Allocator, file: Io.File, events: Events, data: Userdata) AddError!void {
            return self.addFd(allocator, file.handle, events, data);
        }

        pub inline fn modifyFile(self: *Self, file: Io.File, events: ?Events, data: ?Userdata) void {
            return self.modifyFd(file.handle, events, data);
        }

        pub inline fn removeFile(self: *Self, file: Io.File) Userdata {
            return self.removeFd(file.handle);
        }

        /// Temporary ownership of `self` is given to the iterator.
        pub fn wait(self: *Self, timeout_ms: i32) WaitError!EventIterator {
            const n = posix.poll(self.fds.items, timeout_ms) catch |e|
                return @errorCast(e);

            return .{ .self = self, .signaled_n = n };
        }

        //#endregion Common API
    };
}

pub fn EPoll(comptime Userdata: type) type {
    return struct {
        const Self = @This();

        const elems_per_grow = 128;
        const poll_block_size = 128;

        const CountInt = @Int(.unsigned, std.math.log2(poll_block_size) + 1);

        fn fromLinuxEvents(ev: EventInt) Events {
            return .{
                .out = (ev & EPOLL.OUT) != 0,
                .in = (ev & EPOLL.IN) != 0,
                .pri = (ev & EPOLL.PRI) != 0,

                .hang_up = (ev & EPOLL.HUP) != 0,
                .err = (ev & EPOLL.ERR) != 0,

                .read_hang_up = (ev & EPOLL.RDHUP) != 0,
            };
        }

        fn toLinuxEvents(ev: Events) EventInt {
            return @as(EventInt, @intFromBool(ev.in)) * EPOLL.IN |
                @as(EventInt, @intFromBool(ev.out)) * EPOLL.OUT |
                @as(EventInt, @intFromBool(ev.pri)) * EPOLL.PRI |
                @as(EventInt, @intFromBool(ev.edge_triggered)) * EPOLL.ET |
                @as(EventInt, @intFromBool(ev.read_hang_up)) * EPOLL.RDHUP;
        }

        fn removeFdInner(self: *Self, fd: posix.fd_t) struct { usize, Userdata } {
            var iter = self.used.iterator(.{});

            while (iter.next()) |idx| {
                const elem = self.datas.items[idx];
                if (elem[0] != fd) continue;

                self.used.unset(idx);
                self.fd.control(.delete, fd, undefined) catch unreachable;

                return .{ idx, elem[1] };
            } else unreachable; // IO Object not found
        }

        fd: linux_fd.EPollFD,
        used: std.DynamicBitSetUnmanaged = .{},
        datas: std.ArrayList(struct { posix.fd_t, Userdata }) = .empty,

        /// Used to identify the implementation of the current poller,
        /// useful for platform-specific optimizations.
        comptime poller_type: PollerType = .epoll,

        pub const EPEventIterator = struct {
            self: *const Self,
            events: []linux.epoll_event,
            timeout: i32,
            iter: usize = 0,
            count: usize = 0,

            pub fn resizeBuffer(it: *EPEventIterator, gpa: Allocator, new_len: usize) Allocator.Error![]linux.epoll_event {
                if (new_len <= it.events.len) return it.events;

                if (gpa.resize(it.events, new_len)) {
                    it.events.len = new_len;
                    return it.events;
                }

                const new_alloc = try gpa.alloc(linux.epoll_event, new_len);
                @memmove(new_alloc[0 .. it.count - it.iter], it.events[it.iter..it.count]);
                gpa.free(it.events);
                it.events = new_alloc;
                return it.events;
            }

            pub fn next(it: *EPEventIterator) ?PollEvent(Userdata) {
                const self = it.self;

                const State = enum { loop, wait };

                // I love state-machines 🤤
                sw: switch (State.loop) {
                    .loop => {
                        if (it.iter >= it.count) continue :sw .wait;

                        const idx = it.iter;
                        const ev = it.events[idx];
                        it.iter += 1;

                        if (!self.used.isSet(idx)) continue :sw .loop;

                        return .{
                            .data = self.datas.items[ev.data.ptr][1],
                            .events = fromLinuxEvents(ev.events),
                        };
                    },
                    .wait => {
                        const n = self.fd.wait(it.events, it.timeout);
                        it.count = @min(n, it.events.len);
                        it.iter = 0;

                        if (it.count > 0) continue :sw .loop;

                        return null;
                    },
                }
                comptime unreachable;
            }
        };

        /// If `poller_type == .epoll`
        pub fn addFd(self: *Self, allocator: Allocator, fd: posix.fd_t, events: Events, data: Userdata) AddError!void {
            var search_it = self.used.iterator(.{ .kind = .unset });
            const idx = search_it.next() orelse grow: {
                try self.datas.ensureUnusedCapacity(allocator, elems_per_grow);
                const idx = self.used.bit_length;
                try self.used.resize(allocator, idx + elems_per_grow, false);
                break :grow idx;
            };

            self.fd.control(.add, fd, .{
                .events = toLinuxEvents(events),
                .data = .{ .ptr = idx },
            }) catch |e| switch (e) {
                error.NotFound => unreachable,
                error.Duplicate, error.SystemResources => |err| return err,
            };

            self.datas.items.len = @max(self.datas.items.len, idx + 1);
            self.datas.items[idx] = .{ fd, data };
            self.used.set(idx);
        }

        /// If `poller_type == .epoll`
        pub fn modifyFd(self: *Self, fd: posix.fd_t, events: ?Events, data: ?Userdata) void {
            assert(events != null or data != null);

            var iter = self.used.iterator(.{});

            while (iter.next()) |idx| {
                const elem = &self.datas.items[idx];
                if (elem[0] != fd) continue;

                if (data) |ud| {
                    elem[1] = ud;
                }
                if (events) |ev| {
                    self.fd.control(.modify, fd, .{
                        .events = toLinuxEvents(ev),
                        .data = .{ .ptr = idx },
                    }) catch unreachable;
                }

                break;
            } else unreachable; // IO Object not found
        }

        /// If `poller_type == .epoll`
        pub fn removeFd(self: *Self, fd: posix.fd_t) Userdata {
            return self.removeFdInner(fd)[1];
        }

        pub fn epollWait(self: *Self, timeout_ms: i32, buffer: []linux.epoll_event) EPEventIterator {
            return .{
                .self = self,
                .events = buffer,
                .timeout = timeout_ms,
            };
        }

        //#region Common API

        pub const EventIterator = struct {
            events: [poll_block_size]linux.epoll_event,
            private: EPEventIterator,

            pub fn next(it: *EventIterator) ?PollEvent(Userdata) {
                it.private.events = &it.events;
                return it.private.next();
            }
        };

        pub inline fn init() CreateError!Self {
            return .initCapacity(.failing, 0);
        }

        pub fn initCapacity(allocator: Allocator, capacity: usize) CreateError!Self {
            var self: Self = .{ .fd = try .create(true) };
            errdefer self.deinit(allocator);
            try self.used.resize(allocator, capacity, false);
            try self.datas.ensureTotalCapacity(allocator, capacity);
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.fd.close();
            self.used.deinit(allocator);
            self.datas.deinit(allocator);
        }

        pub inline fn addSocket(self: *Self, allocator: Allocator, socket: Socket, events: Events, data: Userdata) AddError!void {
            return self.addFd(allocator, socket.handle, events, data);
        }

        pub inline fn modifySocket(self: *Self, socket: Socket, events: ?Events, data: ?Userdata) void {
            return self.modifyFd(socket.handle, events, data);
        }

        pub inline fn removeSocket(self: *Self, socket: Socket) Userdata {
            return self.removeFd(socket.handle);
        }

        pub inline fn addFile(self: *Self, allocator: Allocator, file: Io.File, events: Events, data: Userdata) AddError!void {
            return self.addFd(allocator, file.handle, events, data);
        }

        pub inline fn modifyFile(self: *Self, file: Io.File, events: ?Events, data: ?Userdata) void {
            return self.modifyFd(file.handle, events, data);
        }

        pub inline fn removeFile(self: *Self, file: Io.File) Userdata {
            return self.removeFd(file.handle);
        }

        pub inline fn wait(self: *Self, timeout_ms: i32) WaitError!EventIterator {
            return .{
                .events = undefined,
                .private = self.epollWait(timeout_ms, &.{}),
            };
        }

        //#endregion Common API
    };
}
