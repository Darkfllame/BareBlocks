// TODO: Clean up that shih :sob:
// Tutorial chapter: https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/02_Graphics_pipeline_basics/00_Introduction.html

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const utils = @import("utils");
const vk = @import("vulkan");
const sdl = @import("sdl");
const config = @import("config");

const logger = core.logger;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const assert = std.debug.assert;

const debug_required_extensions: []const [*:0]const u8 = &.{
    vk.extensions.ext_debug_utils.name.ptr,
};
const debug_required_layers: []const [*:0]const u8 = &.{
    "VK_LAYER_KHRONOS_validation",
};

const create_device_chain = vk.PhysicalDeviceFeatures2{
    .p_next = @constCast(&vk.PhysicalDeviceVulkan13Features{
        .p_next = @constCast(&vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
            .extended_dynamic_state = .true,
        }),
        .dynamic_rendering = .true,
    }),
    .features = .{},
};
const req_feats_slice: []const vk.Bool32 = @ptrCast(&create_device_chain.features);

fn stringFromBuffer(s: []const u8) [:0]const u8 {
    for (s, 0..) |c, i| {
        if (c == 0) return s[0..i :0];
    }
    @panic("Not zero terminated");
}

const DebugUtilsDataFormatter = struct {
    app: *App,
    callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,

    pub fn format(self: DebugUtilsDataFormatter, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.callback_data.p_message_id_name) |idname| {
            try writer.print("[{s} | {x}] ", .{ idname, @as(u32, @bitCast(self.callback_data.message_id_number)) });
        } else {
            try writer.print("[{x}] ", .{self.callback_data.message_id_number});
        }
        if (self.callback_data.p_next) |next| {
            const dab: *const vk.DeviceAddressBindingCallbackDataEXT = @ptrCast(@alignCast(next));
            try writer.print("{s}device address {x:0>16}[0..{d}]: {s}\n", .{
                if (dab.flags.internal_object_bit_ext) "internal " else "",
                dab.base_address,
                dab.size,
                switch (dab.binding_type) {
                    .bind_ext => "bound",
                    .unbind_ext => "unbound",
                    _ => unreachable,
                },
            });
        } else try writer.print("{s}\n", .{self.callback_data.p_message.?});
        const queue_labels = if (self.callback_data.p_queue_labels) |ptr|
            ptr[0..self.callback_data.queue_label_count]
        else
            &.{};
        const cmd_buf_labels = if (self.callback_data.p_cmd_buf_labels) |ptr|
            ptr[0..self.callback_data.cmd_buf_label_count]
        else
            &.{};
        const objects = if (self.callback_data.p_objects) |ptr|
            ptr[0..self.callback_data.object_count]
        else
            &.{};
        if (queue_labels.len != 0) {
            try writer.print(" - {d} queues:\n", .{queue_labels.len});
            for (queue_labels) |lbl| {
                var vecs = [_][]const u8{ "   - ", std.mem.span(lbl.p_label_name), "\n" };
                try writer.writeVecAll(&vecs);
            }
        }
        if (cmd_buf_labels.len != 0) {
            try writer.print(" - {d} command buffers:\n", .{cmd_buf_labels.len});
            for (cmd_buf_labels) |lbl| {
                var vecs = [_][]const u8{ "   - ", std.mem.span(lbl.p_label_name), "\n" };
                try writer.writeVecAll(&vecs);
            }
        }
        if (objects.len != 0) {
            try writer.print(" - {d} objects:\n", .{objects.len});
            for (objects, 0..) |obj, i| {
                try writer.print("   - {t}@{x:0>16}", .{ obj.object_type, obj.object_handle });
                if (obj.p_object_name) |name| {
                    try writer.print(" \"{s}\"", .{std.mem.span(name)});
                }
                if (i + 1 != objects.len) try writer.writeAll("\n");
            }
        }
    }
};

