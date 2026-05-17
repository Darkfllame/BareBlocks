const Device = @This();
const std = @import("std");
const vk = @import("vulkan");
const MemoryManager = @import("MemoryManager.zig");

const assert = std.debug.assert;

const logger = std.log.scoped(.@"graphics/Device");

const Allocator = std.mem.Allocator;

const vulkan_11_features = vk.PhysicalDeviceVulkan11Features{
    .p_next = @constCast(&vulkan_13_features),
    .shader_draw_parameters = .true,
};
const vulkan_13_features = vk.PhysicalDeviceVulkan13Features{
    .p_next = @constCast(&extended_dynamic_state_features),
    .dynamic_rendering = .true,
    .synchronization_2 = .true,
};
const extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
    .extended_dynamic_state = .true,
};
const create_device_chain = vk.PhysicalDeviceFeatures2{
    .p_next = @constCast(&vulkan_11_features),
    .features = .{
        .logic_op = .true,
    },
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
    const TagInt = std.math.Log2Int(@Int(.unsigned, fields.len));
    const FieldsEnum = blk: {
        var names: [fields.len][]const u8 = undefined;
        var values: [fields.len]TagInt = undefined;
        for (fields, 0..) |f, i| {
            names[i] = f.name;
            values[i] = i;
        }

        break :blk @Enum(TagInt, .nonexhaustive, &names, &values);
    };

    fn init(
        self: *QueueFamilyIndices,
        instance: vk.InstanceProxy,
        surface: vk.SurfaceKHR,
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
                (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), surface)) == .true)
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

fn chosePhysicalDevice(instance: vk.InstanceProxy, phys_devs: []const vk.PhysicalDevice) ?u8 {
    const hasFeatures = struct {
        fn hasFeatures(comptime T: type, check: *const T, ptr: *const T) bool {
            const fields = @typeInfo(T).@"struct".fields;
            const feats_count = (@sizeOf(T) - @sizeOf(vk.BaseOutStructure)) / 4;

            const feats_ptr: *const T = @ptrCast(ptr);

            const feats_bools: [*]const vk.Bool32 = @ptrCast(&@field(feats_ptr, fields[2].name));
            const check_bools: [*]const vk.Bool32 = @ptrCast(&@field(check, fields[2].name));

            for (0..feats_count) |i| {
                if (check_bools[i] == .true and feats_bools[i] == .false) {
                    return false;
                }
            }
            return true;
        }
    }.hasFeatures;

    var highest_rating: u32 = 0;
    var best_index: ?u8 = null;
    var edsfeats: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT = .{ .p_next = null };
    var vk13feats: vk.PhysicalDeviceVulkan13Features = .{ .p_next = &edsfeats };
    var vk11feats: vk.PhysicalDeviceVulkan11Features = .{ .p_next = &vk13feats };
    var feats: vk.PhysicalDeviceFeatures2 = .{
        .p_next = &vk11feats,
        .features = .{},
    };
    for (phys_devs, 0..) |pdev, i| {
        var rating: u32 = 0;
        instance.getPhysicalDeviceFeatures2(pdev, &feats);
        const props = instance.getPhysicalDeviceProperties(pdev);

        rating += switch (props.device_type) {
            // I guess this should be fine for now...
            .discrete_gpu => 3,
            .virtual_gpu => 2,
            .integrated_gpu => 1,
            else => 0,
        };

        if (!hasFeatures(vk.PhysicalDeviceFeatures2, &create_device_chain, &feats)) continue;
        if (!hasFeatures(vk.PhysicalDeviceVulkan11Features, &vulkan_11_features, &vk11feats)) continue;
        if (!hasFeatures(vk.PhysicalDeviceVulkan13Features, &vulkan_13_features, &vk13feats)) continue;
        if (!hasFeatures(vk.PhysicalDeviceVulkan13Features, &vulkan_13_features, &vk13feats)) continue;
        if (!hasFeatures(vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT, &extended_dynamic_state_features, &edsfeats)) continue;

        if (highest_rating < rating) {
            highest_rating = rating;
            best_index = @intCast(i);
        }
    }

    return best_index;
}

