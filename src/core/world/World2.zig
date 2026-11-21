const World = @This();
const std = @import("std");
const zio = @import("zio");
const lm = @import("math");
const worldgen = @import("worldgen");
const core = @import("../core.zig");
const DimensionProperties = @import("DimensionProperties.zig");
const Region = @import("Region.zig");

const Io = std.Io;

fn globalGroupConnector(server: *core.Server, world: *World) Io.Cancelable!void {
    const io = server.runtime.io();
    // ? Will this return if `deinit` is called.
    world.group.await(io) catch world.group.cancel(io);
}

// TODO: Region tick
// TODO: Entity management
// TODO: Per-world players

owner: *core.Server,
owner_counter: std.atomic.Value(u32) = .init(0),

/// Size determined by the `dimension_type` registry.
dimensions: [*]Dimension,

group: Io.Group = .init,

pub const Dimension = struct {
    world: *World,
    properties: *const DimensionProperties,
    generation: *worldgen.RandomState,
    biome_search: worldgen.climate.ParameterList.Search,

    regions_mutex: zio.Mutex = .init,
    regions_owner: std.AutoHashMapUnmanaged(lm.Vec2i, u32) = .empty,
    threaded_regions: std.AutoHashMapUnmanaged(u32, *ThreadedRegion) = .empty,
};

pub const ThreadedRegion = struct {
    world: *World,
    dimension: *Dimension,
    owner: u32,
    refcount: core.RefCount,

    channel_buffer: [8]Request,
    channel: zio.Channel(Request),
};

pub const Request = union(enum) {
    merge: *ThreadedRegion,
};

pub fn init(self: *World, owner: *core.Server, seed: u64) !void {
    const dim_types = owner.root_registry.getDynamic(*const DimensionProperties, .dimension_type).?;
    const gpa = owner.allocator;

    const dimensions = try gpa.alloc(Dimension, dim_types.count());
    errdefer gpa.free(dimensions);
    
    var it = dim_types.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        _, const props = entry;

        dimensions[idx] = .{
            .world = self,
            .properties = props,
        };
    }

    self.* = .{
        .owner = owner,
        .seed = seed,

        .dimensions = dimensions,
    };
}

pub fn deinit(self: *World) void {
    const dim_types = self.owner.root_registry.getDynamic(*const DimensionProperties, .dimension_type).?;
    const gpa = self.owner.allocator;

    const io = self.owner.runtime.io();

    const dimensions = self.dimensions[0..dim_types.count()];

    self.group.cancel(io);

    for (dimensions) |dim| {
        dim.regions_owner.deinit(gpa);
        dim.threaded_regions.deinit(gpa);
    }
    gpa.free(dimensions);
}