const QueueFamilyIndices = struct {
    const fields = @typeInfo(QueueFamilyIndices).@"struct".fields;
    const queue_priorities = [_]f32{0} ** fields.len;

    graphics: u32,
    transfer: u32,
    present: u32,

    /// Has same field names as `QueueFamilyIndices` but as `vk.Queue`.
    const Queues = blk: {
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attribs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (fields, &names, &types, &attribs) |f, *name, *T, *att| {
            name.* = f.name;
            T.* = vk.Queue;
            att.* = .{};
        }
        break :blk @Struct(.auto, null, &names, &types, &attribs);
    };

    fn init(
        self: *QueueFamilyIndices,
        app: *const App,
        pdev: vk.PhysicalDevice,
        qfps: []const vk.QueueFamilyProperties,
    ) !void {
        var graphics_family_index: ?u32 = null;
        var transfer_family_index: ?u32 = null;
        var present_family_index: ?u32 = null;

        for (qfps, 0..) |props, i| {
            if (graphics_family_index != null and transfer_family_index != null and
                present_family_index != null) break;

            var used: u32 = 0;

            if (graphics_family_index == null and props.queue_flags.graphics_bit) {
                graphics_family_index = @intCast(i);
                used += 1;
            }
            if (props.queue_count - used == 0) continue;

            if (transfer_family_index == null and
                (props.queue_flags.graphics_bit or props.queue_flags.compute_bit or props.queue_flags.transfer_bit))
            {
                transfer_family_index = @intCast(i);
                used += 1;
            }
            if (props.queue_count - used == 0) continue;

            if (present_family_index == null and
                (try app.vki.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), app.surface)) == .true)
            {
                present_family_index = @intCast(i);
                used += 1;
            }
        }
        if (graphics_family_index == null or transfer_family_index == null or
            present_family_index == null)
        {
            return error.Vulkan;
        }

        self.* = .{
            .graphics = graphics_family_index.?,
            .transfer = transfer_family_index.?,
            .present = present_family_index.?,
        };
    }

    fn calculateQueuCreateInfos(
        self: *QueueFamilyIndices,
        queueIndices: *QueueFamilyIndices,
        info_buffer: []vk.DeviceQueueCreateInfo,
    ) []const vk.DeviceQueueCreateInfo {
        var len: usize = 0;
        inline for (fields) |f| {
            const qfi = @field(self, f.name);

            buf_search: for (info_buffer[0..len]) |*qci| {
                if (qci.queue_family_index == qfi) {
                    @field(queueIndices, f.name) = qci.queue_count;
                    qci.queue_count += 1;
                    break :buf_search;
                }
            } else {
                info_buffer[len] = .{
                    .queue_family_index = qfi,
                    .queue_count = 1,
                    .p_queue_priorities = &queue_priorities,
                };
                @field(queueIndices, f.name) = 0;
                len += 1;
            }
        }
        return info_buffer[0..len];
    }
};

