const Client = @This();
const std = @import("std");
const sdl = @import("sdl");
const vk = @import("vulkan");
const Renderer = @import("Renderer.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;

const logger = std.log.scoped(.@"bare_blocks/Client");

gpa: Allocator,
arena: *std.heap.ArenaAllocator,
io: Io,
args: process.Args,
envmap: *const process.Environ.Map,

vk_alloc_cb: vk.AllocationCallbacks,

renderer: Renderer,

win: *sdl.SDL_Window,
ren: *sdl.SDL_Renderer,

pub fn create(init: process.Init, vk_loader: vk.PfnGetInstanceProcAddr, sdl_vk_exts: []const [*:0]const u8) !*Client {
    const self = try init.gpa.create(Client);
    errdefer init.gpa.destroy(self);

    self.* = .{
        .gpa = init.gpa,
        .arena = init.arena,
        .io = init.io,
        .args = init.minimal.args,
        .envmap = init.environ_map,

        .vk_alloc_cb = undefined,

        .renderer = undefined,

        .win = undefined,
        .ren = undefined,
    };

    try self.renderer.init(.{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .vk_loader = vk_loader,
        .sdl_vk_exts = sdl_vk_exts,
    });
    errdefer self.renderer.deinit(self.gpa);

    self.win = sdl.SDL_CreateWindow("balblabla", 800, 600, 0) orelse return error.SDL;
    errdefer sdl.SDL_DestroyWindow(self.win);

    self.ren = sdl.SDL_CreateRenderer(self.win, null) orelse return error.SDL;
    errdefer sdl.SDL_DestroyRenderer(self.ren);

    return self;
}

pub fn destroy(self: *Client) void {
    sdl.SDL_DestroyRenderer(self.ren);
    sdl.SDL_DestroyWindow(self.win);
    self.renderer.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn tick(self: *Client) !void {
    _ = sdl.SDL_RenderPresent(self.ren);
}

pub fn onEvent(self: *Client, ev: *const sdl.SDL_Event) !enum { @"continue", success } {
    _ = self; // autofix
    // const windowID = sdl.SDL_GetWindowID(self.win);
    switch (ev.type) {
        sdl.SDL_EVENT_QUIT => return .success,
        else => {},
    }
    return .@"continue";
}
