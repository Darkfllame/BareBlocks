const std = @import("std");
const math = @import("math");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const value_providers = @import("value_providers.zig");

pub const packets_callback = @import("packets_callback.zig");
pub const Chunk = @import("Chunk.zig");
pub const DimensionProperties = @import("DimensionProperties.zig");
pub const Registry = @import("registry.zig").Registry;

pub const IntProvider = value_providers.IntProvider;
pub const FloatProvider = value_providers.FloatProvider;

pub const logger = std.log.scoped(.bare_blocks);

pub const BlockPosition = packed struct(u64) {
    x: u26,
    z: u26,
    y: u12,

    pub fn format(self: BlockPosition, writer: *Writer) Writer.Error!void {
        return writer.print("{{ {d}, {d}, {d}}}", .{ self.x, self.y, self.z });
    }
};

pub const Direction = enum {
    down,
    up,
    north,
    south,
    west,
    east,

    pub const AxisDirection = enum {
        negative,
        positive,

        pub fn step(self: AxisDirection) i2 {
            return switch (self) {
                .negative => 0,
                .positive => 1,
            };
        }

        pub fn opposite(self: AxisDirection) AxisDirection {
            return switch (self) {
                .negative => .positive,
                .positive => .negative,
            };
        }
    };
    pub const Axis = enum {
        x,
        y,
        z,

        pub fn fromString(str: []const u8) ?Axis {
            return std.meta.stringToEnum(Axis, str);
        }

        pub fn isVertical(self: Axis) bool {
            return self.plane() == .vertical;
        }

        pub fn isHorizontal(self: Axis) bool {
            return self.plane() == .horizontal;
        }

        pub fn getPositive(self: Axis) Direction {
            return switch (self) {
                .x => .east,
                .y => .up,
                .z => .south,
            };
        }

        pub fn getNegative(self: Axis) Direction {
            return switch (self) {
                .x => .west,
                .y => .down,
                .z => .north,
            };
        }

        pub fn choose(self: Axis, comptime T: type, x: T, y: T, z: T) T {
            return switch (self) {
                .x => x,
                .y => y,
                .z => z,
            };
        }

        pub fn plane(self: Axis) Plane {
            return switch (self) {
                .x, .z => .horizontal,
                .y => .vertical,
            };
        }
    };

    pub const Plane = enum {
        const directions = std.EnumArray(Plane, []const Direction).init(.{
            .horizontal = &.{ .north, .east, .south, .west },
            .vertical = &.{ .up, .down },
        });
        const axes = std.EnumArray(Plane, []const Axis).init(.{
            .horizontal = &.{ .x, .z },
            .vertical = &.{.y},
        });

        horizontal,
        vertical,

        pub fn randomDirection(self: Plane, rnd: std.Random) Direction {
            const dirs = directions.get(self);
            const idx = rnd.uintAtMost(usize, dirs.len);
            return dirs[idx];
        }

        pub fn randomAxis(self: Plane, rnd: std.Random) Axis {
            const _axes = axes.get(self);
            const idx = rnd.uintAtMost(usize, _axes.len);
            return _axes[idx];
        }

        pub fn faces(self: Plane) []const Direction {
            return directions.get(self);
        }

        pub fn shuffledCopy(self: Plane, allocator: Allocator, rnd: std.Random) Allocator.Error![]Direction {
            const dirs = directions.get(self);
            const copy = try allocator.dupe(Direction, dirs);
            rnd.shuffle(Direction, copy);
            return copy;
        }
    };

    pub fn getData3D(self: Direction) u8 {
        return switch (self) {
            .down => 0,
            .up => 1,
            .north => 2,
            .south => 3,
            .west => 4,
            .east => 5,
        };
    }

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .down => .up,
            .up => .down,
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }

    pub fn data2D(self: Direction) i32 {
        return switch (self) {
            .down, .up => -1,
            .south => 0,
            .west => 1,
            .north => 2,
            .east => 3,
        };
    }

    pub fn axisDirection(self: Direction) AxisDirection {
        return switch (self) {
            .down, .north, .west => .negative,
            .up, .south, .east => .positive,
        };
    }

    pub fn axis(self: Direction) Axis {
        return switch (self) {
            .down, .up => .y,
            .north, .south => .z,
            .west, .east => .x,
        };
    }

    pub fn normal(self: Direction) math.Vec3i {
        return switch (self) {
            .down => .new(0, -1, 0),
            .up => .new(0, 1, 0),
            .north => .new(0, 0, -1),
            .south => .new(0, 0, 1),
            .west => .new(-1, 0, 0),
            .east => .new(1, 0, 0),
        };
    }
};