const App = struct {
    fn checkExtensions(self: *App, required: []const [*:0]const u8) !bool {
        if (required.len == 0) return true;

        var bitset = try std.DynamicBitSetUnmanaged.initEmpty(self.gpa, required.len);
        defer bitset.deinit(self.gpa);

        for (self.extensions_properties) |*ext| {
            const name = stringFromBuffer(&ext.extension_name);
            for (required, 0..) |req_namez, i| {
                if (std.mem.eql(u8, name, std.mem.span(req_namez))) {
                    if (bitset.isSet(i)) {
                        logger.warn("Duplicate extension in list: {s}", .{name});
                    }
                    bitset.set(i);

                    if (bitset.count() == required.len) return true;
                }
            }
        }

        var it = bitset.iterator(.{ .kind = .unset });
        while (it.next()) |idx| {
            logger.warn("Extension \"{s}\" not found", .{required[idx]});
        }

        return false;
    }

    fn checkLayers(self: *App, required: []const [*:0]const u8) !bool {
        if (required.len == 0) return true;

        var bitset = try std.DynamicBitSetUnmanaged.initEmpty(self.gpa, required.len);
        defer bitset.deinit(self.gpa);

        for (self.layers_properties) |*lay| {
            const name = stringFromBuffer(&lay.layer_name);
            for (required, 0..) |req_namez, i| {
                if (std.mem.eql(u8, name, std.mem.span(req_namez))) {
                    if (bitset.isSet(i)) {
                        logger.warn("Duplicate layer in list: {s}", .{name});
                    }
                    bitset.set(i);

                    if (bitset.count() == required.len) return true;
                }
            }
        }

        var it = bitset.iterator(.{ .kind = .unset });
        while (it.next()) |idx| {
            logger.warn("Layer \"{s}\" not found", .{required[idx]});
        }

        return false;
    }

    fn debugUtilsCallback(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_types: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: ?*anyopaque,
    ) callconv(vk.vulkan_call_conv) vk.Bool32 {
        if (p_callback_data == null) return .false;

        const vklog = std.log.scoped(.vk_debug_utils);

        const args = .{
            switch (message_types) {
                .{ .general_bit_ext = true } => "general",
                .{ .validation_bit_ext = true } => "validation",
                .{ .performance_bit_ext = true } => "performance",
                .{ .device_address_binding_bit_ext = true } => "device address binding",
                else => "<invalid type>",
            },
            DebugUtilsDataFormatter{
                .app = @ptrCast(@alignCast(p_user_data)),
                .callback_data = p_callback_data.?,
            },
        };
        switch (message_severity) {
            else => vklog.debug("[{s}] {f}", args),
            .{ .info_bit_ext = true } => vklog.info("[{s}] {f}", args),
            .{ .warning_bit_ext = true } => vklog.warn("[{s}] {f}", args),
            .{ .error_bit_ext = true } => vklog.err("[{s}] {f}", args),
        }

        return .false;
    }

    fn chosePhysicalDevice(self: *App) ?u8 {
        var highest_rating: u32 = 0;
        var best_index: ?u8 = null;
        for (self.phys_devs, 0..) |pdev, i| {
            var rating: u32 = 0;
            var feats: vk.PhysicalDeviceFeatures2 = .{ .features = undefined };
            self.vki.getPhysicalDeviceFeatures2(pdev, &feats);
            const feats_bools: []const vk.Bool32 = @ptrCast(&feats.features);
            const props = self.vki.getPhysicalDeviceProperties(pdev);
            rating += switch (props.device_type) {
                // I guess this should be fine for now...
                .discrete_gpu => 3,
                .virtual_gpu => 2,
                .integrated_gpu => 1,
                else => 0,
            };

            const feats_fields = @typeInfo(vk.PhysicalDeviceFeatures).@"struct".fields;
            for (0..feats_fields.len) |j| {
                if (req_feats_slice[i] == .true and feats_bools[j] == .false) {
                    rating = 0;
                }
            }
            if (highest_rating < rating) {
                highest_rating = rating;
                best_index = @intCast(i);
            }
        }

        return best_index;
    }

    fn createLogicalDevice(self: *App) !void {
        const pdev = self.phys_devs[self.chosen_pdev];
        const qfps = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, self.gpa);
        defer self.gpa.free(qfps);

        var family_indices: QueueFamilyIndices = undefined;
        var queue_indices: QueueFamilyIndices = undefined;

        family_indices.init(self, pdev, qfps) catch |e| {
            logger.err("Couldn't get all queue family indices", .{});
            return e;
        };

        var qci_buffer: [QueueFamilyIndices.fields.len]vk.DeviceQueueCreateInfo = undefined;
        const q_create_infos = family_indices.calculateQueuCreateInfos(&queue_indices, &qci_buffer);

        const extensions = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name.ptr,
        };

        self.device = try self.vki.createDevice(pdev, &vk.DeviceCreateInfo{
            .p_next = &create_device_chain,
            .queue_create_info_count = @intCast(q_create_infos.len),
            .p_queue_create_infos = q_create_infos.ptr,
            .enabled_extension_count = extensions.len,
            .pp_enabled_extension_names = &extensions,
        }, null);
        self.vkd = .load(self.device, self.vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer self.vkd.destroyDevice(self.device, null);

        inline for (QueueFamilyIndices.fields) |f| {
            @field(self.queues, f.name) = self.vkd.getDeviceQueue(
                self.device,
                @field(family_indices, f.name),
                @field(queue_indices, f.name),
            );
        }
    }

    fn recreateSwapchain(self: *App) !void {
        var win_pxw: u32 = undefined;
        var win_pxh: u32 = undefined;
        assert(sdl.SDL_GetWindowSizeInPixels(self.window, @ptrCast(&win_pxw), @ptrCast(&win_pxh)));

        const capabilities = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(
            self.phys_devs[self.chosen_pdev],
            self.surface,
        );

        const formats = try self.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(
            self.phys_devs[self.chosen_pdev],
            self.surface,
            self.gpa,
        );
        defer self.gpa.free(formats);
        const fmt_idx = for (formats, 0..) |fmt, i| {
            if (fmt.color_space == .srgb_nonlinear_khr and fmt.format == .b8g8r8a8_srgb) {
                break i;
            }
        } else {
            @branchHint(.cold);
            logger.err("Couldn't find surface format", .{});
            return error.Vulkan;
        };

        const present_modes = try self.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(
            self.phys_devs[self.chosen_pdev],
            self.surface,
            self.gpa,
        );
        defer self.gpa.free(present_modes);
        var fifo_idx: ?usize = null;
        const pm_idx = for (present_modes, 0..) |pm, i| {
            if (pm == .fifo_khr) {
                fifo_idx = i;
            } else if (pm == .mailbox_khr) {
                break i;
            }
        } else fifo_idx orelse {
            @branchHint(.cold);
            logger.err("FIFO Present mode should always be present. Bug in the vulkan driver ?", .{});
            return error.Vulkan;
        };

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

        var min_image_count = @max(3, capabilities.min_image_count);
        if (0 < capabilities.max_image_count and capabilities.max_image_count < min_image_count) {
            min_image_count = capabilities.min_image_count;
        }
        self.swapchain.handle = try self.vkd.createSwapchainKHR(self.device, &vk.SwapchainCreateInfoKHR{
            .surface = self.surface,
            .min_image_count = min_image_count,
            .image_format = formats[fmt_idx].format,
            .image_color_space = formats[fmt_idx].color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_modes[pm_idx],
            .clipped = .true,
            .old_swapchain = self.swapchain,
        }, null);

        self.swapchain.image_count = 0;
        var image_count: u32 = undefined;
        _ = try self.vkd.getSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &image_count,
            null,
        );
        const images = try self.gpa.realloc(self.swapchain.getImages(), image_count);
        self.swapchain.images = images.ptr;
        errdefer self.gpa.free(images);
        _ = try self.vkd.getSwapchainImagesKHR(
            self.device,
            self.swapchain,
            &image_count,
            @constCast(self.swapchain.images.?),
        );

        const views = try self.gpa.realloc(self.swapchain.getImageViews(), image_count);
        self.swapchain.img_views = views.ptr;
        errdefer self.gpa.free(views);

        var iv_ci = vk.ImageViewCreateInfo{
            .image = undefined,
            .view_type = .@"2d",
            .format = formats[fmt_idx].format,
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
                self.vkd.destroyImageView(self.device, iv2, null);
            };
            iv_ci.image = img;
            iv.* = try self.vkd.createImageView(self.device, &iv_ci, null);
        }

        errdefer for (views) |iv| { // prob not needed
            self.vkd.destroyImageView(self.device, iv, null);
        };

        self.swapchain.image_count = @intCast(images.len);
    }

    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    io: Io,
    args: process.Args,
    envmap: *const process.Environ.Map,

    window: *sdl.SDL_Window,

    extensions_properties: []const vk.ExtensionProperties,
    layers_properties: []const vk.LayerProperties,

    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,

    debug_messenger: if (builtin.mode == .Debug) vk.DebugUtilsMessengerEXT else void,

    phys_devs: []const vk.PhysicalDevice,
    // More than 256 is not happening soon LMAO
    /// Index into `phys_devs`
    chosen_pdev: u8,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    device: vk.Device,
    queues: QueueFamilyIndices.Queues,

    swapchain: struct {
        handle: vk.SwapchainKHR = .null_handle,
        image_count: u8 = 0,
        images: ?[*]const vk.Image = null,
        img_views: ?[*]const vk.ImageView = null,

        fn getImages(self: @This()) []const vk.Image {
            return if (self.images) |imgs| imgs[0..self.image_count] else &.{};
        }

        fn getImageViews(self: @This()) []const vk.ImageView {
            return if (self.img_views) |imgs| imgs[0..self.image_count] else &.{};
        }
    },

    pub fn create(
        init: process.Init,
        vk_loader: vk.PfnGetInstanceProcAddr,
        sdl_vk_exts: []const [*:0]const u8,
    ) !*App {
        const self = try init.gpa.create(App);
        errdefer init.gpa.destroy(self);
        self.gpa = init.gpa;
        self.arena = init.arena;
        self.io = init.io;
        self.args = init.minimal.args;
        self.envmap = init.environ_map;

        self.window = sdl.SDL_CreateWindow(
            "Bare Blocks | IN-DEV",
            800,
            600,
            sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_HIDDEN,
        ) orelse {
            logger.err("Failed to create window", .{});
            return error.SDL;
        };
        errdefer sdl.SDL_DestroyWindow(self.window);

        self.vkb = .load(vk_loader);

        //#region VkInstance
        const all_required_extensions = try std.mem.concat(
            self.gpa,
            [*:0]const u8,
            &.{
                sdl_vk_exts,
                if (builtin.mode == .Debug) debug_required_extensions else &.{},
            },
        );
        defer self.gpa.free(all_required_extensions);

        const all_required_layers: []const [*:0]const u8 = if (builtin.mode == .Debug) debug_required_layers else &.{};
        // const all_required_layers = try std.mem.concat(self.gpa, [*:0]const u8, &.{});
        // defer self.gpa.free(all_required_layers);

        self.extensions_properties = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, self.gpa);
        errdefer self.gpa.free(self.extensions_properties);

        self.layers_properties = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.gpa);
        errdefer self.gpa.free(self.layers_properties);

        if (!try self.checkExtensions(all_required_extensions)) {
            return error.ExtensionNotFound;
        }
        if (!try self.checkLayers(all_required_layers)) {
            return error.LayerNotFound;
        }

        const vk_version = vk.makeApiVersion(
            0,
            config.version.major,
            config.version.minor,
            config.version.patch,
        ).toU32();

        // Ideally, this will not be in the final executable except in debug mode
        var msg_cinfo: vk.DebugUtilsMessengerCreateInfoEXT = undefined;
        var inst_cinfo = vk.InstanceCreateInfo{
            .p_application_info = &vk.ApplicationInfo{
                .p_application_name = "Bare Blocks",
                .application_version = vk_version,
                .p_engine_name = "BareBlocks",
                .engine_version = vk_version,
                .api_version = vk.API_VERSION_1_4.toU32(),
            },
            .enabled_layer_count = @intCast(all_required_layers.len),
            .pp_enabled_layer_names = all_required_layers.ptr,
            .enabled_extension_count = @intCast(all_required_extensions.len),
            .pp_enabled_extension_names = all_required_extensions.ptr,
        };
        if (builtin.mode == .Debug) {
            msg_cinfo = .{
                .message_severity = .{
                    .verbose_bit_ext = false,
                    .info_bit_ext = false,
                    .warning_bit_ext = true,
                    .error_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = false,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                    .device_address_binding_bit_ext = false,
                },
                .pfn_user_callback = &debugUtilsCallback,
                .p_user_data = self,
            };
            inst_cinfo.p_next = &msg_cinfo;
        }

        self.instance = try self.vkb.createInstance(&inst_cinfo, null);
        self.vki = .load(self.instance, vk_loader);
        errdefer self.vki.destroyInstance(self.instance, null);
        //#endregion VkInstance

        //#region VkSurfaceKHR
        if (!sdl.SDL_Vulkan_CreateSurface(
            self.window,
            @ptrFromInt(@intFromEnum(self.instance)),
            null,
            @ptrCast(&self.surface),
        )) {
            logger.err("Couldn't create VkSurfaceKHR from SDL_Window", .{});
            return error.SDL;
        }
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        //#endregion VkSurfaceKHR

        //#region VkPhysicalDevice
        {
            var count: u32 = undefined;
            _ = try self.vki.enumeratePhysicalDevices(self.instance, &count, null);
            if (count > 255) {
                logger.warn("Why the f#ck do you have {d} gpus dude 💀", .{count});
                count = 255;
            }
            self.phys_devs = try self.gpa.alloc(vk.PhysicalDevice, count);
            errdefer self.gpa.free(self.phys_devs);
            _ = try self.vki.enumeratePhysicalDevices(self.instance, &count, @constCast(self.phys_devs.ptr));
        }
        errdefer self.gpa.free(self.phys_devs);

        self.chosen_pdev = self.chosePhysicalDevice() orelse {
            logger.err("Couldn't choose physical device", .{});
            return error.Vulkan;
        };

        {
            const props = self.vki.getPhysicalDeviceProperties(self.phys_devs[self.chosen_pdev]);
            const apiver: vk.Version = @bitCast(props.api_version);
            const dver: vk.Version = @bitCast(props.driver_version);
            logger.info(
                \\Chose GPU#{d} "{s}":
                \\ - api version: {d}.{d}.{d}.{d}
                \\ - driver version: {d}.{d}.{d}.{d}
                \\ - type: {t}
                \\ - vendor id: {X}
                \\ - device id: {X}
                \\ - pipeline cache uuid: {f}
            , .{
                self.chosen_pdev,  stringFromBuffer(&props.device_name),

                apiver.variant,    apiver.major,
                apiver.minor,      apiver.patch,

                dver.variant,      dver.major,
                dver.minor,        dver.patch,

                props.device_type, props.vendor_id,
                props.device_id,   utils.UUID.from(@bitCast(props.pipeline_cache_uuid)),
            });
        }
        //#endregion VkPhysicalDevice

        //#region VkDevice
        try self.createLogicalDevice();
        errdefer self.vkd.destroyDevice(self.device, null);
        //#endregion VkDevice

        //#region VkSwapchainKHR
        self.swapchain = .{};
        try self.recreateSwapchain();
        errdefer self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
        //#endregion VkSwapchainKHR

        _ = sdl.SDL_ShowWindow(self.window);
        return self;
    }

    pub fn destroy(self: *App) void {
        for (self.swapchain.getImageViews()) |iv| {
            self.vkd.destroyImageView(self.device, iv, null);
        }
        self.gpa.free(self.swapchain.getImageViews());
        self.gpa.free(self.swapchain.getImages());
        self.vkd.destroySwapchainKHR(self.device, self.swapchain.handle, null);
        self.vkd.destroyDevice(self.device, null);
        self.gpa.free(self.phys_devs);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
        self.gpa.free(self.layers_properties);
        self.gpa.free(self.extensions_properties);
        sdl.SDL_DestroyWindow(self.window);
        self.gpa.destroy(self);
    }

    pub fn tick(self: *App) !void {
        _ = self;
    }

    pub fn onEvent(self: *App, ev: *sdl.SDL_Event) !enum { @"continue", success } {
        _ = self;
        if (ev.type == sdl.SDL_EVENT_QUIT) {
            // .success ends the application
            return .success;
        }
        return .@"continue";
    }
};

