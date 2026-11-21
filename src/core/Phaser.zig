//! Dynamically sized barrier.
//! 
//! Allows multiple registered tasks to wait for a synchronization point.

const Phaser = @This();
const std = @import("std");
const zio = @import("zio");

const Io = std.Io;
const Atomic = std.atomic.Value;

fn innerSync(self: *Phaser, current_registered: usize) enum { none, terminated, arrived } {
    self.arrived += 1;

    if (self.arrived == current_registered) {
        self.arrived = 0;
        self.phase +%= 1;

        self.cond.broadcast();

        return if (self.registered == 0) .terminated else .arrived;
    }

    return .none;
}

mutex: zio.Mutex = .init,
cond: zio.Condition = .init,

/// The number of registered waiters.
registered: usize = 0,
/// The number of waiters arrived at their synchronization point.
arrived: usize = 0,
phase: u32 = 0,
terminated: bool = false,

pub fn register(self: *Phaser) error{Terminated}!void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    self.registered += 1;
}

/// Waits until next synchronization and unregister the current task.
pub fn unregister(self: *Phaser) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    const reg = self.registered;
    self.registered -= 1;

    if (self.innerSync(reg) == .terminated) {
        self.terminated = true;
    }
}

pub fn synchronize(self: *Phaser) Io.Cancelable!void {
    try self.mutex.lock();
    defer self.mutex.unlock();

    const curr_phase = self.phase;

    switch (self.innerSync(self.registered)) {
        .none => {},
        .terminated, .arrived => return,
    }

    while (self.phase == curr_phase and !self.terminated) {
        try self.cond.wait(&self.mutex);
    }
}
