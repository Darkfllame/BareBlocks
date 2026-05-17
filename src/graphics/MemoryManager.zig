const MemoryManager = @This();
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const utils = @import("utils");
const Device = @import("Device.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const DoublyLinkedList = std.DoublyLinkedList;
const assert = std.debug.assert;
const is_debug = builtin.mode == .Debug;

const logger = std.log.scoped(.@"graphics/MemoryManager");

fn Rater(comptime T: type) type {
    return struct {
        const Self = @This();

        best: T,
        best_rating: u32,
        has_value: bool,

        pub const init = Self{
            .best = undefined,
            .best_rating = undefined,
            .has_value = false,
        };

        pub fn maybeSet(self: *Self, rating: u32, value: T) void {
            if (self.has_value) {
                if (rating > self.best_rating) {
                    self.best = value;
                    self.best_rating = rating;
                }
            } else {
                self.best = value;
                self.best_rating = rating;
                self.has_value = true;
            }
        }

        pub fn get(self: Self) ?T {
            return if (self.has_value) self.best else null;
        }
    };
}

const ChunkIterator = struct {
    const State = enum { chunk, block };

    current_block: ?*DoublyLinkedList.Node,
    current_chunk: ?*DoublyLinkedList.Node = null,
    kind: MemoryBlock.Kind,
    fit: AllocationFitMode,
    size: vk.DeviceSize,
    state: State = .block,

    pub const NextResult = struct { *MemoryBlock.Chunk, vk.DeviceSize };

    pub fn init(blocks: DoublyLinkedList, kind: MemoryBlock.Kind, fit: AllocationFitMode, size: vk.DeviceSize) ChunkIterator {
        return .{
            .current_block = if (fit == .last) blocks.last else blocks.first,
            .kind = kind,
            .fit = fit,
            .size = size,
        };
    }

    pub fn next(self: *ChunkIterator) ?NextResult {
        sw: switch (self.state) {
            .chunk => {
                const block: *MemoryBlock = @fieldParentPtr("node", self.current_block.?);
                while (self.current_chunk) |curr| {
                    self.current_chunk = if (self.fit == .last) curr.prev else curr.next;

                    const chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", curr);
                    assert(chunk.block == block);

                    if (chunk.used) continue;

                    const chunk_end_offset = if (chunk.node.next) |node|
                        @as(*MemoryBlock.Chunk, @fieldParentPtr("node", node)).offset
                    else
                        block.size;
                    assert(chunk_end_offset > chunk.offset);

                    const chunk_size = chunk_end_offset - chunk.offset;
                    if (chunk_size < self.size) continue;

                    return .{ chunk, chunk_size };
                }

                self.state = .block;
                self.current_block = block.node.next;
                continue :sw self.state;
            },
            .block => while (self.current_block) |curr| : (self.current_block = curr.next) {
                const block: *MemoryBlock = @fieldParentPtr("node", curr);

                if (block.kind != self.kind) continue;
                if (block.size - block.used < self.size) continue;

                self.current_chunk = if (self.fit == .last) block.chunks.last else block.chunks.first;
                assert(self.current_chunk != null);

                self.state = .chunk;
                continue :sw self.state;
            } else return null,
        }
    }
};

const MemoryBlock = struct {
    node: DoublyLinkedList.Node,

    devm: vk.DeviceMemory,
    size: vk.DeviceSize,
    used: vk.DeviceSize,
    kind: Kind,

    /// Basically, the size of a node is decided by the offset of
    /// the current node, and the offset of the next or the device
    /// size.
    ///
    /// It is also asumed the list has at least 1 elements.
    chunks: DoublyLinkedList,

    pub const Kind = enum { transfer, image_buffer };
    pub const Chunk = struct {
        node: DoublyLinkedList.Node,

        block: *MemoryBlock,
        offset: vk.DeviceSize,
        used: bool,
    };
};

fn allocateMemory(
    self: *MemoryManager,
    kind: MemoryBlock.Kind,
    size: vk.DeviceSize,
    fit: AllocationFitMode,
    alignment: Alignment,
) !*MemoryBlock.Chunk {
    // Checking maximum memory sizes
    if (size > self.max_alloc_size) return error.OutOfDeviceMemory;
    const mtype = switch (kind) {
        .image_buffer => self.buffer_mtype,
        .transfer => self.transfer_mtype,
    };

    if (size > mtype.heap.size) return error.OutOfDeviceMemory;

    var fit_size: vk.DeviceSize = if (fit == .best) ~@as(vk.DeviceSize, 0) else 0;
    var chosen_chunk: ?*MemoryBlock.Chunk = null;

    var chunk_iter = ChunkIterator.init(self.blocks, kind, fit, size);
    while (chunk_iter.next()) |res| {
        const chunk, var chunk_size = res;
        const alignment_cost = alignment.forward(chunk.offset) - chunk.offset;

        chunk_size -= alignment_cost;

        const chose = switch (fit) {
            .first, .last => {
                fit_size = chunk_size;
                chosen_chunk = chunk;
                break;
            },
            .best => if (chunk_size == size) {
                fit_size = chunk_size;
                chosen_chunk = chunk;
                break;
            } else fit_size > chunk_size,
            .worst => fit_size < chunk_size,
        };
        if (chose) {
            fit_size = chunk_size;
            chosen_chunk = chunk;
        }
    }

    const chunk = chosen_chunk orelse alloc_new_block: {
        if (self.num_blocks == self.max_alloc_count) return error.OutOfDeviceMemory;

        const alloc_size = self.alloc_alignment.forward(size);

        const block = try self.gpa.create(MemoryBlock);
        errdefer self.gpa.destroy(block);
        const chunk = try self.gpa.create(MemoryBlock.Chunk);
        errdefer self.gpa.destroy(chunk);

        block.* = .{
            .node = undefined,
            .devm = undefined,
            .size = alloc_size,
            .used = 0,
            .kind = kind,
            .chunks = .{
                .first = &chunk.node,
                .last = &chunk.node,
            },
        };
        chunk.* = .{
            .node = .{},
            .block = block,
            .offset = 0,
            .used = true,
        };

        block.devm = self.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
            .allocation_size = alloc_size,
            .memory_type_index = mtype.type_index,
        }, null) catch |e| return switch (e) {
            error.OutOfHostMemory => error.OutOfMemory,
            error.OutOfDeviceMemory => error.OutOfDeviceMemory,
            error.InvalidExternalHandle, error.Unknown, error.InvalidOpaqueCaptureAddressKHR => unreachable,
            error.ValidationFailed => unreachable, // Invalid state
        };

        self.blocks.prepend(&block.node);
        self.num_blocks += 1;
        fit_size = alloc_size;

        break :alloc_new_block @as(*MemoryBlock.Chunk, @fieldParentPtr("node", block.chunks.first.?));
    };
    const block = chunk.block;
    const chunk_end_offset = if (chunk.node.next) |next|
        @as(*MemoryBlock.Chunk, @fieldParentPtr("node", next)).offset
    else
        block.size;
    assert(chunk_end_offset > chunk.offset);
    const chunk_size = chunk_end_offset - chunk.offset;
    const alignment_cost = alignment.forward(chunk.offset) - chunk.offset;

    var prev_chunk: ?*MemoryBlock.Chunk = null;
    var next_chunk: ?*MemoryBlock.Chunk = null;

    const orig_offset = chunk.offset;
    if (alignment_cost != 0) {
        prev_chunk = try self.gpa.create(MemoryBlock.Chunk);
        prev_chunk.?.* = .{
            .node = undefined,
            .block = block,
            .offset = chunk.offset,
            .used = false,
        };
        chunk.offset = alignment.forward(chunk.offset);
    }
    errdefer {
        chunk.offset = orig_offset;
        if (prev_chunk) |ch| self.gpa.destroy(ch);
    }
    if (chunk_size > size) {
        next_chunk = try self.gpa.create(MemoryBlock.Chunk);
        next_chunk.?.* = .{
            .node = undefined,
            .block = block,
            .offset = chunk.offset + size,
            .used = false,
        };
    }
    errdefer if (next_chunk) |ch| self.gpa.destroy(ch);

    chunk.used = true;
    block.used += size;
    if (prev_chunk) |ch| block.chunks.insertBefore(&chunk.node, &ch.node);
    if (next_chunk) |ch| block.chunks.insertAfter(&chunk.node, &ch.node);

    return chunk;
}

