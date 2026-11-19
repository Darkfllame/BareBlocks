const TickSynchronizer = @This();
const std = @import("std");
const zio = @import("zio");

const Io = std.Io;
const Atomic = std.atomic.Value;

mutex: zio.Mutex = .init,
cond: zio.Condition = .init,

phase: u64 = 0,
registered: u64 = 0,
arrived: u64 = 0,
terminated: bool = false,

pub fn register(self: *TickSynchronizer) error{Terminated}!void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    if (self.terminated) return error.Terminated;
    self.registered += 1;
}

pub fn unregister(self: *TickSynchronizer) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    if (self.terminated) return;
    
    const reg = self.registered;

    self.registered -= 1;
    self.arrived += 1;

    if (self.arrived == reg) {
        self.arrived = 0;
        self.phase += 1;

        if (self.registered == 0) {
            self.terminated = true;
        }

        self.cond.broadcast();
    }
}

pub fn waitForTick(self: *TickSynchronizer) Io.Cancelable!void {
    try self.mutex.lock();
    defer self.mutex.unlock();

    if (self.terminated) return;

    const curr_phase = self.phase;

    self.arrived += 1;

    if (self.arrived == self.registered) {
        self.arrived = 0;
        self.phase += 1;
        self.cond.broadcast();
        return;
    }

    while (self.phase == curr_phase and !self.terminated) {
        try self.cond.wait(&self.mutex);
    }
}
