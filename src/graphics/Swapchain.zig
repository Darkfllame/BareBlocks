const Swapchain = @This();
const std = @import("std");
const vk = @import("vulkan");
const sdl = @import("sdl");
const Device = @import("Device.zig");

const logger = std.log.scoped(.@"graphics/Swapchain");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

extern fn SDL_Vulkan_CreateSurface(
    window: *sdl.SDL_Window,
    instance: vk.Instance,
    allocator: ?*const vk.AllocationCallbacks,
    surface_out: *vk.SurfaceKHR,
) callconv(.c) bool;

fn deinitSwapchain(self: *Swapchain, allocator: Allocator) void {
    allocator.free(self.images[0..self.image_count]);
    {
        const img_views = self.img_views[0..self.image_count];
        for (img_views) |iv| {
            self.vk_device.destroyImageView(iv, null);
        }
        allocator.free(img_views);
    }
    self.vk_device.destroySwapchainKHR(self.handle, null);
}

fn getCommandBuffer(self: *Swapchain) vk.CommandBufferProxy {
    return vk.CommandBufferProxy.init(
        self.command_buffers[self.current_frame + self.image_index * self.max_frames_in_flight],
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

vk_device: vk.DeviceProxy,
device: *const Device,
handle: vk.SwapchainKHR,
surface: vk.SurfaceKHR,
extent: vk.Extent2D,
max_frames_in_flight: u8,
image_count: u8,
surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
images: [*]vk.Image,
img_views: [*]vk.ImageView,

command_buffers: [*]vk.CommandBuffer,
render_semaphores: [*]vk.Semaphore,
present_semaphores: [*]vk.Semaphore,
presentation_fences: [*]vk.Fence,
image_index: u32,
current_frame: u8,

pub const InitInfo = struct {
    gpa: Allocator,
    window: *sdl.SDL_Window,
    instance: vk.InstanceProxy,
    device: *const Device,
    max_frames_in_flight: u8 = 2,
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

    self.vk_device = info.device.proxy;
    self.device = info.device;
    self.handle = .null_handle;
    self.max_frames_in_flight = info.max_frames_in_flight;
    self.current_frame = 0;
    self.image_count = 0;
    try self.recreate(info.gpa, info.instance, info.window, info.device.pdev);
    errdefer self.deinitSwapchain(info.gpa);

    const cmd_buffers = try info.gpa.alloc(vk.CommandBuffer, self.image_count * self.max_frames_in_flight);
    errdefer info.gpa.free(cmd_buffers);
    self.command_buffers = cmd_buffers.ptr;

    const rsems = try info.gpa.alloc(vk.Semaphore, self.image_count * self.max_frames_in_flight);
    errdefer info.gpa.free(rsems);
    self.render_semaphores = rsems.ptr;

    const psems = try info.gpa.alloc(vk.Semaphore, self.max_frames_in_flight);
    errdefer info.gpa.free(psems);
    self.present_semaphores = psems.ptr;

    const pfences = try info.gpa.alloc(vk.Fence, self.max_frames_in_flight);
    errdefer info.gpa.free(pfences);
    self.presentation_fences = pfences.ptr;

    try self.vk_device.allocateCommandBuffers(
        &vk.CommandBufferAllocateInfo{
            .level = .primary,
            .command_buffer_count = @intCast(cmd_buffers.len),
            .command_pool = info.device.command_pool,
        },
        cmd_buffers.ptr,
    );
    errdefer self.vk_device.freeCommandBuffers(info.device.command_pool, cmd_buffers);

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
        sem.* = try self.vk_device.createSemaphore(&.{}, null);
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
}

pub fn deinit(self: *Swapchain, allocator: Allocator, instance: vk.InstanceProxy) void {
    self.deinitSwapchain(allocator);
    for (self.render_semaphores[0 .. self.image_count * self.max_frames_in_flight]) |sem| {
        self.vk_device.destroySemaphore(sem, null);
    }
    for (self.present_semaphores[0..self.max_frames_in_flight], self.presentation_fences[0..self.max_frames_in_flight]) |psem, pfence| {
        self.vk_device.destroySemaphore(psem, null);
        self.vk_device.destroyFence(pfence, null);
    }
    self.vk_device.freeCommandBuffers(self.device.command_pool, self.command_buffers[0..self.image_count]);
    if (self.surface != .null_handle) {
        instance.destroySurfaceKHR(self.surface, null);
    }

    allocator.free(self.command_buffers[0 .. self.image_count * self.max_frames_in_flight]);
    allocator.free(self.render_semaphores[0 .. self.image_count * self.max_frames_in_flight]);
    allocator.free(self.present_semaphores[0..self.max_frames_in_flight]);
    allocator.free(self.presentation_fences[0..self.max_frames_in_flight]);
}

pub fn recreate(
    self: *Swapchain,
    gpa: Allocator,
    instance: vk.InstanceProxy,
    window: *sdl.SDL_Window,
    pdev: vk.PhysicalDevice,
) !void {
    var win_pxw: u32 = undefined;
    var win_pxh: u32 = undefined;
    assert(sdl.SDL_GetWindowSizeInPixels(window, @ptrCast(&win_pxw), @ptrCast(&win_pxh)));

    const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        pdev,
        self.surface,
    );

    const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        pdev,
        self.surface,
        gpa,
    );
    defer gpa.free(formats);
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
        pdev,
        self.surface,
        gpa,
    );
    defer gpa.free(present_modes);
    var has_fifo = false;
    const pm: vk.PresentModeKHR = for (present_modes) |pm| {
        if (pm == .fifo_khr) {
            has_fifo = true;
        } else if (pm == .mailbox_khr) {
            break pm;
        }
    } else if (has_fifo) .fifo_khr else {
        @branchHint(.cold);
        logger.err("FIFO Present mode should always be present. Bug in the vulkan driver ?", .{});
        return error.Vulkan;
    };
    self.present_mode = pm;

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
    self.handle = try self.vk_device.createSwapchainKHR(&create_info, null);

    const old_img_count = self.image_count * self.max_frames_in_flight;
    self.image_count = 0;
    var image_count: u32 = undefined;
    _ = try self.vk_device.getSwapchainImagesKHR(
        self.handle,
        &image_count,
        null,
    );

    const images = try gpa.realloc(self.images[0..old_img_count], image_count);
    self.images = images.ptr;
    errdefer gpa.free(images);
    _ = try self.vk_device.getSwapchainImagesKHR(
        self.handle,
        &image_count,
        self.images,
    );

    const views = try gpa.realloc(self.img_views[0..old_img_count], image_count);
    self.img_views = views.ptr;
    errdefer gpa.free(views);

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

    self.image_count = @intCast(images.len);
}