pub fn format(self: *const MemoryManager, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var current = self.blocks.first;
    try writer.print("MemoryManager blocks: {d}", .{self.num_blocks});
    while (current) |curr| {
        current = curr.next;
        try writer.writeByte('\n');

        const block: *MemoryBlock = @fieldParentPtr("node", curr);
        try writer.print(" - {t} VkDeviceMemory@{x:0>16} {d}/{d} ({d}%)\n", .{
            block.kind,
            block.devm,
            block.used,
            block.size,
            block.used * 100 / block.size,
        });

        var current_chunk = block.chunks.first;
        while (current_chunk) |chnode| {
            current_chunk = chnode.next;

            const chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", chnode);

            const chunk_end_offset = if (chunk.node.next) |node|
                @as(*MemoryBlock.Chunk, @fieldParentPtr("node", node)).offset
            else
                block.size;

            try writer.print("   - {d}..{d}: {s}", .{
                chunk.offset,                       chunk_end_offset,
                if (chunk.used) "used" else "free",
            });
            if (current_chunk != null) {
                try writer.writeByte('\n');
            }
        }
    }
}

const MemTypePair = struct { type_index: u32, flags: vk.MemoryPropertyFlags, heap: vk.MemoryHeap };

gpa: Allocator,
vk_device: vk.DeviceProxy,
device: *const Device,
blocks: DoublyLinkedList,
num_blocks: u32,
buffer_mtype: MemTypePair,
transfer_mtype: MemTypePair,

