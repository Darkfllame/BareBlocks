const DimensionProperties = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("../core.zig");
const world = @import("world.zig");

flags: Flags,
coordinate_scale: f64,
ambient_light: f32,
monster_spawn: struct {
    light_level: core.IntProvider,
    block_light_limit: core.IntProvider,
},
/// The maximum height to which chorus fruits and Nether portals can bring players within this
/// dimension. This excludes portals that were already built above the limit as they still connect
/// normally. Cannot be greater than height.max.
logical_height: HeightInt,
/// Build range, inclusive
height: utils.Range(HeightInt),
infiniburn: utils.Identifier.Tag,
skybox: Skybox,
cardinal_light: enum { default, nether },
default_clock: ?utils.Identifier,

pub const height_range = utils.Range(HeightInt).init(world.min_world_height, world.max_world_height);
pub const y_range = utils.Range(HeightInt).init(world.min_world_y, world.max_world_y);
pub const way_y_range =utils.Range(std.math.IntFittingRange(world.way_below_min_y, world.way_above_max_y)).init(world.way_below_min_y, world.way_below_min_y);

pub const overworld = DimensionProperties{
    .flags = .{
        .skylight = true,
        .ceiling = false,
        .ender_dragon_fight = false,
        .fixed_time = false,
    },
    .coordinate_scale = 1,
    .ambient_light = 0,
    .monster_spawn = .{
        .light_level = .{ .uniform = .init(0, 7) },
        .block_light_limit = .{ .constant = 0 },
    },
    .logical_height = 319,
    .height = .init(-64, 319),
    .infiniburn = .{ .tag = .vanilla("infiniburn_overworld") },
    .skybox = .overworld,
    .cardinal_light = .default,
    .default_clock = .vanilla("overworld"),
};

pub const the_nether = DimensionProperties{
    .flags = .{
        .skylight = false,
        .ceiling = true,
        .ender_dragon_fight = false,
        .fixed_time = true,
    },
    .coordinate_scale = 8,
    .ambient_light = 0.1,
    .monster_spawn = .{
        .light_level = .{ .constant = 7 },
        .block_light_limit = .{ .constant = 15 },
    },
    .logical_height = 128,
    .height = .init(0, 255),
    .infiniburn = .{ .tag = .vanilla("infiniburn_nether") },
    .skybox = .none,
    .cardinal_light = .nether,
    .default_clock = null,
};

pub const the_end = DimensionProperties{
    .flags = .{
        .skylight = true,
        .ceiling = false,
        .ender_dragon_fight = true,
        .fixed_time = true,
    },
    .coordinate_scale = 1,
    .ambient_light = 0.25,
    .monster_spawn = .{
        .light_level = .{ .constant = 15 },
        .block_light_limit = .{ .constant = 0 },
    },
    .logical_height = 255,
    .height = .init(0, 255),
    .infiniburn = .{ .tag = .vanilla("infiniburn_nether") },
    .skybox = .end,
    .cardinal_light = .default,
    .default_clock = .vanilla("the_end"),
};

pub const overworld_caves = DimensionProperties{
    .flags = .{
        .skylight = true,
        .ceiling = true,
        .ender_dragon_fight = false,
        .fixed_time = false,
    },
    .coordinate_scale = 1,
    .ambient_light = 0,
    .monster_spawn = .{
        .light_level = .{ .uniform = .init(0, 7) },
        .block_light_limit = .{ .constant = 0 },
    },
    .logical_height = 319,
    .height = .init(-64, 319),
    .infiniburn = .{ .tag = .vanilla("infiniburn_overworld") },
    .skybox = .overworld,
    .cardinal_light = .default,
    .default_clock = .vanilla("overworld"),
};

pub const HeightInt = std.math.IntFittingRange(-1, world.max_world_height);

pub const Skybox = enum { none, overworld, end };

pub const Flags = packed struct {
    skylight: bool = false,
    ceiling: bool = false,
    ender_dragon_fight: bool = false,
    fixed_time: bool = false,
};

pub inline fn coordScaleTo(self: *const DimensionProperties, other: *const DimensionProperties) f64 {
    return self.coordinate_scale / other.coordinate_scale;
}

pub fn buildRange(self: *const DimensionProperties) @Int(.unsigned, @bitSizeOf(world.VerticalCoord)) {
    return @intCast(self.height.max - self.height.min + 1);
}

test {
    std.testing.refAllDecls(@This());
}
