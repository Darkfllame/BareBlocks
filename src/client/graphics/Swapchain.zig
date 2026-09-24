const Swapchain = @This();
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const sdl = @import("sdl");
const Device = @import("Device.zig");

const logger = std.log.scoped(.@"graphics/Swapchain");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const is_debug = builtin.mode == .Debug;

extern fn SDL_Vulkan_CreateSurface(
    window: *sdl.SDL_Window,
    instance: vk.Instance,
    allocator: ?*const vk.AllocationCallbacks,
    surface_out: *vk.SurfaceKHR,
) callconv(.c) bool;

fn deinitSwapchain(self: *Swapchain, allocator: Allocator) void {
    const img_views = self.img_views[0..self.image_count];
    for (img_views) |iv| {
        self.vk_device.destroyImageView(iv, null);
    }
    self.vk_device.destroySwapchainKHR(self.handle, null);

    allocator.free(self.images[0..self.image_count]);
    allocator.free(img_views);
}

fn getCommandBuffer(self: *Swapchain) vk.CommandBufferProxy {
    return .init(
        self.command_buffers[self.current_frame + self.getImageIndex()],
        self.vk_device.wrapper,
    );
}

fn transitionImageLayout(
    self: *Swapchain,
    image_index: u32,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access_mask: vk.AccessFlags2,
    dst_access_mask: vk.AccessFlags2,
    src_stage_mask: vk.PipelineStageFlags2,
    dst_stage_mask: vk.PipelineStageFlags2,
) void {
    const cmd_buf = self.getCommandBuffer();
    cmd_buf.pipelineBarrier2(&vk.DependencyInfo{
        .dependency_flags = .{},
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = src_stage_mask,
            .src_access_mask = src_access_mask,
            .dst_stage_mask = dst_stage_mask,
            .dst_access_mask = dst_access_mask,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.images[image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }},
    });
}

const SyncObjectsSet = struct {
    cmd_buffers: [*]vk.CommandBuffer,
    tcmd_buffers: [*]vk.CommandBuffer,
    rsems: [*]vk.Semaphore,
    psems: [*]vk.Semaphore,
    pfences: [*]vk.Fence,
};

fn getSyncObjects(self: *Swapchain) SyncObjectsSet {
    return .{
        .cmd_buffers = self.command_buffers,
        .tcmd_buffers = self.tcmd_buffers,
        .rsems = self.render_semaphores,
        .psems = self.present_semaphores,
        .pfences = self.presentation_fences,
    };
}

fn setSyncObjectsSet(self: *Swapchain, set: SyncObjectsSet) void {
    self.command_buffers = set.cmd_buffers;
    self.tcmd_buffers = set.tcmd_buffers;
    self.render_semaphores = set.rsems;
    self.present_semaphores = set.psems;
    self.presentation_fences = set.pfences;
}

fn createSyncObjects(self: *Swapchain, allocator: Allocator) !SyncObjectsSet {
    const cmd_buffers = try allocator.alloc(vk.CommandBuffer, self.getImageCount());
    errdefer allocator.free(cmd_buffers);

    const tcmd_buffers = try allocator.alloc(vk.CommandBuffer, self.getImageCount());
    errdefer allocator.free(tcmd_buffers);

    const rsems = try allocator.alloc(vk.Semaphore, self.getImageCount());
    errdefer allocator.free(rsems);

    const psems = try allocator.alloc(vk.Semaphore, self.max_frames_in_flight);
    errdefer allocator.free(psems);

    const pfences = try allocator.alloc(vk.Fence, self.max_frames_in_flight * 2);
    errdefer allocator.free(pfences);

    try self.vk_device.allocateCommandBuffers(
        &vk.CommandBufferAllocateInfo{
            .level = .primary,
            .command_buffer_count = @intCast(cmd_buffers.len),
            .command_pool = self.device.command_pool,
        },
        cmd_buffers.ptr,
    );
    errdefer self.vk_device.freeCommandBuffers(self.device.command_pool, cmd_buffers);

    try self.vk_device.allocateCommandBuffers(
        &vk.CommandBufferAllocateInfo{
            .level = .primary,
            .command_buffer_count = @intCast(tcmd_buffers.len),
            .command_pool = self.device.transfer_command_pool,
        },
        tcmd_buffers.ptr,
    );
    errdefer self.vk_device.freeCommandBuffers(self.device.command_pool, tcmd_buffers);

    for (rsems, 0..) |*sem, i| {
        errdefer for (rsems[0..i]) |s| {
            self.vk_device.destroySemaphore(s, null);
        };
        sem.* = try self.vk_device.createSemaphore(&.{}, null);
    }
    errdefer for (rsems) |s| {
        self.vk_device.destroySemaphore(s, null);
    };

    for (psems, 0..) |*sem, i| {
        errdefer for (psems[0..i]) |s| {
            self.vk_device.destroySemaphore(s, null);
        };
        sem.* = try self.vk_device.createSemaphore(&vk.SemaphoreCreateInfo{}, null);
    }
    errdefer for (psems) |s| {
        self.vk_device.destroySemaphore(s, null);
    };

    for (pfences, 0..) |*fence, i| {
        errdefer for (pfences[0..i]) |f| {
            self.vk_device.destroyFence(f, null);
        };
        fence.* = try self.vk_device.createFence(&vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        }, null);
    }
    errdefer for (pfences) |f| {
        self.vk_device.destroyFence(f, null);
    };

    return .{
        .cmd_buffers = cmd_buffers.ptr,
        .tcmd_buffers = tcmd_buffers.ptr,
        .rsems = rsems.ptr,
        .psems = psems.ptr,
        .pfences = pfences.ptr,
    };
}