alloc_alignment: std.mem.Alignment,
max_alloc_count: u32,
max_alloc_size: vk.DeviceSize,

pub const AllocError = error{ OutOfMemory, OutOfDeviceMemory };
pub const CopyToTransferBufferError = error{
    OutOfMemory,
    OutOfDeviceMemory,
};

/// Can be mixed and matched for efficient memory allocation
pub const AllocationFitMode = enum {
    /// Generally shouldn't be used except when you're doing
    /// the first allocation ever.
    first,
    /// Useful when creating a bunch of buffers in a row as it
    /// will always use the last allocation possible. Kinda makes
    /// allocation acts like a  stack.
    last,
    /// Should be the preferred use, will always use the smallest available
    /// space for allocation.
    best,
    /// Will always use the largest available space for allocation.
    worst,

    pub const default = AllocationFitMode.best;
};
pub const Buffer = struct {
    handle: vk.Buffer,
    size: vk.DeviceSize,
    kind: Kind,
    chunk: *MemoryBlock.Chunk,

    pub const Kind = enum { vertex, index, transfer, uniform, storage };
};
pub const InitInfo = struct {
    gpa: Allocator,
    instance: vk.InstanceProxy,
    device: *const Device,
    pdev: vk.PhysicalDevice,
};

pub fn init(self: *MemoryManager, info: InitInfo) error{Vulkan}!void {
    self.gpa = info.gpa;
    self.vk_device = info.device.proxy;
    self.device = info.device;
    self.blocks = .{};
    self.num_blocks = 0;

    var props = vk.PhysicalDeviceMemoryProperties2{ .memory_properties = undefined };
    var maint3 = vk.PhysicalDeviceMaintenance3Properties{
        .max_per_set_descriptors = undefined,
        .max_memory_allocation_size = undefined,
    };
    var props2 = vk.PhysicalDeviceProperties2{
        .p_next = &maint3,
        .properties = undefined,
    };
    info.instance.getPhysicalDeviceMemoryProperties2(info.pdev, &props);
    info.instance.getPhysicalDeviceProperties2(info.pdev, &props2);

    self.alloc_alignment = .fromByteUnits(@truncate(props2.properties.limits.buffer_image_granularity));
    self.max_alloc_count = props2.properties.limits.max_memory_allocation_count;
    self.max_alloc_size = maint3.max_memory_allocation_size;

    const mem_types = props.memory_properties.memory_types[0..props.memory_properties.memory_type_count];
    const mem_heaps = props.memory_properties.memory_heaps[0..props.memory_properties.memory_heap_count];

    var transfer_mem_rater: Rater(u32) = .init;
    var buffer_mem_rater: Rater(u32) = .init;
    for (mem_types, 0..) |mtype, i| {
        assert(mtype.heap_index < props.memory_properties.memory_heap_count);

        var transfer_rating: u32 = 0;
        var buffer_rating: u32 = 0;
        transfer_rating += @intFromBool(mtype.property_flags.host_visible_bit);
        transfer_rating += @intFromBool(mtype.property_flags.host_coherent_bit);
        transfer_rating += @intFromBool(mtype.property_flags.host_cached_bit);
        buffer_rating += @intFromBool(mtype.property_flags.device_local_bit);
        // This could be good because if you need to make a big vertex/index buffer,
        // it only alllocates it when transferering to it.
        // You can also pre-allocate a big chunk of memory and only actually use it
        // when neccessary
        buffer_rating += @intFromBool(mtype.property_flags.lazily_allocated_bit);

        transfer_mem_rater.maybeSet(transfer_rating, @intCast(i));
        buffer_mem_rater.maybeSet(buffer_rating, @intCast(i));
    }

    self.transfer_mtype = blk: {
        const idx = transfer_mem_rater.get() orelse {
            logger.err("Couldn't find suitable memory types for transfer operations", .{});
            return error.Vulkan;
        };
        const mt = mem_types[idx];
        break :blk .{
            .type_index = idx,
            .flags = mt.property_flags,
            .heap = mem_heaps[mt.heap_index],
        };
    };
    self.buffer_mtype = blk: {
        const idx = buffer_mem_rater.get() orelse {
            logger.err("Couldn't find suitable memory types for buffers", .{});
            return error.Vulkan;
        };
        const mt = mem_types[idx];
        break :blk .{
            .type_index = idx,
            .flags = mt.property_flags,
            .heap = mem_heaps[mt.heap_index],
        };
    };
}

