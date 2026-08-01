const AnyCoroutine = @This();
const std = @import("std");
const private = @import("private.zig");

const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const StackState = private.StackState;
const CoroFunction = private.CoroFunction;

const page_size_min = private.page_size_min;
const os_tag = private.os_tag;

const IoImpl = switch (os_tag) {
    .linux => @import("io_e/linux.zig"),
    else => private.compileError("Embedded IO for \"{t}\": Not Yet Implemented", .{os_tag}),
};

fn createLinux(
    self: *AnyCoroutine,
    stack_size: usize,
    data_size: usize,
    data_align: mem.Alignment,
) Allocator.Error!void {
    const page_size = std.heap.pageSize();

    var guard_offset: usize = undefined;
    var stack_top_offset: usize = undefined;
    var stack_offset: usize = undefined;
    var data_offset: usize = undefined;

    const map_bytes = blk: {
        var bytes: usize = page_size;
        guard_offset = bytes;

        bytes += @max(page_size, stack_size);
        stack_top_offset = bytes;
        bytes = mem.alignForward(usize, bytes, page_size);
        stack_offset = bytes;

        bytes = data_align.forward(bytes);
        data_offset = bytes;
        bytes += data_size;

        bytes = mem.alignForward(usize, bytes, page_size);
        break :blk bytes;
    };

    const mapped = posix.mmap(
        null,
        map_bytes,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch |err| switch (err) {
        error.MemoryMappingNotSupported,
        error.AccessDenied,
        error.PermissionDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.MappingAlreadyExists,
        => unreachable,
        else => return error.OutOfMemory,
    };
    errdefer posix.munmap(mapped);

    if (std.os.linux.mprotect(
        mapped.ptr + guard_offset,
        mapped.len - guard_offset,
        posix.PROT{
            .READ = true,
            .WRITE = true,
        },
    ) != 0) return error.OutOfMemory;

    const stack_bottom = &mapped[stack_offset];

    self.* = .{
        .allocated = mapped,
        .data = &mapped[data_offset],
        .fn_ptr = @ptrCast(&StackState.alwaysYield),
        .stack = .{
            .top = &mapped[stack_top_offset],
            .bottom = stack_bottom,
            // -8 because the C calling convention also counts the base pointer
            // for stack alignement.
            .rsp = @ptrFromInt(@intFromPtr(stack_bottom) - @sizeOf(usize)),
            .rbp = stack_bottom,
            .rip = &StackState.alwaysYield,
        },
        .state = .{
            .canceled = false,
            .max_sleep_time = -1,
        },
    };
}

fn destroyLinux(self: AnyCoroutine) void {
    if (self.allocated.len == 0) return;
    posix.munmap(self.allocated);
}

pub const create = switch (os_tag) {
    .linux => createLinux,
    else => private.compileError("Coroutines for \"{t}\": Not Yet Implemented", .{os_tag}),
};

pub const destroy = switch (os_tag) {
    .linux => destroyLinux,
    else => private.compileError("Coroutines for \"{t}\": Not Yet Implemented", .{os_tag}),
};

pub fn reinit(self: *AnyCoroutine) void {
    self.stack.rsp = self.stack.bottom;
    self.stack.rbp = self.stack.bottom;
    self.stack.rip = self.fn_ptr;
    self.state.canceled = false;
}

allocated: []align(page_size_min) u8,
data: *anyopaque,
fn_ptr: *const CoroFunction,
stack: StackState,
state: IoImpl,

pub const static_io = Io{ .userdata = null, .vtable = &IoImpl.vtable };

pub fn yield(self: *AnyCoroutine) Io.Cancelable!void {
    self.stack.switchStack();
    if (self.state.canceled) return error.Canceled;
}

/// A thin IO implementation for non-blocking files/sockets.
///
/// Does not implement anything other than networking currently.
///
/// External polling required.
pub fn io(self: *AnyCoroutine) Io {
    return .{
        .userdata = self,
        .vtable = &IoImpl.vtable,
    };
}

