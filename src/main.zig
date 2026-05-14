const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const utils = @import("utils");
const vk = @import("vulkan");
const sdl = @import("sdl");
const config = @import("config");
const Device = @import("graphics/Device.zig");
const Swapchain = @import("graphics/Swapchain.zig");

const logger = core.logger;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const assert = std.debug.assert;

const default_shader_code align(4) = @embedFile("default_shader_code").*;

const debug_required_extensions: []const [*:0]const u8 = &.{
    vk.extensions.ext_debug_utils.name.ptr,
};
const debug_required_layers: []const [*:0]const u8 = &.{
    "VK_LAYER_KHRONOS_validation",
};

const vulkan_11_features = vk.PhysicalDeviceVulkan11Features{
    .p_next = @constCast(&vulkan_13_features),
    .shader_draw_parameters = true,
};
const vulkan_13_features = vk.PhysicalDeviceVulkan13Features{
    .p_next = @constCast(&extended_dynamic_state_features),
    .dynamic_rendering = true,
};
const extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
    .extended_dynamic_state = true,
};
const create_device_chain = vk.PhysicalDeviceFeatures2{
    .p_next = @constCast(&vulkan_11_features),
    .features = .{
        .logic_op = true,
    },
};

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
    const queue_priorities = blk: {
        var values: [fields.len]f32 = undefined;
        @memset(&values, 0);
        break :blk values;
    };

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
                (try app.vki.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), app.surface)))
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