pub fn deinit(self: *MemoryManager) void {
    var current = self.blocks.first;
    while (current) |curr| {
        current = curr.next;

        const block: *MemoryBlock = @fieldParentPtr("node", curr);

        var current_chunk = block.chunks.first;
        while (current_chunk) |curr_ch| {
            current_chunk = curr_ch.next;

            const chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", curr_ch);
            assert(chunk.block == block);

            if (is_debug and chunk.used) {
                const chunk_end_offset = if (chunk.node.next) |node|
                    @as(*MemoryBlock.Chunk, @fieldParentPtr("node", node)).offset
                else
                    block.size;
                assert(chunk_end_offset > chunk.offset);

                const chunk_size = chunk_end_offset - chunk.offset;

                logger.err("GPU memory leaked at VkDeviceMemory@{x:0>16}[{d}..{d}] ({Bi})", .{
                    @intFromEnum(block.devm), chunk.offset, chunk_end_offset - 1, chunk_size,
                });
            }

            self.gpa.destroy(chunk);
        }

        self.vk_device.freeMemory(block.devm, null);
        self.gpa.destroy(block);
    }
}

pub fn allocBuffer(self: *MemoryManager, kind: Buffer.Kind, size: vk.DeviceSize, fit: AllocationFitMode) AllocError!Buffer {
    var rval: Buffer = .{
        .handle = undefined,
        .size = size,
        .kind = kind,
        .chunk = undefined,
    };

    rval.handle = self.vk_device.createBuffer(&vk.BufferCreateInfo{
        .flags = .{},
        .size = size,
        .usage = .{
            .vertex_buffer_bit = kind == .vertex,
            .index_buffer_bit = kind == .index,
            .transfer_src_bit = kind == .transfer,
            .transfer_dst_bit = kind == .transfer,
            .uniform_buffer_bit = kind == .uniform,
            .storage_buffer_bit = kind == .storage,
        },
        .sharing_mode = if (self.device.concurrent_queues_count > 1) .concurrent else .exclusive,
        .queue_family_index_count = self.device.concurrent_queues_count,
        .p_queue_family_indices = &self.device.concurrent_queues,
    }, null) catch |e| return switch (e) {
        error.OutOfHostMemory => error.OutOfMemory,
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.Unknown, error.InvalidOpaqueCaptureAddressKHR => unreachable,
        error.ValidationFailed => unreachable, // invalid state
    };
    errdefer self.vk_device.destroyBuffer(rval.handle, null);

    const req = self.vk_device.getBufferMemoryRequirements(rval.handle);

    const alloc_kind: MemoryBlock.Kind = if (kind == .transfer) .transfer else .image_buffer;
    rval.chunk = try self.allocateMemory(
        alloc_kind,
        req.size,
        fit,
        .fromByteUnits(@intCast(req.alignment)),
    );

    return rval;
}