fn destroySyncObjects(self: *Swapchain, allocator: Allocator, set: SyncObjectsSet) void {
    const img_count = self.getImageCount();
    self.vk_device.freeCommandBuffers(self.device.command_pool, set.cmd_buffers[0..img_count]);
    self.vk_device.freeCommandBuffers(self.device.transfer_command_pool, set.tcmd_buffers[0..img_count]);
    for (set.rsems[0..img_count]) |s| {
        self.vk_device.destroySemaphore(s, null);
    }
    for (set.psems[0..self.max_frames_in_flight]) |s| {
        self.vk_device.destroySemaphore(s, null);
    }
    for (set.pfences[0 .. self.max_frames_in_flight * 2]) |f| {
        self.vk_device.destroyFence(f, null);
    }
    allocator.free(set.cmd_buffers[0..img_count]);
    allocator.free(set.tcmd_buffers[0..img_count]);
    allocator.free(set.rsems[0..img_count]);
    allocator.free(set.psems[0..self.max_frames_in_flight]);
    allocator.free(set.pfences[0 .. self.max_frames_in_flight * 2]);
}

fn recreateSwapchain(self: *Swapchain, allocator: Allocator, vsync: VsyncMode) !void {
    var win_pxw: u32 = undefined;
    var win_pxh: u32 = undefined;
    assert(sdl.SDL_GetWindowSizeInPixels(self.window, @ptrCast(&win_pxw), @ptrCast(&win_pxh)));
    const instance = self.device.instance;

    const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        self.device.pdev,
        self.surface,
    );

    const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        self.device.pdev,
        self.surface,
        allocator,
    );
    defer allocator.free(formats);
    const format = for (formats) |fmt| {
        if (fmt.color_space == .srgb_nonlinear_khr and fmt.format == .b8g8r8a8_srgb) {
            break fmt;
        }
    } else {
        @branchHint(.cold);
        logger.err("Couldn't find surface format", .{});
        return error.Vulkan;
    };
    self.surface_format = format;

    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        self.device.pdev,
        self.surface,
        allocator,
    );
    defer allocator.free(present_modes);

    var pm = vk.PresentModeKHR.fifo_khr;
    if (vsync == .disabled) {
        loop: for (present_modes) |available| switch (available) {
            .mailbox_khr => {
                pm = available;
                break :loop;
            },
            .immediate_khr => pm = available,
            .fifo_relaxed_khr => if (pm != .immediate_khr) {
                pm = available;
            },
            else => continue,
        };
    } else if (vsync == .adaptive) {
        for (present_modes) |available| {
            if (available == .fifo_relaxed_khr) {
                pm = .fifo_relaxed_khr;
                break;
            }
        }
    }

    const extent = blk: {
        if (capabilities.current_extent.width != std.math.maxInt(u32)) {
            break :blk capabilities.current_extent;
        }
        break :blk vk.Extent2D{
            .width = std.math.clamp(
                win_pxw,
                capabilities.min_image_extent.width,
                capabilities.max_image_extent.width,
            ),
            .height = std.math.clamp(
                win_pxh,
                capabilities.min_image_extent.height,
                capabilities.max_image_extent.height,
            ),
        };
    };
    self.extent = extent;

    var min_image_count = @max(3, capabilities.min_image_count);
    if (0 < capabilities.max_image_count and capabilities.max_image_count < min_image_count) {
        min_image_count = capabilities.min_image_count;
    }
    const create_info = vk.SwapchainCreateInfoKHR{
        .surface = self.surface,
        .min_image_count = min_image_count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = pm,
        .clipped = .true,
        .old_swapchain = self.handle,
    };
    const old_handle = self.handle;
    self.handle = self.vk_device.createSwapchainKHR(&create_info, null) catch |e| switch (e) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
        error.DeviceLost => @panic("GPU Device Lost"),
        error.SurfaceLostKHR => @panic("Surface Lost"),
        error.NativeWindowInUseKHR => unreachable,
        error.InitializationFailed => return error.InitializationFailed,
        error.CompressionExhaustedEXT => unreachable,
        error.ValidationFailed => unreachable,
        error.Unknown => unreachable,
    };
    errdefer self.vk_device.destroySwapchainKHR(self.handle, null);

    const old_img_count = self.image_count;
    self.image_count = 0;
    var image_count: u32 = undefined;
    _ = try self.vk_device.getSwapchainImagesKHR(
        self.handle,
        &image_count,
        null,
    );

    for (self.img_views[0..old_img_count]) |iv| {
        self.vk_device.destroyImageView(iv, null);
    }

    const images = allocator.realloc(self.images[0..old_img_count], image_count) catch |e| {
        allocator.free(self.images[0..old_img_count]);
        return e;
    };
    self.images = images.ptr;
    errdefer allocator.free(images);
    if (old_handle != .null_handle) {
        self.vk_device.destroySwapchainKHR(old_handle, null);
    }
    _ = try self.vk_device.getSwapchainImagesKHR(
        self.handle,
        &image_count,
        self.images,
    );

    const views = allocator.realloc(self.img_views[0..old_img_count], image_count) catch |e| {
        allocator.free(self.img_views[0..old_img_count]);
        return e;
    };
    self.img_views = views.ptr;
    errdefer allocator.free(views);

    var iv_ci = vk.ImageViewCreateInfo{
        .image = undefined,
        .view_type = .@"2d",
        .format = format.format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    for (images, views, 0..) |img, *iv, i| {
        errdefer for (views[0..i]) |iv2| {
            self.vk_device.destroyImageView(iv2, null);
        };
        iv_ci.image = img;
        iv.* = try self.vk_device.createImageView(&iv_ci, null);
    }

    errdefer for (views) |iv| { // prob not needed
        self.vk_device.destroyImageView(iv, null);
    };

    self.image_count = @intCast(image_count);
}

