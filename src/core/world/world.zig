const std = @import("std");
const utils = @import("utils");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

/// The maximum distance a player can go from [0;0].
pub const max_horizontal_coord = 30e6;
pub const max_world_size = max_horizontal_coord * 2;
pub const max_border_size = max_world_size;
pub const max_border_center_coord = max_horizontal_coord;
pub const max_entity_spawn_y = 20e6;
pub const min_entity_spawn_y = -max_entity_spawn_y;
pub const section_size = 16;
pub const min_world_height = section_size;
pub const max_world_height = (1 << @bitSizeOf(VerticalCoord)) - 32;
pub const max_world_y = (max_world_height >> 1) - 1;
pub const min_world_y = max_world_y - max_world_height + 1;
pub const way_above_max_y = max_world_y << 4;
pub const way_below_min_y = min_world_y << 4;

pub const HorizontalCoord = std.math.IntFittingRange(-max_horizontal_coord, max_horizontal_coord);
pub const VerticalCoord = @Int(.signed, 64 - 2 * @bitSizeOf(HorizontalCoord));
pub const PackedBlockPos = packed struct(u64) {
    x: HorizontalCoord,
    z: HorizontalCoord,
    y: VerticalCoord,

    pub fn format(self: PackedBlockPos, writer: *Writer) Writer.Error!void {
        return writer.print("[{d};{d};{d}]", .{ self.x, self.y, self.z });
    }
};

pub const Region = @import("Region.zig");
pub const DimensionProperties = @import("DimensionProperties.zig");

comptime {
    assert(@bitSizeOf(HorizontalCoord) * 2 + @bitSizeOf(VerticalCoord) == 64);
}

test {
    std.testing.refAllDecls(@This());
}
