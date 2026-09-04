const DimensionProperties = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("core.zig");
const Chunk = @import("Chunk.zig");

const bits_for_y = @bitSizeOf(@FieldType(core.BlockPosition, "y"));
const y_size = (1 << bits_for_y) - 32;
const max_y = (y_size >> 1) - 1;

flags: Flags,
coordinate_scale: f64,
ambient_light: f32,
monster_spawn: struct { light_level: u4, block_light_limit: u4 },
logical_height: HeightInt,
height: utils.Range(HeightInt),
infiniburn: utils.Identifier,

pub const height_range = utils.Range(HeightInt).init(Chunk.section_size, y_size);
pub const y_range = utils.Range(HeightInt).init(max_y - y_size + 1, max_y);
pub const way_y_range = utils.Range(i16).init(
    @as(comptime_int, y_range.min) << 4,
    @as(comptime_int, y_range.max) << 4,
);

pub const HeightInt = @Int(.signed, bits_for_y + 1);

pub const Flags = packed struct {
    skylight: bool = false,
    ceiling: bool = false,
    ender_dragon_fight: bool = false,
    fixed_time: bool = false,
};

pub fn chunkPosToSection(dim: *const DimensionProperties, pos: Chunk.Position) ?struct {Chunk.SectionIndex,Chunk. SectionPosition} {
    if (!dim.height.inRange(pos.y)) return false;
    const relative_y: u16 = @intCast(@as(i16, pos.y) - dim.height.min);
    return .{
        @intCast(relative_y / Chunk.section_size),
        .{
            .x = pos.x,
            .y = @intCast(relative_y % 16),
            .z = pos.z,
        },
    };
}