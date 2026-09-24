const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const vk = @import("vulkan");
const client = @import("client");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const assert = std.debug.assert;

const is_debug = builtin.mode == .Debug;

const logger = std.log.scoped(.@"bare_blocks/client");

const Wrapper = struct {
    init: process.Init,
    err: ?anyerror = null,
    app: ?*client.Client = null,
    sdl_inited: bool = false,
    sdl_vk_inited: bool = false,

    inline fn checkErrorSet(e: anytype) void {
        if (!is_debug) return; // no-op on release builds

        const E = @TypeOf(e);
        if (E == anyerror) {
            if (e == error.DeviceLost) @panic("Unexpected DeviceLost error");
        }
        comptime {
            for (@typeInfo(E).error_set.?) |err| {
                if (std.mem.eql(u8, err.name, "DeviceLost")) {
                    @compileError("error.DeviceLost in error set");
                }
            }
        }
    }

    fn sdlAppInit(ud_out: [*c]?*anyopaque, _: c_int, argv: [*c][*c]u8) callconv(.c) sdl.SDL_AppResult {
        const w: *Wrapper = @ptrCast(@alignCast(argv));
        ud_out.* = w;

        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            w.err = error.SDL;
            logger.err("Couldn't initialize SDL", .{});
            return sdl.SDL_APP_FAILURE;
        }
        w.sdl_inited = true;

        if (!sdl.SDL_Vulkan_LoadLibrary(null)) {
            w.err = error.SDL;
            logger.err("Couldn't load vulkan library", .{});
            return sdl.SDL_APP_FAILURE;
        }
        w.sdl_vk_inited = true;

        const vk_loader: ?vk.PfnGetInstanceProcAddr = @ptrCast(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr());
        if (vk_loader == null) {
            w.err = error.SDLVulkan;
            logger.err("Couldn't get vkGetInstanceProcAddr function", .{});
            return sdl.SDL_APP_FAILURE;
        }
        var ext_count: u32 = undefined;
        const exts = sdl.SDL_Vulkan_GetInstanceExtensions(&ext_count);
        assert(exts != null);

        w.app = client.Client.create(
            w.init,
            vk_loader.?,
            @ptrCast(exts[0..ext_count]),
        ) catch |e| {
            checkErrorSet(e);
            if (@errorReturnTrace()) |ert| {
                std.debug.dumpErrorReturnTrace(ert);
            }
            w.err = e;
            logger.err("Couldn't create application: {t}", .{e});
            return sdl.SDL_APP_FAILURE;
        };

        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlAppIter(ud: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
        const w: *Wrapper = @ptrCast(@alignCast(ud));
        w.app.?.tick() catch |e| {
            checkErrorSet(e);
            if (@errorReturnTrace()) |ert| {
                std.debug.dumpErrorReturnTrace(ert);
            }
            w.err = e;
            logger.err("Error while ticking: {t}", .{e});
            return sdl.SDL_APP_FAILURE;
        };
        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlAppEvent(ud: ?*anyopaque, ev: [*c]sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
        const w: *Wrapper = @ptrCast(@alignCast(ud));
        const res = w.app.?.onEvent(@ptrCast(ev)) catch |e| {
            if (@errorReturnTrace()) |ert| {
                std.debug.dumpErrorReturnTrace(ert);
            }
            w.err = e;
            logger.err("Error while handling event: {t}", .{e});
            return sdl.SDL_APP_FAILURE;
        };
        return switch (res) {
            .@"continue" => sdl.SDL_APP_CONTINUE,
            .success => sdl.SDL_APP_SUCCESS,
        };
    }

    fn sdlAppQuit(ud: ?*anyopaque, _: sdl.SDL_AppResult) callconv(.c) void {
        const w: *Wrapper = @ptrCast(@alignCast(ud));
        if (w.app) |app| {
            app.destroy();
            w.app = null;
        }

        if (w.sdl_vk_inited) {
            sdl.SDL_Vulkan_UnloadLibrary();
        }
        if (w.sdl_inited) {
            sdl.SDL_Quit();
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    sdl.SDL_SetMainReady();

    var w = Wrapper{ .init = init };

    const res = sdl.SDL_EnterAppMainCallbacks(
        undefined,
        @ptrCast(&w),
        Wrapper.sdlAppInit,
        Wrapper.sdlAppIter,
        Wrapper.sdlAppEvent,
        Wrapper.sdlAppQuit,
    );

    if (@as(?[*:0]const u8, @ptrCast(sdl.SDL_GetError()))) |err| may_err: {
        var msg = std.mem.span(err);
        for (msg, 0..) |c, i| {
            if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
                if (i == msg.len - 1) break :may_err;
                msg = msg[i..];
                break;
            }
        } else break :may_err;
        logger.err("SDL Error: {s}", .{msg});
    }

    return w.err orelse @truncate(@as(c_uint, @bitCast(res)));
}

test {
    std.testing.refAllDecls(@This());
}