pub fn freeBuffer(self: *MemoryManager, buffer: Buffer) void {
    const chunk = buffer.chunk;
    const block = chunk.block;

    if (chunk.node.next) |next_node| fix_next_node: {
        const next_chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", next_node);
        assert(next_chunk.block == block);
        if (next_chunk.used) break :fix_next_node;

        block.chunks.remove(&next_chunk.node);
        self.gpa.destroy(next_chunk);
    }
    if (chunk.node.prev) |prev_node| fix_prev_node: {
        const prev_chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", prev_node);
        assert(prev_chunk.block == block);
        if (prev_chunk.used) {
            chunk.used = false;
            break :fix_prev_node;
        }

        block.chunks.remove(&chunk.node);
        self.gpa.destroy(chunk);
    } else chunk.used = false;

    block.used -= buffer.size;
    self.vk_device.destroyBuffer(buffer.handle, null);

    if (block.used == 0) {
        self.blocks.remove(&block.node);
        self.vk_device.freeMemory(block.devm, null);
        const block_chunk: *MemoryBlock.Chunk = @fieldParentPtr("node", block.chunks.first.?);
        assert(block_chunk.node.next == null); // All chunks should be fused within one at this point
        self.gpa.destroy(block_chunk);
        self.gpa.destroy(block);
        self.num_blocks -= 1;
    }
}

/// Will copy up to `buffer.size` bytes from `reader`
pub fn copyToTransferBuffer(self: *MemoryManager, buffer: Buffer, reader: *std.Io.Reader) std.Io.Reader.Error!void {
    const chunk = buffer.chunk;
    const ptr = (self.vk_device.mapMemory(chunk.block.devm, chunk.offset, buffer.size, .{}) catch |e| return switch (e) {
        error.OutOfHostMemory, error.MemoryMapFailed => error.OutOfMemory,
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.ValidationFailed => unreachable,
        error.Unknown => unreachable,
    }).?;
    defer self.vk_device.unmapMemory(chunk.block.devm);

    var copy_buf: [512]u8 = undefined;
    var offset: usize = 0;
    while (offset < buffer.size) {
        const read = try reader.readSliceShort(copy_buf[0..@min(copy_buf.len, buffer.size - offset)]);
        @memcpy(ptr[offset .. offset + read], copy_buf[0..read]);
        offset += read;
    }
}
