//! Effectively a stack of u1 values implemented using ArrayList(usize).

const BitStack = @This();
const std = @import("std");

const testing = std.testing;
const Allocator = std.mem.Allocator;

bytes: std.ArrayList(u8),
bit_len: usize = 0,

pub const init = BitStack{ .bytes = .empty, .bit_len = 0 };

pub fn deinit(self: *BitStack, allocator: Allocator) void {
    self.bytes.deinit(allocator);
    self.* = undefined;
}

pub fn ensureTotalCapacity(self: *BitStack, allocator: Allocator, bit_capacity: usize) Allocator.Error!void {
    const byte_capacity = (bit_capacity + 7) >> 3;
    try self.bytes.ensureTotalCapacity(allocator, byte_capacity);
}

pub fn push(self: *BitStack, allocator: Allocator, b: u1) Allocator.Error!void {
    const byte_index = self.bit_len >> 3;
    if (self.bytes.items.len <= byte_index) {
        try self.bytes.append(allocator, 0);
    }

    pushWithStateAssumeCapacity(self.bytes.items, &self.bit_len, b);
}

pub fn peek(self: *const BitStack) u1 {
    return peekWithState(self.bytes.items, self.bit_len);
}

pub fn pop(self: *BitStack) u1 {
    return popWithState(self.bytes.items, &self.bit_len);
}

/// Standalone function for working with a fixed-size buffer.
pub fn pushWithStateAssumeCapacity(buf: []u8, bit_len: *usize, b: u1) void {
    const byte_index = bit_len.* >> 3;
    const bit_index = @as(u3, @intCast(bit_len.* & 7));

    buf[byte_index] &= ~(@as(u8, 1) << bit_index);
    buf[byte_index] |= @as(u8, b) << bit_index;

    bit_len.* += 1;
}

/// Standalone function for working with a fixed-size buffer.
pub fn peekWithState(buf: []const u8, bit_len: usize) u1 {
    const byte_index = (bit_len - 1) >> 3;
    const bit_index = @as(u3, @intCast((bit_len - 1) & 7));
    return @as(u1, @intCast((buf[byte_index] >> bit_index) & 1));
}

/// Standalone function for working with a fixed-size buffer.
pub fn popWithState(buf: []const u8, bit_len: *usize) u1 {
    const b = peekWithState(buf, bit_len.*);
    bit_len.* -= 1;
    return b;
}

test BitStack {
    var stack = BitStack.init;
    defer stack.deinit(testing.allocator);

    try stack.push(testing.allocator, 1);
    try stack.push(testing.allocator, 0);
    try stack.push(testing.allocator, 0);
    try stack.push(testing.allocator, 1);

    try testing.expectEqual(@as(u1, 1), stack.peek());
    try testing.expectEqual(@as(u1, 1), stack.pop());
    try testing.expectEqual(@as(u1, 0), stack.peek());
    try testing.expectEqual(@as(u1, 0), stack.pop());
    try testing.expectEqual(@as(u1, 0), stack.pop());
    try testing.expectEqual(@as(u1, 1), stack.pop());
}
