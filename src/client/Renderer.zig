const Renderer = @This();
const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const vk = @import("vulkan");
const sdl = @import("sdl");
const config = @import("config");
const math = @import("math");
const Device = @import("graphics/Device.zig");
const Swapchain = @import("graphics/Swapchain.zig");

const logger = std.log.scoped(.@"bare_blocks/Renderer");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const process = std.process;
const assert = std.debug.assert;

const is_debug = builtin.mode == .Debug;

const debug_required_extensions: []const [*:0]const u8 = &.{
    vk.extensions.ext_debug_utils.name.ptr,
};
const debug_required_layers: []const [*:0]const u8 = &.{
    "VK_LAYER_KHRONOS_validation",
};

const DebugUtilsDataFormatter = struct {
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

fn FormattedFlags(comptime FlagsType: type) type {
    return struct {
        f: FlagsType,

        pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
            const info = @typeInfo(FlagsType).@"struct";
            const BackInt = info.backing_integer.?;
            const max_back = std.math.maxInt(BackInt);
            const bits: BackInt = @bitCast(self.f);
            try writer.writeAll("{ ");
            inline for (info.fields) |f| {
                const offset = @bitOffsetOf(FlagsType, f.name);
                const rem_mask = (max_back << (offset + 1)) & max_back;
                const can_have_next = (offset + 1) < @bitSizeOf(BackInt);
                if (@field(self.f, f.name)) {
                    try writer.writeAll(f.name);
                    if (can_have_next and bits & rem_mask != 0 and (bits >> (offset + 1)) & 1 != 0) try writer.writeAll(" | ");
                }
            }
            if (bits != 0) try writer.writeByte(' ');
            try writer.writeByte('}');
        }
    };
}

const MemoryFormatter = struct {
    props: vk.PhysicalDeviceMemoryProperties,

    pub fn format(self: MemoryFormatter, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("   - Types: {d}\n", .{self.props.memory_type_count});
        for (self.props.memory_types[0..self.props.memory_type_count]) |_type| {
            try writer.print("     - Index: {d}, flags: {f}\n", .{
                _type.heap_index, FormattedFlags(vk.MemoryPropertyFlags){ .f = _type.property_flags },
            });
        }
        try writer.print("   - Heaps: {d}\n", .{self.props.memory_heap_count});
        for (self.props.memory_heaps[0..self.props.memory_heap_count], 0..) |heap, i| {
            try writer.print("     - Size: {Bi}, flags: {f}", .{
                heap.size, FormattedFlags(vk.MemoryHeapFlags){ .f = heap.flags },
            });
            if (i < self.props.memory_heap_count - 1) try writer.writeByte('\n');
        }
    }
};

const PhysicalDevice = struct {
    fn init(self: *PhysicalDevice, handle: vk.PhysicalDevice) void {
        self.handle = handle;
        self.props.s_type = .physical_device_properties_2;
        self.props.p_next = &self.props11;
        self.props11.s_type = .physical_device_vulkan_1_1_properties;
        self.props11.p_next = &self.props12;
        self.props12.s_type = .physical_device_vulkan_1_2_properties;
        self.props12.p_next = &self.props13;
        self.props13.s_type = .physical_device_vulkan_1_3_properties;
        self.props13.p_next = &self.dprops;
        self.dprops.s_type = .physical_device_driver_properties;
        self.dprops.p_next = null;

        self.mprops.s_type = .physical_device_memory_properties_2;
        self.mprops.p_next = null;
    }

    handle: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties2,
    props11: vk.PhysicalDeviceVulkan11Properties,
    props12: vk.PhysicalDeviceVulkan12Properties,
    props13: vk.PhysicalDeviceVulkan13Properties,
    maint3: vk.PhysicalDeviceMaintenance3Properties,
    dprops: vk.PhysicalDeviceDriverProperties,
    mprops: vk.PhysicalDeviceMemoryProperties2,
};

fn debugUtilsCallback(message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, message_types: vk.DebugUtilsMessageTypeFlagsEXT, p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, p_user_data: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = p_user_data;
    if (p_callback_data == null) return .false;

    const vklog = std.log.scoped(.vk_debug_utils);

    const args = .{
        FormattedFlags(vk.DebugUtilsMessageTypeFlagsEXT){ .f = message_types },
        FormattedFlags(vk.DebugUtilsMessageSeverityFlagsEXT){ .f = message_severity },
        DebugUtilsDataFormatter{ .callback_data = p_callback_data.? },
    };

    if (message_severity.error_bit_ext) {
        vklog.err("[{f}, {f}] {f}", args);
    } else if (message_severity.warning_bit_ext) {
        vklog.warn("[{f}, {f}] {f}", args);
    } else if (message_severity.info_bit_ext) {
        vklog.info("[{f}, {f}] {f}", args);
    } else {
        vklog.debug("[{f}, {f}] {f}", args);
    }

    return .false;
}