max_frames_in_flight: u8,
vsync_mode: VsyncMode,

vk_device: vk.DeviceProxy,
window: *sdl.SDL_Window,
device: *const Device,
handle: vk.SwapchainKHR,
surface: vk.SurfaceKHR,
extent: vk.Extent2D,

image_count: u8,
surface_format: vk.SurfaceFormatKHR,
images: [*]vk.Image,
img_views: [*]vk.ImageView,

/// `len = getImageCount()`
command_buffers: [*]vk.CommandBuffer,
/// Command buffers for transfer operations
///
/// `len = getImageCount()`
tcmd_buffers: [*]vk.CommandBuffer,
/// `len = getImageCount()`
render_semaphores: [*]vk.Semaphore,
/// `len = max_frames_in_flight`
present_semaphores: [*]vk.Semaphore,
/// `len = max_frames_in_flight * 2`
presentation_fences: [*]vk.Fence,
image_index: u32,
current_frame: u8,
draw_began: if (is_debug) bool else void,

pub const VsyncMode = enum { disabled, enabled, adaptive };
pub const InitInfo = struct {
    gpa: Allocator,
    window: *sdl.SDL_Window,
    instance: vk.InstanceProxy,
    device: *const Device,

    max_frames_in_flight: u8 = 2,
    vsync: VsyncMode = .enabled,
};
pub const RecreateOptions = struct {
    max_frames_in_flight: ?u8 = null,
    vsync: ?VsyncMode = null,
};

pub fn createSurface(self: *Swapchain, instance: vk.Instance, window: *sdl.SDL_Window) !void {
    if (!SDL_Vulkan_CreateSurface(
        window,
        instance,
        null,
        &self.surface,
    )) {
        logger.err("Couldn't create VkSurfaceKHR from SDL_Window", .{});
        return error.SDL;
    }
}

/// Assumes self.surface has already been created with `createSurface`.
pub fn init(self: *Swapchain, info: InitInfo) !void {
    assert(self.surface != .null_handle);

    self.max_frames_in_flight = info.max_frames_in_flight;
    self.vsync_mode = info.vsync;

    self.vk_device = info.device.proxy;
    self.window = info.window;
    self.device = info.device;
    self.handle = .null_handle;
    self.current_frame = 0;
    self.image_count = 0;
    self.image_index = 0;
    try self.recreateSwapchain(info.gpa, info.vsync);
    errdefer self.deinitSwapchain(info.gpa);

    const obj_set = try self.createSyncObjects(info.gpa);
    errdefer self.destroySyncObjects(info.gpa, obj_set);
    self.setSyncObjectsSet(obj_set);
}