pub fn beginDraw(self: *Swapchain) !vk.CommandBufferProxy {
    const frame_fence = self.presentation_fences[self.current_frame..][0..1];
    _ = try self.vk_device.waitForFences(frame_fence, .true, ~@as(u64, 0));
    try self.vk_device.resetFences(frame_fence);

    const next = try self.vk_device.acquireNextImageKHR(
        self.handle,
        ~@as(u64, 0),
        self.present_semaphores[self.current_frame],
        .null_handle,
    );
    switch (next.result) {
        .success => {},
        .timeout => unreachable,
        .suboptimal_khr => {},
        .not_ready => {},
        else => unreachable,
    }
    self.image_index = next.image_index;
    const cmd = self.getCommandBuffer();
    // cmd.resetCommandBuffer(.{}) catch unreachable;
    try cmd.beginCommandBuffer(&.{});

    self.transitionImageLayout(
        next.image_index,
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
            .image_view = self.img_views[next.image_index],
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
    const cmd = self.getCommandBuffer();
    cmd.resetCommandBuffer(.{}) catch unreachable;
}

pub fn endDraw(self: *Swapchain) !void {
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
    try cmd.endCommandBuffer();
    const gqueue = self.device.getQueue(.graphics);
    const pqueue = self.device.getQueue(.present);

    const frame_index = self.current_frame + self.image_index * self.max_frames_in_flight;
    try gqueue.submit(&[_]vk.SubmitInfo{vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = self.present_semaphores[self.current_frame..],
        .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{
            .color_attachment_output_bit = true,
        }},
        .command_buffer_count = 1,
        .p_command_buffers = self.command_buffers[frame_index..],
        .signal_semaphore_count = 1,
        .p_signal_semaphores = self.render_semaphores[frame_index..],
    }}, self.presentation_fences[self.current_frame]);
    _ = try pqueue.presentKHR(&vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = self.render_semaphores[frame_index..],
        .swapchain_count = 1,
        .p_swapchains = (&self.handle)[0..1],
        .p_image_indices = @ptrCast(&self.image_index),
    });
    self.current_frame = (self.current_frame + 1) % self.max_frames_in_flight;
}
