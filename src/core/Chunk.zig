const Chunk = @This();
const std = @import("std");
const math = @import("math");
const core = @import("core.zig");
const DimensionProperties = @import("DimensionProperties.zig");
const Block = @import("Block.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const y_range_max: comptime_int = @ceil(@as(comptime_float, DimensionProperties.y_range.max) / section_size);

comptime {
    assert(std.math.isPowerOfTwo(section_size));
}

pub const section_size = 16;
pub const bits_per_section_strip = std.math.log2(section_size);
pub const blocks_per_section = section_size * section_size * section_size;

pub const SectionIndex = @Int(.unsigned, bits_per_section_strip);
pub const StripPaletteIndex = @Int(.unsigned, bits_per_section_strip * 2);
pub const SectionsIndex = @Int(.unsigned, std.math.log2(y_range_max));
pub const SectionsSize = @Int(.unsigned, std.math.log2(std.math.ceilPowerOfTwoAssert(u16, y_range_max + 1)));

pub const VerticalStrips = struct {
    const StripNode = struct {
        node: std.DoublyLinkedList.Node,
        palette_index: StripPaletteIndex,
        size: SectionIndex,
    };

    list: std.DoublyLinkedList,
    size: packed struct { min: SectionIndex, max: SectionIndex },

    pub const empty = VerticalStrips{
        .list = .{},
        .size = .{ .min = 0, .max = 0 },
    };
};

pub const SectionData = union(enum) {
    const LayeredElement = usize;
    const layer_mask = (1 << bits_per_section_strip) - 1;
    const layered_bits_size = @divExact(@bitSizeOf(LayeredElement), bits_per_section_strip);
    const layered_size = @divExact(layered_bits_size, 8);

    /// `0` is air, `1` is the first and only palette index for this section.
    solid: u1,
    /// Uses tons of data and should never be used.
    raw: *[blocks_per_section]u16,
    /// Section is separated into multiple horizontal layers
    layered: [layered_size]LayeredElement,
    vertical_strips: VerticalStrips,
};

pub const BlockPalette = struct {
    states: [*]*Block.State,
    states_cap: PaletteSize,
    states_len: PaletteSize,

    pub const max_unused_states = 16;

    pub const PaletteIndex = @Int(.unsigned, std.math.log2(blocks_per_section));
    pub const PaletteSize = @Int(.unsigned, std.math.log2(std.math.ceilPowerOfTwoAssert(u16, blocks_per_section + 1)));
};

pub const Section = struct {
    data: SectionData,
    palette: BlockPalette,

    pub const empty = Section{
        .data = .{ .solid = 0 },
        .palette = .{
            .states = &[0]*Block.State{},
            .states_cap = 0,
            .states_len = 0,
        },
    };
};

mutex: Io.Mutex,
sections: [*]Section,
sections_cap: SectionsSize,
/// A value of `0` means the entire chunk is empty.
sections_len: SectionsSize,

pub const Position = packed struct { x: SectionIndex, y: DimensionProperties.HeightInt, z: SectionIndex };
pub const SectionPosition = packed struct {x:SectionIndex,y:SectionIndex,z:SectionIndex};