pub fn deinit(self: *Swapchain, allocator: Allocator) void {
    if (is_debug and self.draw_began) {
        @panic("You must end rendering before deinitializing a swapchain");
    }
    self.device.queueWaitIdle(.present);
    self.deinitSwapchain(allocator);
    self.destroySyncObjects(allocator, self.getSyncObjects());
}

pub fn recreate(self: *Swapchain, allocator: Allocator, options: RecreateOptions) !void {
    // This function ensures that, even if it fails, calling .deinit() on <self> will not
    // crash in any way.

    const vsync_mode = options.vsync orelse self.vsync_mode;
    try self.recreateSwapchain(allocator, vsync_mode);
    self.vsync_mode = vsync_mode;

    if (options.max_frames_in_flight) |mfif| blk: {
        if (mfif == self.max_frames_in_flight) break :blk;

        const old_set = self.getSyncObjects();
        const new_set = try self.createSyncObjects(allocator);
        self.destroySyncObjects(allocator, old_set);
        self.setSyncObjectsSet(new_set);

        self.max_frames_in_flight = mfif;
    }
}

pub inline fn getImageCount(self: *Swapchain) usize {
    return self.image_count * self.max_frames_in_flight;
}

pub inline fn getImageIndex(self: *Swapchain) usize {
    return self.image_index * self.max_frames_in_flight;
}

pub fn beginTransfer(self: *Swapchain) !vk.CommandBufferProxy {
    const frame_fences = self.presentation_fences[self.current_frame * 2 ..][0..2];
    _ = self.vk_device.waitForFences(frame_fences[1..], .true, ~@as(u64, 0)) catch unreachable;

    const cmd = vk.CommandBufferProxy.init(
        self.tcmd_buffers[self.current_frame + self.getImageIndex()],
        self.vk_device.wrapper,
    );
    try cmd.beginCommandBuffer(&vk.CommandBufferBeginInfo{});
    return cmd;
}

pub fn endTransfer(self: *Swapchain) !void {
    const frame_fences = self.presentation_fences[self.current_frame * 2 ..][0..2];
    const cmd = vk.CommandBufferProxy.init(
        self.tcmd_buffers[self.current_frame + self.getImageIndex()],
        self.vk_device.wrapper,
    );
    try cmd.endCommandBuffer();
    self.vk_device.resetFences(frame_fences[1..]) catch unreachable;
    self.device.getQueue(.transfer).submit(&[_]vk.SubmitInfo{vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = self.tcmd_buffers[self.current_frame + self.getImageIndex() ..],
    }}, frame_fences[1]) catch |e| switch (e) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
        error.DeviceLost => @panic("GPU Device Lost"),
        error.ValidationFailed => unreachable,
        error.Unknown => unreachable,
    };
    _ = self.vk_device.waitForFences(frame_fences[1..], .true, ~@as(u64, 0)) catch unreachable;
}

