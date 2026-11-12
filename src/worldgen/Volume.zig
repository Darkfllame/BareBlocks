//! A box of sample positions (vanilla's `DensityVolume`), `step` blocks apart on each axis.
//! Buffers of a volume are indexed y first, then x, then z.
const Volume = @This();
const std = @import("std");

size_x: i32,
size_y: i32,
size_z: i32,
min_x: i32,
min_y: i32,
min_z: i32,
step_x: i32 = 1,
step_y: i32 = 1,
step_z: i32 = 1,

pub fn index(self: Volume, x: i32, y: i32, z: i32) usize {
    return @intCast(y + (x + z * self.size_x) * self.size_y);
}

pub fn blockX(self: Volume, x: i32) i32 {
    return self.min_x + x * self.step_x;
}

pub fn blockY(self: Volume, y: i32) i32 {
    return self.min_y + y * self.step_y;
}

pub fn blockZ(self: Volume, z: i32) i32 {
    return self.min_z + z * self.step_z;
}

pub fn maxX(self: Volume) i32 {
    return self.min_x + self.size_x * self.step_x - 1;
}

pub fn maxY(self: Volume) i32 {
    return self.min_y + self.size_y * self.step_y - 1;
}

pub fn maxZ(self: Volume) i32 {
    return self.min_z + self.size_z * self.step_z - 1;
}

pub fn size(self: Volume) usize {
    return @intCast(self.size_x * self.size_y * self.size_z);
}

pub fn eql(a: Volume, b: Volume) bool {
    return std.meta.eql(a, b);
}

/// `null` if the block isn't one of the volume's sample positions.
pub fn indexOfBlock(self: Volume, block_x: i32, block_y: i32, block_z: i32) ?usize {
    const x = block_x - self.min_x;
    const y = block_y - self.min_y;
    const z = block_z - self.min_z;
    if (x < 0 or y < 0 or z < 0) return null;
    if (x >= self.size_x * self.step_x or y >= self.size_y * self.step_y or z >= self.size_z * self.step_z) return null;
    if (@mod(x, self.step_x) != 0 or @mod(y, self.step_y) != 0 or @mod(z, self.step_z) != 0) return null;
    return self.index(@divFloor(x, self.step_x), @divFloor(y, self.step_y), @divFloor(z, self.step_z));
}