const cache_file_path: []const []const u8 = &.{ "bare_blocks", "pipeline_cache.dat" };
const cache_file_path_len: usize = blk: {
    var len: usize = 0;
    for (cache_file_path) |str| {
        len += str.len + 1;
    }
    break :blk len;
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

    fn doxGpuInfo(self: *App) void {
        var driver_props: vk.PhysicalDeviceDriverProperties = .{
            .driver_id = undefined,
            .driver_name = undefined,
            .driver_info = undefined,
            .conformance_version = undefined,
        };
        var props2: vk.PhysicalDeviceProperties2 = .{
            .p_next = &driver_props,
            .properties = undefined,
        };
        self.vki.getPhysicalDeviceProperties2(self.device.pdev, &props2);
        const props = &props2.properties;
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
            \\ - driver id: {t}
            \\ - driver name: {s}
            \\ - driver info: {s}{s}
            \\ - driver conformance version: {d}.{d}.{d}.{d}
        , .{
            self.chosen_pdev,                            stringFromBuffer(&props.device_name),

            apiver.variant,                              apiver.major,
            apiver.minor,                                apiver.patch,

            dver.variant,                                dver.major,
            dver.minor,                                  dver.patch,

            props.device_type,                           props.vendor_id,
            props.device_id,                             utils.UUID.from(@bitCast(props.pipeline_cache_uuid)),

            driver_props.driver_id,                      stringFromBuffer(&driver_props.driver_name),
            stringFromBuffer(&driver_props.driver_info), "",

            driver_props.conformance_version.major,      driver_props.conformance_version.minor,
            driver_props.conformance_version.subminor,   driver_props.conformance_version.patch,
        });
    }

    fn createInstance(
        self: *App,
        vk_loader: vk.PfnGetInstanceProcAddr,
        sdl_vk_exts: []const [*:0]const u8,
    ) !void {
        const max_version: vk.Version = @bitCast(try self.vkb.enumerateInstanceVersion());
        if (max_version.variant != 0 or max_version.major != 1 or max_version.minor < 3) {
            logger.err("Vulkan drivers outdated, please use/install vulkan 0.1.3.0" ++
                "(it came out in 2022 bro, come on). Got {d}.{d}.{d}.{d}", .{
                max_version.variant, max_version.major,
                max_version.minor,   max_version.patch,
            });
            return error.Vulkan;
        }

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
                .api_version = vk.API_VERSION_1_3.toU32(),
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
        self.vki.load(self.instance, vk_loader);
        errdefer self.vki.destroyInstance(self.instance, null);

        if (builtin.mode == .Debug) {
            self.debug_messenger = try self.vki.createDebugUtilsMessengerEXT(self.instance, &msg_cinfo, null);
        }
        errdefer if (builtin.mode == .Debug) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        };
    }

    fn getCacheFilePath(self: *App) ![]const u8 {
        if (self.cache_file_path) |path| return path;

        const path = sw: switch (builtin.os.tag) {
            .linux => {
                const home_dir = self.envmap.get("HOME") orelse @panic("Why don't you have your HOME set ._.");
                break :sw try std.fs.path.join(self.gpa, (&[_][]const u8{ home_dir, ".cache" }) ++ cache_file_path);
            },
            .windows => {
                const lad = self.envmap.get("LOCALAPPDATA") orelse @panic("Uh oh");
                break :sw try std.fs.path.join(self.gpa, (&[_][]const u8{lad}) ++ cache_file_path);
            },
            else => @compileError("OS Not Supported"),
        };
        self.cache_file_path = path;
        return path;
    }

    fn fetchPipelineCacheData(self: *App) ![]u8 {
        const cache_path = try self.getCacheFilePath();

        const cache_file = try std.Io.Dir.openFileAbsolute(self.io, cache_path, .{
            .lock = .exclusive,
        });
        defer cache_file.close(self.io);

        var reader = cache_file.reader(self.io, &.{});
        const len = try cache_file.length(self.io);

        const buf = try reader.interface.readAlloc(self.gpa, len);
        logger.info("Loaded {Bi} of pipeline cache data", .{buf.len});
        return buf;
    }

    fn savePipelineCache(self: *App) !void {
        const file_path = self.cache_file_path.?;
        const global_cache_dir = try std.Io.Dir.openDirAbsolute(
            self.io,
            file_path[0 .. file_path.len - cache_file_path_len],
            .{},
        );
        defer global_cache_dir.close(self.io);

        try global_cache_dir.createDirPath(self.io, file_path[0 .. file_path.len - cache_file_path[cache_file_path.len - 1].len]);

        const cache_file = try std.Io.Dir.createFileAbsolute(self.io, self.cache_file_path.?, .{
            .lock = .exclusive,
        });

        const data = try self.device.getPipelineCacheData(self.gpa, self.pipeline_cache);
        defer self.gpa.free(data);

        try cache_file.writePositionalAll(self.io, data, 0);

        logger.info("Saved {Bi} of pipeline cache data", .{data.len});
    }

    fn hsv2rgb(h: f32, s: f32, v: f32) [3]f32 {
        const i = @floor(h * 6);
        const f = h * 6 - i;
        const p = v * (1 - s);
        const q = v * (1 - f * s);
        const t = v * (1 - (1 - f) * s);
        return switch (@as(u8, @intFromFloat(@mod(i, 6)))) {
            0 => .{ v, t, p },
            1 => .{ q, v, p },
            2 => .{ p, v, t },
            3 => .{ p, q, v },
            4 => .{ t, p, v },
            5 => .{ v, p, q },
            else => unreachable,
        };
    }

    fn render(self: *App, cmd: vk.CommandBufferProxy) !void {
        cmd.bindPipeline(.graphics, self.pipeline);
        const millis = @as(i64, @intCast(@divTrunc(self.start_time.untilNow(self.io, .boot).nanoseconds, std.time.ns_per_ms)));
        const seconds = @as(f64, @floatFromInt(millis)) / std.time.ms_per_s;
        const values: [3][4]f32 = .{
            hsv2rgb(@floatCast(@sin(seconds * std.math.rad_per_deg * 10)), 1, 1) ++ .{0},
            hsv2rgb(@floatCast(@sin((seconds + 40) * std.math.rad_per_deg * 10)), 1, 1) ++ .{0},
            hsv2rgb(@floatCast(@sin((seconds + 80) * std.math.rad_per_deg * 10)), 1, 1) ++ .{0},
        };
        cmd.pushConstants(
            self.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(@TypeOf(values)),
            &values,
        );
        cmd.draw(3, 1, 0, 0);
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
    device: Device,
    swapchain: Swapchain,

    do_rendering: bool = false,

    cache_file_path: ?[]const u8,
    pipeline_cache: vk.PipelineCache,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,

    start_time: Io.Timestamp,

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
        self.cache_file_path = null;
        self.do_rendering = false;

        self.window = sdl.SDL_CreateWindow(
            "Bare Blocks | IN-DEV",
            800,
            600,
            sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_HIDDEN |
                sdl.SDL_WINDOW_RESIZABLE,
        ) orelse {
            logger.err("Failed to create window", .{});
            return error.SDL;
        };
        errdefer sdl.SDL_DestroyWindow(self.window);

        self.vkb.load(vk_loader);

        try self.createInstance(vk_loader, sdl_vk_exts);
        errdefer {
            self.gpa.free(self.extensions_properties);
            self.gpa.free(self.layers_properties);
            if (builtin.mode == .Debug) {
                self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
            }
            self.vki.destroyInstance(self.instance, null);
        }
        const instp = vk.InstanceProxy.init(self.instance, &self.vki);

        try self.swapchain.createSurface(self.instance, self.window);
        errdefer instp.destroySurfaceKHR(self.swapchain.surface, null);

        { // Allocating physical devices array, for future dynamic device switching
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

        try self.device.init(.{
            .gpa = self.gpa,
            .instance = instp,
            .wrapper = &self.vkd,
            .physical_devices = self.phys_devs,
            .surface = self.swapchain.surface,

            .pdev_index_out = &self.chosen_pdev,
        });
        errdefer self.device.deinit();

        self.doxGpuInfo();

        try self.swapchain.init(.{
            .gpa = self.gpa,
            .window = self.window,
            .instance = instp,
            .device = &self.device,
        });
        errdefer self.swapchain.deinit(self.gpa, instp);

        const ppc_data: ?[]const u8 = self.fetchPipelineCacheData() catch |e| err: {
            logger.warn("Couldn't get pipeline cache data: {t}", .{e});
            break :err null;
        };
        errdefer if (self.cache_file_path) |path| self.gpa.free(path);
        defer if (ppc_data) |data| self.gpa.free(data);

        self.pipeline_cache = try self.device.createPipelineCache(ppc_data);
        errdefer self.device.destroyPipelineCache(self.pipeline_cache);

        { // Graphics Pipeline
            const vertex_module = try self.device.createShader(@ptrCast(&default_shader_code));
            defer self.device.destroyShader(vertex_module);
            const fragment_module = try self.device.createShader(@ptrCast(&default_shader_code));
            defer self.device.destroyShader(fragment_module);

            self.pipeline_layout = try self.device.createPipelineLayout(Device.PipelineLayoutCreateInfo{
                .push_constant_ranges = &.{
                    vk.PushConstantRange{
                        .offset = 0,
                        .size = @sizeOf(f32) * 4 * 3,
                        .stage_flags = .{ .vertex_bit = true },
                    },
                },
            });
            errdefer self.device.destroyPipelineLayout(self.pipeline_layout);

            const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };

            self.pipeline = try self.device.createGraphicsPipeline(Device.GraphicsPipelineCreateInfo{
                .cache = self.pipeline_cache,

                .p_next = &vk.PipelineRenderingCreateInfo{
                    .view_mask = 0,
                    .color_attachment_count = 1,
                    .p_color_attachment_formats = @ptrCast(&self.swapchain.surface_format.format),
                    .depth_attachment_format = .undefined,
                    .stencil_attachment_format = .undefined,
                },
                .stages = &.{
                    .{
                        .stage = .{ .vertex_bit = true },
                        .module = vertex_module,
                        .p_name = "vertexMain",
                    },
                    .{
                        .stage = .{ .fragment_bit = true },
                        .module = fragment_module,
                        .p_name = "fragmentMain",
                    },
                },
                .vertex_input_state = .{},
                .input_assembly_state = .{
                    .topology = .triangle_list,
                    .primitive_restart_enable = .false,
                },
                .viewport_state = .{
                    .viewport_count = 1,
                    .scissor_count = 1,
                },
                .rasterization_state = .{
                    .depth_clamp_enable = .false,
                    .rasterizer_discard_enable = .false,
                    .polygon_mode = .fill,
                    .cull_mode = .{ .back_bit = false },
                    .front_face = .counter_clockwise,
                    .depth_bias_enable = .false,
                    .depth_bias_constant_factor = 0,
                    .depth_bias_clamp = 0,
                    .depth_bias_slope_factor = 0,
                    .line_width = 1,
                },
                .multisample_state = .{
                    .rasterization_samples = .{ .@"1_bit" = true },
                    .sample_shading_enable = .false,
                    .min_sample_shading = 0,
                    .alpha_to_coverage_enable = .false,
                    .alpha_to_one_enable = .false,
                },
                .depth_stencil_state = .{
                    .depth_test_enable = .false,
                    .depth_write_enable = .false,
                    .depth_compare_op = .less,
                    .depth_bounds_test_enable = .false,
                    .stencil_test_enable = .false,
                    .front = undefined,
                    .back = undefined,
                    .min_depth_bounds = 0,
                    .max_depth_bounds = 0,
                },
                .color_blend_state = .{
                    .logic_op_enable = .true,
                    .logic_op = .copy,
                    .attachment_count = 1,
                    .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{.{
                        .blend_enable = .true,
                        .src_color_blend_factor = .src_alpha,
                        .dst_color_blend_factor = .one_minus_src_alpha,
                        .color_blend_op = .add,
                        .src_alpha_blend_factor = .one,
                        .dst_alpha_blend_factor = .zero,
                        .alpha_blend_op = .add,
                        .color_write_mask = .{
                            .r_bit = true,
                            .g_bit = true,
                            .b_bit = true,
                            .a_bit = true,
                        },
                    }},
                    .blend_constants = .{ 0, 0, 0, 0 },
                },
                .dynamic_state = .{
                    .dynamic_state_count = dynamic_states.len,
                    .p_dynamic_states = &dynamic_states,
                },
                .layout = self.pipeline_layout,
            });
        } // Graphics Pipeline
        errdefer self.device.destroyPipeline(self.pipeline);

        _ = sdl.SDL_ShowWindow(self.window);
        self.start_time = .now(self.io, .boot);
        return self;
    }

    pub fn destroy(self: *App) void {
        const instp = vk.InstanceProxy.init(self.instance, &self.vki);

        self.device.queueWaitIdle(.graphics) catch |e| logger.warn("Error while waiting for graphics queue: {t}", .{e});
        self.device.queueWaitIdle(.present) catch |e| logger.warn("Error while waiting for present queue: {t}", .{e});
        self.device.destroyPipeline(self.pipeline);
        self.device.destroyPipelineLayout(self.pipeline_layout);
        self.savePipelineCache() catch |e| {
            logger.err("Failed to save pipeline cache: {t}", .{e});
        };
        self.device.destroyPipelineCache(self.pipeline_cache);
        self.swapchain.deinit(self.gpa, instp);
        self.device.deinit();
        if (builtin.mode == .Debug) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        }
        instp.destroyInstance(null);
        sdl.SDL_DestroyWindow(self.window);

        if (self.cache_file_path) |path| self.gpa.free(path);
        self.gpa.free(self.phys_devs);
        self.gpa.free(self.layers_properties);
        self.gpa.free(self.extensions_properties);
        self.gpa.destroy(self);
    }

    pub fn tick(self: *App) !void {
        if (self.do_rendering) {
            const cmd = try self.swapchain.beginDraw();
            self.render(cmd) catch |e| {
                logger.err("Rendering error: {t}", .{e});
            };
            try self.swapchain.endDraw();
        }
    }

    pub fn onEvent(self: *App, ev: *sdl.SDL_Event) !enum { @"continue", success } {
        const windowID = sdl.SDL_GetWindowID(self.window);
        switch (ev.type) {
            sdl.SDL_EVENT_QUIT => return .success,
            sdl.SDL_EVENT_WINDOW_RESIZED, sdl.SDL_EVENT_WINDOW_DISPLAY_CHANGED => if (ev.window.windowID == windowID) {
                try self.device.queueWaitIdle(.graphics);
                try self.device.queueWaitIdle(.present);
                try self.swapchain.recreate(
                    self.gpa,
                    .init(self.instance, &self.vki),
                    self.window,
                    self.device.pdev,
                );
            },

            sdl.SDL_EVENT_WINDOW_MINIMIZED, sdl.SDL_EVENT_WINDOW_HIDDEN => if (ev.window.windowID == windowID) {
                self.do_rendering = false;
            },
            sdl.SDL_EVENT_WINDOW_RESTORED, sdl.SDL_EVENT_WINDOW_MAXIMIZED, sdl.SDL_EVENT_WINDOW_SHOWN => if (ev.window.windowID == windowID) {
                self.do_rendering = true;
            },
            sdl.SDL_EVENT_KEY_DOWN => {
                if (ev.key.scancode == sdl.SDL_SCANCODE_F1) {
                    const old_pipeline = self.pipeline_cache;
                    self.pipeline_cache = try self.device.proxy.createPipelineCache(&.{}, null);
                    self.device.proxy.destroyPipelineCache(old_pipeline, null);
                    logger.info("Cleared pipeline cache!", .{});
                }
            },
            else => {},
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