const Wrapper = struct {
    init: process.Init,
    err: ?anyerror = null,
    app: ?*App = null,
    sdl_inited: bool = false,
    sdl_vk_inited: bool = false,

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

        w.app = App.create(
            w.init,
            vk_loader.?,
            @ptrCast(exts[0..ext_count]),
        ) catch |e| {
            w.err = e;
            logger.err("Couldn't create application: {t}", .{e});
            return sdl.SDL_APP_FAILURE;
        };

        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlAppIter(ud: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
        const w: *Wrapper = @ptrCast(@alignCast(ud));
        w.app.?.tick() catch |e| {
            w.err = e;
            logger.err("Error while ticking: {t}", .{e});
            return sdl.SDL_APP_FAILURE;
        };
        return sdl.SDL_APP_CONTINUE;
    }

    fn sdlAppEvent(ud: ?*anyopaque, ev: [*c]sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
        const w: *Wrapper = @ptrCast(@alignCast(ud));
        const res = w.app.?.onEvent(@ptrCast(ev)) catch |e| {
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

pub fn main(init: process.Init) !u8 {
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
        const msg = std.mem.span(err);
        if (msg.len == 0) break :may_err;
        for (msg) |c| {
            if (c != ' ' and c != '\n' and c != '\r' and c != '\t') break;
        } else break :may_err;
        logger.err("SDL Error: {s}", .{msg});
    }

    return w.err orelse @truncate(@as(c_uint, @bitCast(res)));
}