pub fn beginDraw(self: *Swapchain, gpa: Allocator) !vk.CommandBufferProxy {
    if (is_debug) assert(!self.draw_began); // Frame already began

    const frame_fences = self.presentation_fences[self.current_frame * 2 ..][0..2];
    _ = self.vk_device.waitForFences(frame_fences[0..1], .true, ~@as(u64, 0)) catch unreachable;

    const next = retry_loop: while (true) {
        break :retry_loop self.vk_device.acquireNextImageKHR(
            self.handle,
            ~@as(u64, 0),
            self.present_semaphores[self.current_frame],
            .null_handle,
        ) catch |e| esw: switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            error.DeviceLost => @panic("GPU Device Lost"),
            error.SurfaceLostKHR => {
                const old_surface = self.surface;
                try self.createSurface(self.device.instance.handle, self.window);
                self.device.instance.destroySurfaceKHR(old_surface, null);
                continue :esw error.OutOfDateKHR;
            },
            error.OutOfDateKHR => {
                try self.recreate(gpa, .{});
                continue :retry_loop;
            },
            // Not using the extension related to this error code
            error.FullScreenExclusiveModeLostEXT => unreachable,
            error.ValidationFailed => unreachable,
            error.Unknown => unreachable,
        };
    };
    switch (next.result) {
        .success => {},
        .timeout => unreachable,
        .suboptimal_khr => {
            logger.debug("Sub-optimal swapchain", .{});
        },
        .not_ready => {
            logger.debug("Swapchain not ready", .{});
        },
        else => unreachable,
    }
    self.image_index = next.image_index;
    const cmd = self.getCommandBuffer();
    // cmd.resetCommandBuffer(.{}) catch unreachable;
    cmd.beginCommandBuffer(&.{}) catch |e| switch (e) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
        error.ValidationFailed => unreachable,
        error.Unknown => unreachable,
    };
    if (is_debug) self.draw_began = true;
    errdefer comptime unreachable; // May need to modify code

    self.transitionImageLayout(
        self.image_index,
        .undefined,
        .color_attachment_optimal,
        .{},
        .{ .color_attachment_write_bit = true },
        .{ .color_attachment_output_bit = true },
        .{ .color_attachment_output_bit = true },
    );
    cmd.beginRendering(&vk.RenderingInfo{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.extent,
        },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = &[_]vk.RenderingAttachmentInfo{.{
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .image_view = self.img_views[self.image_index],
            .image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = vk.ClearValue{
                .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
            },
        }},
    });
    cmd.setViewport(0, &.{vk.Viewport{
        .x = 0,
        .y = @as(f32, @floatFromInt(self.extent.height)),
        .width = @floatFromInt(self.extent.width),
        .height = -@as(f32, @floatFromInt(self.extent.height)),
        .max_depth = 1,
        .min_depth = 0,
    }});
    cmd.setScissor(0, &.{vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.extent,
    }});

    return cmd;
}

pub fn cancelDraw(self: *Swapchain) void {
    if (is_debug) {
        assert(self.draw_began);
        self.draw_began = false;
    }

    const cmd = self.getCommandBuffer();
    cmd.resetCommandBuffer(.{}) catch unreachable;
}

pub fn endDraw(self: *Swapchain, allocator: Allocator) !void {
    if (is_debug) {
        assert(self.draw_began);
        self.draw_began = false;
    }

    const cmd = self.getCommandBuffer();
    cmd.endRendering();
    self.transitionImageLayout(
        self.image_index,
        .color_attachment_optimal,
        .present_src_khr,
        .{ .color_attachment_write_bit = true },
        .{},
        .{ .color_attachment_output_bit = true },
        .{ .bottom_of_pipe_bit = true },
    );
    cmd.endCommandBuffer() catch |e| {
        cmd.resetCommandBuffer(.{}) catch unreachable;
        return e;
    };
    const gqueue = self.device.getQueue(.graphics);
    const pqueue = self.device.getQueue(.present);

    const frame_index = self.current_frame + self.getImageIndex();
    const frame_fences = self.presentation_fences[self.current_frame * 2 ..][0..2];
    self.vk_device.resetFences(frame_fences[0..1]) catch unreachable;

    gqueue.submit(&[_]vk.SubmitInfo{vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = self.present_semaphores[self.current_frame..],
        .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{
            .color_attachment_output_bit = true,
        }},
        .command_buffer_count = 1,
        .p_command_buffers = self.command_buffers[frame_index..],
        .signal_semaphore_count = 1,
        .p_signal_semaphores = self.render_semaphores[frame_index..],
    }}, frame_fences[0]) catch |e| switch (e) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
        error.DeviceLost => @panic("GPU Device Lost"),
        error.ValidationFailed => unreachable,
        error.Unknown => unreachable,
    };
    retry_loop: while (true) {
        const res = pqueue.presentKHR(&vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = self.render_semaphores[frame_index..],
            .swapchain_count = 1,
            .p_swapchains = (&self.handle)[0..1],
            .p_image_indices = @ptrCast(&self.image_index),
        }) catch |e| esw: switch (e) {
            error.OutOfHostMemory => return error.OutOfMemory,
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            error.DeviceLost => @panic("GPU Device Lost"),
            error.SurfaceLostKHR => {
                const old_surface = self.surface;
                try self.createSurface(self.device.instance.handle, self.window);
                self.device.instance.destroySurfaceKHR(old_surface, null);
                continue :esw error.OutOfDateKHR;
            },
            error.OutOfDateKHR => {
                try self.recreate(allocator, .{});
                continue :retry_loop;
            },
            error.FullScreenExclusiveModeLostEXT => unreachable,
            error.ValidationFailed => unreachable,
            error.PresentTimingQueueFullEXT => unreachable,
            error.Unknown => unreachable,
        };
        switch (res) {
            .success => {},
            .suboptimal_khr => {
                logger.debug("Sub-optimal swapchain", .{});
            },
            else => unreachable,
        }
        break;
    }
    self.current_frame = (self.current_frame + 1) % self.max_frames_in_flight;
}
