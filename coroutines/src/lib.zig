//! Cooperative multi-tasking with Green Threads/User Scheduled Threads/Coroutines/Fibers
//!
//! How to use:
//! ```zig
//! var co: Coroutine(my_async_function) = undefined;
//! try co.init(.{}, .{ args... });
//!
//! if (coro.@"resume"()) {
//!     // for ReturnType == void
//! }
//!
//! if (coro.@"resume"()) |may_v| {
//!     if (may_v) |v| {
//!         // for @typeInfo(ReturnType) == .error_union
//!     } else {
//!         ...
//!     }
//! } else |e| {
//!     ...
//! }
//!
//! if (coro.@"resume"()) |v| {
//!     // for anything else
//! }
//!
//! fn my_async_function(gt: *AnyCoroutine, <args...>) <ReturnType> { ... }
//! ```
//!
//! TODO: Support more architectures. (and windows)
//!

const std = @import("std");
const private = @import("private.zig");

const Allocator = std.mem.Allocator;

const StackState = private.StackState;
const AdaptedReturnType = private.AdaptedReturnType;
const ReturnType = private.ReturnType;
const CoroFunction = private.CoroFunction;
const FnPtr = private.FnPtr;
const Args = private.Args;
const convertReturnType = private.convertReturnType;

/// This struct should not be initialized anywhere else than
/// in this library. It is passed as the first argument of
/// coroutines.
pub const AnyCoroutine = @import("AnyCoroutine.zig");
pub const polling = @import("polling.zig");

pub const InitOptions = struct {
    stack_size: usize = default_stack_size,
    /// `null` means the coroutine can sleep as much as it wants.
    max_sleep_time: ?u95 = 10 * std.time.ns_per_us,

    /// Seems about right...
    pub const default_stack_size = 1 * 1024 * 1024;
};

/// Invalid values for `T` includes:
///   - `noreturn`
///   - `@TypeOf(null)`
///   - `comptime_float`/`comptime_int`
///   - `type`
///   - `@TypeOf(undefined)`
///   - raw function types (`fn (arg0: type0, ...) ReturnType` instead of a pointer)
///   - opaque types
///   - frame/anyframe
///
/// General rule is: This construct is runtime **only**, as any comptime logic
/// would fail to run.
pub fn Coroutine(comptime T: type) type {
    const RetType = AdaptedReturnType(T);
    return struct {
        const Self = @This();

        any: AnyCoroutine,
        ret: ?T,

        /// Initializes a already-finished coroutine.
        ///
        /// `.@"resume"` can be called safely on it as many
        /// time as one wishes.
        ///
        /// Comptime friendly.
        pub fn initFinished(value: T) Self {
            return .{
                .any = .{
                    .allocated = &.{},
                    .stack = undefined,
                    .data = undefined,
                    .fn_ptr = undefined,
                    .state = undefined,
                },
                .ret = value,
            };
        }

        /// Raw initialization of a coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `function`: The function to call for the coroutine.
        ///   - `additional_data`: Data to be attached to the `*AnyCoroutine`.
        ///   - `data_align`: Alignment of `additional_data`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub fn initRaw(
            self: *Self,
            options: InitOptions,
            function: *const CoroFunction,
            additional_data: []const u8,
            data_align: std.mem.Alignment,
        ) Allocator.Error!void {
            try self.any.create(
                options.stack_size,
                additional_data.len,
                data_align,
            );
            @memcpy(@as([*]u8, @ptrCast(self.any.data)), additional_data);
            self.any.fn_ptr = function;
            self.any.stack.rip = function;
            self.any.state.max_sleep_time = options.max_sleep_time orelse -1;
            self.ret = null;
        }

        /// Will initialize the coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `Fn`: The type of `function`.
        ///   - `function`: The function to call for the coroutine.
        ///   - `args`: The arguments to pass to `function`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub fn initFnPtr(
            self: *Self,
            options: InitOptions,
            comptime Fn: type,
            function: FnPtr(Fn),
            args: Args(Fn),
        ) Allocator.Error!void {
            const Inner = struct {
                ptr: *const Fn,
                args: @TypeOf(args),

                fn call(co: *StackState) callconv(.c) noreturn {
                    const any: *AnyCoroutine = @alignCast(@fieldParentPtr("stack", co));
                    const _self: *Self = @fieldParentPtr("any", any);
                    const args_ptr: *@This() = @ptrCast(@alignCast(any.data));
                    // private.StackState.printCurrentStack();
                    _self.ret = @call(
                        .auto,
                        args_ptr.ptr,
                        .{any} ++ args_ptr.args,
                    );
                    co.switchStack();
                    unreachable; // switched to dead coroutine
                }
            };

            try self.initRaw(options, &Inner.call, @ptrCast(&Inner{
                .ptr = function,
                .args = args,
            }), .of(Inner));
        }

        /// Will initialize the coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `function`: The function to call for the coroutine.
        ///   - `args`: The arguments to pass to `function`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub inline fn init(
            self: *Self,
            options: InitOptions,
            comptime function: anytype,
            args: Args(@TypeOf(function)),
        ) Allocator.Error!void {
            return self.initFnPtr(options, @TypeOf(function), function, args);
        }

        /// Re-initialize the coroutine.
        ///
        /// Allows the previous function to run again without
        /// re-allocating memory. Useful for coroutines that can
        /// return values then re-runs right after.
        pub fn reinit(self: *Self) void {
            self.any.reinit();
            self.ret = null;
        }

        pub fn deinit(self: *Self) void {
            self.any.destroy();
            self.* = undefined;
        }

        pub fn await(self: *Self, kind: enum { await, cancel }) T {
            if (kind == .cancel) self.markCancel();
            while (self.ret == null) self.any.stack.switchStack();
            const ret = self.ret.?;
            return ret;
        }

        pub inline fn markCancel(self: *Self) void {
            self.any.state.cancel();
        }

        /// `RetType` is a transformation of `T`.
        /// Such as if `T` is `void`:
        ///   - It will return `true` when the coroutine
        ///     finished. `false` otherwise.
        ///
        /// If `T` is an error union:
        ///   - `?E!P` => `E!?P`
        ///
        /// otherwise it's just `?T` with `null` meaning
        /// it is not finished.
        pub fn @"resume"(self: *Self) RetType {
            return convertReturnType(T, self.resumeRaw());
        }

        pub fn hasFinished(self: Self) bool {
            return self.ret != null;
        }

        pub fn resumeRaw(self: *Self) ?T {
            if (self.ret) |ret| return ret;
            self.any.stack.switchStack();
            return self.ret;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Coroutine(void));
}
