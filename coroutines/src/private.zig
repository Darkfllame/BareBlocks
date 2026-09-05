const std = @import("std");
const builtin = @import("builtin");
const AnyCoroutine = @import("AnyCoroutine.zig");

const posix = std.posix;
const linux = std.os.linux;

pub const page_size_min = std.heap.page_size_min;
pub const os_tag = builtin.os.tag;
pub const is_windows = os_tag == .windows;
pub const is_linux = os_tag == .linux;
pub const is_debug = builtin.mode == .Debug;

/// If `T` is `void`:
///   - Converts `null` to `false`.
///   - and `{}` to `true`
///
/// If `T` is an error union:
///   - `?E!P` => `E!?P`
///
/// otherwise it's just `v`.
pub inline fn convertReturnType(comptime T: type, v: ?T) AdaptedReturnType(T) {
    const info = @typeInfo(T);
    return switch (info) {
        .void => if (v) |_| true else false,
        .error_union => |eu| if (v) |uni|
            if (uni) |value|
                convertReturnType(eu.payload, value)
            else |e|
                e
        else
            convertReturnType(eu.payload, null),
        .noreturn, .null, .@"opaque", .comptime_float, .comptime_int, .type, .undefined, .frame, .@"anyframe", .@"fn" => {
            @compileError("Invalid function return type: " ++ @tagName(info));
        },
        else => v,
    };
}

pub const StackState = extern struct {
    rsp: *anyopaque,
    rbp: *anyopaque,
    rip: *const anyopaque,
    top: *anyopaque,
    bottom: *anyopaque,

    pub inline fn switchStack(self: *StackState) void {
        if (is_windows) {
            const tib = &std.os.windows.teb().NtTib;
            const old = tib.*;
            tib.StackBase = self.bottom;
            tib.StackLimit = self.top;
            self.bottom = old.StackBase;
            self.top = tib.StackLimit;
        }
        asm volatile (
            \\ xchgq %%rsp, 0(%%rdi)
            \\ xchgq %%rbp, 8(%%rdi)
            \\ leaq 0f(%%rip), %%rax
            \\ xchgq %%rax, 16(%%rdi)
            \\ jmpq *%%rax
            \\0:
            :
            : [rawcoro] "{rdi}" (self),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            });
    }

    pub fn alwaysYield(self: *StackState) callconv(.c) noreturn {
        while (true) self.switchStack();
    }
};

pub fn AdaptedReturnType(comptime T: type) type {
    const info = @typeInfo(T);
    return switch (info) {
        .void => bool,
        .error_union => |eu| eu.error_set!AdaptedReturnType(eu.payload),
        .noreturn, .null, .@"opaque", .comptime_float, .comptime_int, .type, .undefined, .frame, .@"anyframe", .@"fn" => {
            @compileError("Invalid function return type: " ++ @tagName(info));
        },
        else => ?T,
    };
}

pub fn Args(comptime Fn: type) type {
    const info = switch (@typeInfo(Fn)) {
        .@"fn" => |f| f,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn" and p.size == .one)
            @typeInfo(p.child).@"fn"
        else
            @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
        else => @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
    };
    if (info.is_var_args) {
        @compileError("Function given to coroutine cannot be variadic");
    }
    if (info.is_generic) {
        @compileError("Function given to coroutine cannot be generic");
    }
    const params = info.params;
    if (params.len < 1 and params[0].type.? != *AnyCoroutine) {
        @compileError("Function must have at least 1 argument; Function's first argument should be *AnyCoroutine");
    }

    var types: [params.len - 1]type = undefined;
    for (params[1..], &types) |p, *t| {
        t.* = p.type.?;
    }
    return @Tuple(&types);
}

pub fn FnPtr(comptime Fn: type) type {
    return switch (@typeInfo(Fn)) {
        .@"fn" => *const Fn,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn" and p.size == .one)
            Fn
        else
            @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
        else => @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
    };
}

/// Helper function to get the return type of a function
/// or function type (`*const fn (...) <...>`).
pub fn ReturnType(comptime func: anytype) type {
    return sw: switch (@typeInfo(@TypeOf(func))) {
        .type => continue :sw @typeInfo(func),
        .@"fn" => |f| f.return_type.?,
        .pointer => |ptr| {
            if (ptr.size != .one or !ptr.is_const) {
                @compileError("func must be a function (type) or constant-pointer-to-function type");
            }
            continue :sw @typeInfo(ptr.child);
        },
        else => @compileError("func must be a function (type) or constant-pointer-to-function type"),
    };
}

/// Function signature for coroutines. Only used with `Coroutine(T).initRaw`
pub const CoroFunction = fn (*StackState) callconv(.c) noreturn;

pub fn timestampToPosix(nanoseconds: i96) posix.timespec {
    if (builtin.zig_backend == .stage2_wasm) {
        // Workaround for https://codeberg.org/ziglang/zig/issues/30575
        return .{
            .sec = @intCast(@divTrunc(nanoseconds, std.time.ns_per_s)),
            .nsec = @intCast(@rem(nanoseconds, std.time.ns_per_s)),
        };
    }
    return .{
        .sec = @intCast(@divFloor(nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(nanoseconds, std.time.ns_per_s)),
    };
}

pub fn unreachIoFunc(comptime name: []const u8) @FieldType(std.Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(std.Io.VTable, name)).pointer.child).@"fn";
    const RetType = info.return_type.?;

    return switch (info.param_types.len) {
        0 => &struct {
            fn inner() RetType {
                unreachable;
            }
        }.inner,
        1 => &struct {
            fn inner(_: info.param_types[0].?) RetType {
                unreachable;
            }
        }.inner,
        2 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?) RetType {
                unreachable;
            }
        }.inner,
        3 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?) RetType {
                unreachable;
            }
        }.inner,
        4 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?) RetType {
                unreachable;
            }
        }.inner,
        5 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?) RetType {
                unreachable;
            }
        }.inner,
        6 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?, _: info.param_types[5].?) RetType {
                unreachable;
            }
        }.inner,
        7 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?, _: info.param_types[5].?, _: info.param_types[6].?) RetType {
                unreachable;
            }
        }.inner,
        8 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?, _: info.param_types[5].?, _: info.param_types[6].?, _: info.param_types[7].?) RetType {
                unreachable;
            }
        }.inner,
        9 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?, _: info.param_types[5].?, _: info.param_types[6].?, _: info.param_types[7].?, _: info.param_types[8].?) RetType {
                unreachable;
            }
        }.inner,
        10 => &struct {
            fn inner(_: info.param_types[0].?, _: info.param_types[1].?, _: info.param_types[2].?, _: info.param_types[3].?, _: info.param_types[4].?, _: info.param_types[5].?, _: info.param_types[6].?, _: info.param_types[7].?, _: info.param_types[8].?, _: info.param_types[9].?) RetType {
                unreachable;
            }
        }.inner,
        else => @compileError("Not enough implementation"),
    };
}

pub inline fn compileError(comptime _format: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(_format, args));
}

pub const timestampFromPosix = std.Io.Threaded.timestampFromPosix;
pub const nanosecondsFromPosix = std.Io.Threaded.nanosecondsFromPosix;
pub const clockToPosix = std.Io.Threaded.clockToPosix;