fn createLogicalDevice(self: *Device, gpa: Allocator, wrapper: *vk.DeviceWrapper, surface: vk.SurfaceKHR) !void {
    const qfps = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, gpa);
    defer gpa.free(qfps);

    var queue_indices: QueueFamilyIndices = undefined;

    self.queue_family_indices.init(self.instance, surface, self.pdev, qfps) catch |e| {
        logger.err("Couldn't get all queue family indices", .{});
        return e;
    };

    var qci_buffer: [QueueFamilyIndices.fields.len]vk.DeviceQueueCreateInfo = undefined;
    const q_create_infos = self.queue_family_indices.calculateQueuCreateInfos(&queue_indices, &qci_buffer);
    for (q_create_infos, 0..) |info, i| {
        self.concurrent_queues[i] = info.queue_family_index;
    }
    self.concurrent_queues_count = @intCast(q_create_infos.len);

    const extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name.ptr,
        vk.extensions.khr_dynamic_rendering.name.ptr,
        vk.extensions.khr_maintenance_1.name.ptr,
    };

    const device = try self.instance.createDevice(self.pdev, &vk.DeviceCreateInfo{
        .p_next = &create_device_chain,
        .queue_create_info_count = @intCast(q_create_infos.len),
        .p_queue_create_infos = q_create_infos.ptr,
        .enabled_extension_count = extensions.len,
        .pp_enabled_extension_names = &extensions,
    }, null);
    wrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    errdefer wrapper.destroyDevice(device, null);

    self.proxy = .init(device, wrapper);

    inline for (QueueFamilyIndices.fields) |f| {
        @field(self.queues, f.name) = self.proxy.getDeviceQueue(
            @field(self.queue_family_indices, f.name),
            @field(queue_indices, f.name),
        );
    }
}

instance: vk.InstanceProxy,
pdev: vk.PhysicalDevice,
proxy: vk.DeviceProxy,
queue_family_indices: QueueFamilyIndices,
queues: QueueFamilyIndices.Queues,
concurrent_queues_count: QueueFamilyIndices.TagInt,
concurrent_queues: [QueueFamilyIndices.fields.len]u32,
command_pool: vk.CommandPool,
mman: MemoryManager,

pub const PipelineLayoutCreateInfo = struct {
    flags: vk.PipelineLayoutCreateFlags = .{},
    set_layouts: []const vk.DescriptorSetLayout = &.{},
    push_constant_ranges: []const vk.PushConstantRange = &.{},
};
pub const GraphicsPipelineCreateInfo = struct {
    p_next: ?*const anyopaque = null,
    cache: vk.PipelineCache = .null_handle,
    flags: vk.PipelineCreateFlags = .{},
    stages: []const vk.PipelineShaderStageCreateInfo,
    vertex_input_state: ?vk.PipelineVertexInputStateCreateInfo = null,
    input_assembly_state: ?vk.PipelineInputAssemblyStateCreateInfo = null,
    tessellation_state: ?vk.PipelineTessellationStateCreateInfo = null,
    viewport_state: ?vk.PipelineViewportStateCreateInfo = null,
    rasterization_state: ?vk.PipelineRasterizationStateCreateInfo = null,
    multisample_state: ?vk.PipelineMultisampleStateCreateInfo = null,
    depth_stencil_state: ?vk.PipelineDepthStencilStateCreateInfo = null,
    color_blend_state: ?vk.PipelineColorBlendStateCreateInfo = null,
    dynamic_state: ?vk.PipelineDynamicStateCreateInfo = null,
    /// Interface layout of the pipeline
    layout: vk.PipelineLayout = .null_handle,
    /// If VK_PIPELINE_CREATE_DERIVATIVE_BIT is set and this value is nonzero, it specifies the handle
    /// of the base pipeline this is a derivative of
    base_pipeline_handle: vk.Pipeline = .null_handle,
    /// If VK_PIPELINE_CREATE_DERIVATIVE_BIT is set and this value is not -1, it specifies an index into
    /// CreateInfos of the base pipeline this is a derivative of
    base_pipeline_index: i32 = 0,
};
pub const InitInfo = struct {
    gpa: Allocator,
    instance: vk.InstanceProxy,
    wrapper: *vk.DeviceWrapper,
    physical_devices: []const vk.PhysicalDevice,
    surface: vk.SurfaceKHR,

    pdev_index_out: ?*u8 = null,
};
pub const Buffer = MemoryManager.Buffer;

pub fn init(self: *Device, info: InitInfo) !void {
    const pdev_index = chosePhysicalDevice(info.instance, info.physical_devices) orelse {
        logger.err("Couldn't choose physical device", .{});
        return error.Vulkan;
    };
    self.instance = info.instance;
    self.pdev = info.physical_devices[pdev_index];
    // initializes .device and .queues
    try self.createLogicalDevice(info.gpa, info.wrapper, info.surface);
    errdefer self.proxy.destroyDevice(null);

    self.command_pool = try self.proxy.createCommandPool(&vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = self.queue_family_indices.graphics,
    }, null);
    errdefer self.proxy.destroyCommandPool(self.command_pool, null);

    try self.mman.init(.{
        .gpa = info.gpa,
        .instance = info.instance,
        .device = self,
        .pdev = self.pdev,
    });
    errdefer self.mman.deinit(info.gpa);

    if (info.pdev_index_out) |pdo| {
        pdo.* = pdev_index;
    }
}

