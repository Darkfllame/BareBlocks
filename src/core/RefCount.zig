const RefCount = @This();
const std = @import("std");
const utils = @import("utils");

// TODO: Figure if 32-bits targets (unlikely) would be compilable
/// Aligned to avoid false-sharing.
count: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(1),

/// Should be called when a thread pass the point
pub fn acquire(self: *RefCount) void {
    return self.acquireExtra(@returnAddress());
}

/// Should be called when a thread pass the point
pub fn acquireExtra(self: *RefCount, return_address: usize) void {
    if (self.count.fetchAdd(1, .monotonic) == 0) {
        if (utils.is_safe) {
            std.debug.panicExtra(return_address, "Attempted to revive dead reference: {*}", .{self});
        }
        unreachable;
    }
}

pub fn release(self: *RefCount) bool {
    if (self.count.fetchSub(1, .release) == 1) {
        _ = self.count.load(.acquire);
        return true;
    }
    return false;
}