const CountingAllocator = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const vtable = Allocator.VTable{
    .alloc = &alloc,
    .resize = &resize,
    .remap = &remap,
    .free = &free,
};

fn findBlock(self: *CountingAllocator, address: usize) ?*?[]u8 {
    for (self.allocs.items) |*block| {
        if (address == 0 and block.* == null) return block;
        if (block.* == null) continue;
        if (@intFromPtr(block.*.?.ptr) == address) return block;
    }
    return null;
}

fn alloc(ud: *anyopaque, size: usize, al: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ud));
    if (self.count_largest) self.allocs.ensureUnusedCapacity(self.parent, 1) catch return null;
    const ret = self.parent.rawAlloc(size, al, ret_addr) orelse return null;
    self.total += size;
    if (self.count_largest) {
        if (self.findBlock(0)) |bptr| {
            bptr.* = ret[0..size];
        } else {
            self.allocs.appendAssumeCapacity(ret[0..size]);
        }
    }
    return ret;
}

fn resize(ud: *anyopaque, slice: []u8, al: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *CountingAllocator = @ptrCast(@alignCast(ud));
    if (self.parent.rawResize(slice, al, new_len, ret_addr)) {
        self.total = (self.total - slice.len) + new_len;
        if (self.count_largest) {
            self.findBlock(@intFromPtr(slice.ptr)).?.*.?.len = new_len;
        }
    }
    return false;
}

fn remap(ud: *anyopaque, slice: []u8, al: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ud));
    const new_addr = self.parent.rawRemap(slice, al, new_len, ret_addr) orelse return null;
    if (self.count_largest) {
        self.findBlock(@intFromPtr(slice.ptr)).?.*.? = new_addr[0..new_len];
    }
    return new_addr;
}

fn free(ud: *anyopaque, slice: []u8, al: Alignment, ret_addr: usize) void {
    const self: *CountingAllocator = @ptrCast(@alignCast(ud));
    self.parent.rawFree(slice, al, ret_addr);
    self.total -= slice.len;
    if (self.count_largest) {
        self.findBlock(@intFromPtr(slice.ptr)).?.* = null;
        var i = self.allocs.items.len;
        while (i > 0) : (i -= 1) {
            const index = i - 1;
            if (self.allocs.items[index] != null) {
                self.allocs.items.len = i;
                break;
            }
        }
    }
}

parent: Allocator,
total: usize,
count_largest: bool,
allocs: std.ArrayList(?[]u8),

pub fn init(parent: Allocator, count_largest: bool) CountingAllocator {
    return .{
        .parent = parent,
        .total = 0,
        .count_largest = count_largest,
        .allocs = .empty,
    };
}

pub fn deinit(self: *CountingAllocator) void {
    self.allocs.deinit(self.parent);
}

pub fn allocator(self: *CountingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn largestAllocation(self: *const CountingAllocator) usize {
    std.debug.assert(self.count_largest);

    var largest: usize = 0;
    for (self.allocs.items) |may_block| {
        if (may_block == null) continue;
        largest = @max(largest, may_block.?.len);
    }

    return largest;
}

pub fn format(self: *const CountingAllocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("(total: {Bi}", .{self.total});
    if (self.count_largest) {
        try writer.print(", slots: {d}\n", .{self.allocs.items.len});

        for (self.allocs.items, 0..) |mptr, i| {
            const ptr = mptr orelse continue;

            const perth: f128 = @floatFromInt((ptr.len * 1000) / self.total);

            try writer.writeAll("  ");
            try writer.print("{Bi} [{d:.1}%]: {x}", .{
                ptr.len, perth / 10, ptr,
            });
            if (i + 1 < self.allocs.items.len) {
                try writer.writeAll(",\n");
            }
        }
    }
    try writer.writeByte(')');
}
