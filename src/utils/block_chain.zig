const std = @import("std");
const utils = @import("utils.zig");

const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

pub fn BlockChainOptions(comptime T: type) type {
    return struct {
        fn validate(comptime self: @This()) void {
            if (self.count_size > @bitSizeOf(usize)) @compileError("Due to std limitations," ++
                ".count_size must be less or equal than @bitSizeOf(usize)");
            if (self.max_elements) |max| {
                if (max < 0 or std.math.maxInt(self.count_size) < max) {
                    utils.compileError("Invalid BlockChainOptions.max_elements: {d}", .{max});
                }
            }
            if (@sizeOf(self.DuplicateContext) != 0) {
                utils.validateMethod(self.DuplicateContext, "isDuplicate", &.{T}, bool);
            }
        }

        /// For optimal storage, a single cache line
        /// should be used (see `std.atomic.cache_line`).
        ///
        /// In practice, it may resolve in single-element
        /// linked list on big types.
        elems_per_block: comptime_int = 16,

        count_size: comptime_int = @bitSizeOf(usize),
        max_elements: ?comptime_int = null,

        DuplicateContext: type = void,
    };
}

pub const DuplicateError = error{DuplicateEntry};
pub const OverflowError = error{Overflow};

/// A stable address list.
pub fn BlockChain(comptime T: type, comptime options: BlockChainOptions(T)) type {
    const has_dup_check = @sizeOf(options.DuplicateContext) != 0;
    options.validate();
    return struct {
        const Self = @This();

        const ElementMask = std.StaticBitSet(options.elems_per_block);

        const BlockNode = struct {
            mutex: Io.Mutex = .init,
            node: DoublyLinkedList.Node,
            mask: ElementMask,
            elems: [options.elems_per_block]T,
        };

        comptime max_count: comptime_int = options.max_elements orelse std.math.maxInt(Count),

        mutex: Io.Mutex = .init,
        list: DoublyLinkedList = .{},
        count: Count = 0,

        pub const Count = @Int(.unsigned, options.count_size);

        pub const AddError = std.Io.Cancelable || Allocator.Error || if (options.max_elements != null) OverflowError else error{} ||
            if (has_dup_check) DuplicateError else error{};

        pub const Iterator = struct {
            io_ud: ?*anyopaque,
            io_futexWake: *const fn (?*anyopaque, *const u32, u32) void,
            mutex_ptr: *Io.Mutex,
            current_node: ?*DoublyLinkedList.Node,
            mask_it: std.StaticBitSet(options.elems_per_block).Iterator(.{}),

            pub fn next(self: *Iterator) ?*T {
                while (self.current_node) |curr| : ({
                    self.current_node = curr.next;
                    if (self.current_node) |node| {
                        const block: *BlockNode = @alignCast(@fieldParentPtr("node", node));
                        self.mask_it = block.mask.iterator(.{});
                    }
                }) {
                    const block: *BlockNode = @alignCast(@fieldParentPtr("node", curr));
                    const idx = self.mask_it.next() orelse continue;
                    return &block.elems[idx];
                }
                return null;
            }

            pub fn done(self: Iterator) void {
                var failing_vtable = std.Io.failing.vtable.*;
                failing_vtable.futexWake = self.io_futexWake;
                self.mutex_ptr.unlock(.{
                    .userdata = self.io_ud,
                    .vtable = &failing_vtable,
                });
            }
        };

        pub fn deinit(self: *Self, allocator: Allocator, io: std.Io) void {
            self.mutex.lockUncancelable(io);

            var current = self.list.first;
            var i: usize = 0;
            while (current) |curr| : (i += 1) {
                current = curr.next;

                const block: *BlockNode = @alignCast(@fieldParentPtr("node", curr));
                block.mutex.lockUncancelable(io);
                assert(block.mask.count() == 0); // Block is not empty

                self.list.remove(&block.node);
                allocator.destroy(block);
            }
        }

        pub fn add(self: *Self, allocator: Allocator, io: std.Io) AddError!*T {
            comptime assert(@sizeOf(options.DuplicateContext) == 0);
            return self.addContext(allocator, io, undefined);
        }

        pub fn remove(self: *Self, allocator: Allocator, io: std.Io, value: *const T) Io.Cancelable!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var current = self.list.first;
            var i: usize = 0;
            while (current) |curr| : (i += 1) {
                current = curr.next;

                const block: *BlockNode = @alignCast(@fieldParentPtr("node", curr));

                if (@intFromPtr(value) >= @intFromPtr(&block.elems) and
                    @intFromPtr(value) <= @intFromPtr(&block.elems[block.elems.len - 1]))
                {
                    try block.mutex.lock(io);

                    const offset = @intFromPtr(value) - @intFromPtr(&block.elems);
                    const idx = @divExact(offset, @sizeOf(T));
                    block.mask.unset(idx);
                    self.count += 1;

                    const prev_empty = block.node.prev != null and
                        @as(*BlockNode, @alignCast(@fieldParentPtr("node", block.node.prev.?)))
                            .mask.count() == 0;
                    const next_empty = block.node.next != null and
                        @as(*BlockNode, @alignCast(@fieldParentPtr("node", block.node.next.?)))
                            .mask.count() == 0;

                    // remove current block if the next or previous one is also empty.
                    if (block.mask.count() == 0 and (next_empty or prev_empty)) {
                        self.list.remove(&block.node);
                        allocator.destroy(block);
                        return;
                    }

                    block.mutex.unlock(io);
                    return;
                }
            }
            unreachable; // Value was not in the list
        }

        pub fn lockBlock(self: *Self, io: std.Io, value: *const T) Io.Cancelable!*Io.Mutex {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var current = self.list.first;
            var i: usize = 0;
            while (current) |curr| : (i += 1) {
                current = curr.next;

                const block: *BlockNode = @alignCast(@fieldParentPtr("node", curr));
                if (@intFromPtr(value) >= @intFromPtr(&block.elems) and
                    @intFromPtr(value) <= @intFromPtr(&block.elems[block.elems.len - 1]))
                {
                    try block.mutex.lock(io);
                    return &block.mutex;
                }
            }
        }

        pub fn addContext(self: *Self, allocator: Allocator, io: std.Io, context: options.DuplicateContext) AddError!*T {
            if (options.max_elements) |max| {
                if (self.count + 1 >= max) return error.Overflow;
            }

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var current = self.list.first;
            var result: struct { ?*BlockNode, usize } = .{ null, 0 };
            while (current) |curr| {
                current = curr.next;

                const block: *BlockNode = @alignCast(@fieldParentPtr("node", curr));
                try block.mutex.lock(io);
                defer block.mutex.unlock(io);

                if (has_dup_check) {
                    if (result[0] != null) {
                        var it = block.mask.iterator(.{});
                        while (it.next()) |idx| {
                            if (context.isDuplicate(block.elems[idx])) {
                                return error.DuplicateEntry;
                            }
                        }

                        continue;
                    }

                    for (&block.elems, 0..) |value, idx| {
                        if (block.mask.isSet(idx) and context.isDuplicate(value)) {
                            return error.DuplicateEntry;
                        } else if (block.mask.isSet(idx)) {
                            result = .{ block, idx };
                        }
                    }
                } else {
                    var it = block.mask.iterator(.{ .kind = .unset });
                    if (it.next()) |idx| {
                        block.mask.set(idx);
                        self.count += 1;
                        return &block.elems[idx];
                    }
                }
            }
            if (has_dup_check) if (result[0]) |block| {
                block.mask.set(result[1]);
                self.count += 1;
                return &block.elems[result[1]];
            };

            const block = try allocator.create(BlockNode);
            block.* = .{
                .node = undefined,
                .mask = .initEmpty(),
                .elems = undefined,
            };
            self.list.append(&block.node);
            block.mask.set(0);
            return &block.elems[0];
        }

        /// Locks adding/removing items in the block chain.
        ///
        /// Call `done()` on iterator when iteration ends to
        /// unlock the block chain.
        pub fn iterator(self: *Self, io: std.Io) std.Io.Cancelable!Iterator {
            try self.mutex.lock(io);
            return .{
                .io_ud = io.userdata,
                .io_futexWake = io.vtable.futexWake,
                .mutex_ptr = &self.mutex,
                .current_node = self.list.first,
                .mask_it = if (self.list.first) |fnode| @as(
                    *BlockNode,
                    @alignCast(@fieldParentPtr("node", fnode)),
                ).mask.iterator(.{}) else ElementMask.initEmpty().iterator(.{}),
            };
        }
    };
}
