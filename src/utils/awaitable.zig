const std = @import("std");

const Io = std.Io;

pub fn Awaitable(comptime T: type) type {
    return struct {
        const Self = @This();

        event: Io.Event = .unset,
        value: T = undefined,

        pub fn set(self: *Self, io: Io, value: T) void {
            self.value = value;
            self.event.set(io);
        }

        pub fn wait(self: *Self, io: Io) Io.Cancelable!T {
            try self.wait(io);
            return self.value;
        }

        pub fn waitUncancelable(self: *Self, io: Io) T {
            const old = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old);

            try self.wait(io);
            return self.value;
        }
    };
}