pub fn deinit(self: *Device) void {
    self.mman.deinit();
    self.proxy.destroyCommandPool(self.command_pool, null);
    self.proxy.destroyDevice(null);
}

pub fn getQueue(self: *const Device, comptime queue_name: QueueFamilyIndices.FieldsEnum) vk.QueueProxy {
    return .init(@field(self.queues, @tagName(queue_name)), self.proxy.wrapper);
}

pub fn queueWaitIdle(self: *const Device, comptime queue_name: QueueFamilyIndices.FieldsEnum) !void {
    return self.getQueue(queue_name).waitIdle();
}

pub inline fn createShader(self: *Device, code: []const u32) !vk.ShaderModule {
    return self.proxy.createShaderModule(&vk.ShaderModuleCreateInfo{
        .code_size = code.len * 4,
        .p_code = code.ptr,
    }, null);
}

pub inline fn destroyShader(self: *Device, sh: vk.ShaderModule) void {
    assert(sh != .null_handle);
    return self.proxy.destroyShaderModule(sh, null);
}

pub inline fn createPipelineCache(self: *Device, data: ?[]const u8) !vk.PipelineCache {
    return self.proxy.createPipelineCache(&vk.PipelineCacheCreateInfo{
        .initial_data_size = if (data) |d| d.len else 0,
        .p_initial_data = if (data) |d| d.ptr else null,
    }, null);
}

pub inline fn getPipelineCacheData(self: *Device, gpa: Allocator, ppc: vk.PipelineCache) ![]u8 {
    return self.proxy.getPipelineCacheDataAlloc(ppc, gpa);
}

pub inline fn mergePipelineCaches(self: *Device, dest_ppc: vk.PipelineCache, srcs: []const vk.PipelineCache) !void {
    return self.proxy.mergePipelineCaches(dest_ppc, srcs);
}

pub inline fn destroyPipelineCache(self: *Device, ppc: vk.PipelineCache) void {
    return self.proxy.destroyPipelineCache(ppc, null);
}

pub fn createPipelineLayout(self: *Device, info: PipelineLayoutCreateInfo) !vk.PipelineLayout {
    assert(info.set_layouts.len <= std.math.maxInt(u32));
    assert(info.push_constant_ranges.len <= std.math.maxInt(u32));

    return self.proxy.createPipelineLayout(&vk.PipelineLayoutCreateInfo{
        .flags = info.flags,
        .set_layout_count = @intCast(info.set_layouts.len),
        .p_set_layouts = info.set_layouts.ptr,
        .push_constant_range_count = @intCast(info.push_constant_ranges.len),
        .p_push_constant_ranges = info.push_constant_ranges.ptr,
    }, null);
}

pub inline fn destroyPipelineLayout(self: *Device, ppl: vk.PipelineLayout) void {
    return self.proxy.destroyPipelineLayout(ppl, null);
}

pub inline fn createGraphicsPipeline(self: *Device, info: GraphicsPipelineCreateInfo) !vk.Pipeline {
    var out: vk.Pipeline = undefined;

    _ = try self.proxy.createGraphicsPipelines(
        info.cache,
        (&vk.GraphicsPipelineCreateInfo{
            .p_next = info.p_next,
            .flags = info.flags,
            .stage_count = @intCast(info.stages.len),
            .p_stages = info.stages.ptr,
            .p_vertex_input_state = if (info.vertex_input_state) |*ptr| ptr else null,
            .p_input_assembly_state = if (info.input_assembly_state) |*ptr| ptr else null,
            .p_tessellation_state = if (info.tessellation_state) |*ptr| ptr else null,
            .p_viewport_state = if (info.viewport_state) |*ptr| ptr else null,
            .p_rasterization_state = if (info.rasterization_state) |*ptr| ptr else null,
            .p_multisample_state = if (info.multisample_state) |*ptr| ptr else null,
            .p_depth_stencil_state = if (info.depth_stencil_state) |*ptr| ptr else null,
            .p_color_blend_state = if (info.color_blend_state) |*ptr| ptr else null,
            .p_dynamic_state = if (info.dynamic_state) |*ptr| ptr else null,
            .layout = info.layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_handle = info.base_pipeline_handle,
            .base_pipeline_index = info.base_pipeline_index,
        })[0..1],
        null,
        (&out)[0..1],
    );

    return out;
}

pub inline fn destroyPipeline(self: *Device, pl: vk.Pipeline) void {
    return self.proxy.destroyPipeline(pl, null);
}