fn checkExtensions(self: *Renderer, gpa: Allocator, required: []const [*:0]const u8) !bool {
    if (required.len == 0) return true;

    var bitset = try std.DynamicBitSetUnmanaged.initEmpty(gpa, required.len);
    defer bitset.deinit(gpa);

    for (self.extensions_properties) |*ext| {
        const name = std.mem.sliceTo(&ext.extension_name, 0);
        logger.debug("Extensions found: {s}", .{name});
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

fn checkLayers(self: *Renderer, gpa: Allocator, required: []const [*:0]const u8) !bool {
    if (required.len == 0) return true;

    var bitset = try std.DynamicBitSetUnmanaged.initEmpty(gpa, required.len);
    defer bitset.deinit(gpa);

    for (self.layers_properties) |*lay| {
        const name = std.mem.sliceTo(&lay.layer_name, 0);
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

fn createInstance(self: *Renderer, gpa: Allocator, arena: Allocator, sdl_vk_exts: []const [*:0]const u8) !void {
    const max_version = try self.vkb.enumerateInstanceVersion();
    if (max_version.variant != 0 or max_version.major != 1 or max_version.minor < 3) {
        logger.err("Vulkan drivers outdated, please use/install vulkan 0.1.3.0" ++
            "(it came out in 2022 bro, come on). Got {d}.{d}.{d}.{d}", .{
            max_version.variant, max_version.major,
            max_version.minor,   max_version.patch,
        });
        return error.VulkanVersion;
    }

    const all_required_extensions = try std.mem.concat(
        gpa,
        [*:0]const u8,
        &.{
            sdl_vk_exts,
            if (is_debug) debug_required_extensions else &.{},
        },
    );
    defer gpa.free(all_required_extensions);

    const all_required_layers: []const [*:0]const u8 = if (is_debug) debug_required_layers else &.{};

    self.extensions_properties = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, arena);
    self.layers_properties = try self.vkb.enumerateInstanceLayerPropertiesAlloc(arena);

    if (!try self.checkExtensions(gpa, all_required_extensions)) {
        return error.ExtensionNotFound;
    }
    if (!try self.checkLayers(gpa, all_required_layers)) {
        return error.LayerNotFound;
    }

    const vk_version = vk.Version.of(
        0,
        config.version.major,
        config.version.minor,
        config.version.patch,
    );

    const InfoType = if (is_debug) vk.DebugUtilsMessengerCreateInfoEXT else void;
    var msg_cinfo: InfoType = undefined;
    var app_info = vk.ApplicationInfo{
        .p_application_name = "Bare Blocks",
        .application_version = vk_version,
        .p_engine_name = "Bare Blocks",
        .engine_version = vk_version,
        .api_version = vk.API_VERSION_1_3,
    };
    var inst_cinfo = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(all_required_layers.len),
        .pp_enabled_layer_names = all_required_layers.ptr,
        .enabled_extension_count = @intCast(all_required_extensions.len),
        .pp_enabled_extension_names = all_required_extensions.ptr,
    };
    if (is_debug) {
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

    self.instance = try self.vkb.createInstance(&inst_cinfo, self.alloc_cb);
    self.vki.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    errdefer self.vki.destroyInstance(self.instance, self.alloc_cb);

    if (is_debug) {
        self.debug_messenger = try self.vki.createDebugUtilsMessengerEXT(self.instance, &msg_cinfo, self.alloc_cb);
    }
    errdefer if (is_debug) self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, self.alloc_cb);
}

fn destroyInstance(self: *Renderer) void {
    if (is_debug) self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, self.alloc_cb);
    self.vki.destroyInstance(self.instance, self.alloc_cb);
}

alloc_cb: ?*const vk.AllocationCallbacks,
vkb: vk.BaseWrapper,
vki: vk.InstanceWrapper,

instance: vk.Instance,
debug_messenger: if (is_debug) vk.DebugUtilsMessengerEXT else void,
extensions_properties: []const vk.ExtensionProperties,
layers_properties: []const vk.LayerProperties,

physical_devices: []PhysicalDevice,

pub const InitOptions = struct {
    gpa: Allocator,
    arena: Allocator,
    vk_loader: vk.PfnGetInstanceProcAddr,
    sdl_vk_exts: []const [*:0]const u8,
    alloc_cb: ?*const vk.AllocationCallbacks = null,
};

pub fn init(self: *Renderer, opt: InitOptions) !void {
    self.alloc_cb = opt.alloc_cb;

    self.vkb.load(opt.vk_loader);

    try self.createInstance(opt.gpa, opt.arena, opt.sdl_vk_exts);
    errdefer self.destroyInstance();

    {
        const pdevs = try self.vki.enumeratePhysicalDevicesAlloc(self.instance, opt.gpa);
        defer opt.gpa.free(pdevs);

        self.physical_devices = try opt.gpa.alloc(PhysicalDevice, pdevs.len);
        errdefer comptime unreachable;

        for (pdevs, self.physical_devices, 0..) |pdev, *out, i| {
            out.init(pdev);
            self.vki.getPhysicalDeviceProperties2(pdev, &out.props);
            self.vki.getPhysicalDeviceMemoryProperties2(pdev, &out.mprops);

            logger.info(
                \\GPU#{d} "{s}":
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
                \\ - Memory:
                \\{f}
            , .{
                i,                                                        std.mem.sliceTo(&out.props.properties.device_name, 0),

                out.props.properties.api_version.variant,                 out.props.properties.api_version.major,
                out.props.properties.api_version.minor,                   out.props.properties.api_version.patch,

                out.props.properties.driver_version.variant,              out.props.properties.driver_version.major,
                out.props.properties.driver_version.minor,                out.props.properties.driver_version.patch,

                out.props.properties.device_type,                         out.props.properties.vendor_id,
                out.props.properties.device_id,                           utils.UUID.fromBytes(&out.props.properties.pipeline_cache_uuid, .little),

                out.dprops.driver_id,                                     std.mem.sliceTo(&out.dprops.driver_name, 0),
                std.mem.sliceTo(&out.dprops.driver_info, 0),              "",

                out.dprops.conformance_version.major,                     out.dprops.conformance_version.minor,
                out.dprops.conformance_version.subminor,                  out.dprops.conformance_version.patch,

                MemoryFormatter{ .props = out.mprops.memory_properties },
            });
        }
    }
    errdefer opt.gpa.free(self.physical_devices);
}

pub fn deinit(self: *Renderer, gpa: Allocator) void {
    gpa.free(self.physical_devices);
}

test {
    std.testing.refAllDecls(@This());
}
