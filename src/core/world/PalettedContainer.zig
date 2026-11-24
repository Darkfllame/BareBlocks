const PalettedContainer = @This();
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");

const TypeErasedRegistry = core.registry.TypeErasedRegistry;
const RegistryEntryId = core.registry.RegistryEntryId;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

strategy: Strategy,
data: Data,

pub const Configuration = struct {
    fn simple(cmode: CreateMode, bits: u8) Configuration {
        return .{
            .always_repack = false,
            .bits_in_memory = bits,
            .bits_in_storage = bits,
            .create_mode = cmode,
        };
    }

    fn global(bits_in_memory: u8, bits_in_storage: u8) Configuration {
        return .{
            .always_repack = true,
            .bits_in_memory = bits_in_memory,
            .bits_in_storage = bits_in_storage,
            .create_mode = .global,
        };
    }

    always_repack: bool,
    bits_in_memory: u8,
    bits_in_storage: u8,
    create_mode: CreateMode,

    pub const CreateMode = enum { single_value, linear, hashmap, global };

    pub fn createPalette(self: Configuration, allocator: Allocator, strategy: *const Strategy, entries: []const RegistryEntryId) Allocator.Error!Palette {
        _ = strategy; // autofix
        switch (self.create_mode) {
            .single_value => {
                assert(self.always_repack == false);
                assert(self.bits_in_memory == 0);
                assert(self.bits_in_storage == 0);
                assert(entries.len == 1);
                return .{ .single_value = entries[0] };
            },
            .linear => {
                assert(self.always_repack == false);
                assert(self.bits_in_memory == self.bits_in_storage);

                const bits = self.bits_in_memory;
                const values_len = @as(usize, 1) << @intCast(bits);
                assert(entries.len <= values_len);

                const values = try allocator.alloc(RegistryEntryId, values_len);
                @memcpy(values[0..entries.len], entries);
                @memcpy(values[entries.len..], @as(RegistryEntryId, @fromBackingInt(0)));

                return .{ .linear = .{
                    .values = values,
                    .bits = bits,
                    .size = entries.len,
                } };
            },
            .hashmap => {
                assert(self.always_repack == false);
                assert(self.bits_in_memory == self.bits_in_storage);

                const bits = self.bits_in_memory;
                const values_len = @as(usize, 1) << @intCast(bits);

                var pal = Palette{ .hashmap = .{
                    .map = .empty,
                    .by_id = &.{},
                    .next_id = 0,
                    .size = 0,
                } };

                const hm = &pal.hashmap;

                // hm.by_id = try all
                try hm.map.ensureTotalCapacity(allocator, values_len);

                for (entries) |value| {
                    const id = hm.next_id;
                    hm.next_id += 1;

                    hm.map.putAssumeCapacity(value, id);
                }
            },
        }
    }
};

pub const Strategy = struct {
    fn minimumBitsRequiredForDistinctValues(count: usize) u8 {
        return std.math.log2_int_ceil(usize, count);
    }

    global_map: *const TypeErasedRegistry, // TODO: Not always a plain registry
    max_bits_in_memory: u8,
    entry_count: usize,
    mode: Mode,

    pub const Mode = enum(u8) { block_states = 4, biomes = 2 }; // Also represents the `bitsPerAxis` variable.

    pub fn init(registry: *const TypeErasedRegistry, mode: Mode) Strategy {
        return .{
            .global_map = registry,
            .max_bits_in_memory = minimumBitsRequiredForDistinctValues(registry.count()),
            .bits_per_axis = @backingInt(mode),
            .entry_count = 1 << (@backingInt(mode) * 3),
            .mode = mode,
        };
    }

    pub fn getConfigurationForBitCount(self: *const Strategy, entry_bits: u8) Configuration {
        return switch (self.mode) {
            .block_states => switch (entry_bits) {
                0 => .simple(.single_value, 0),
                1...4 => .simple(.linear, 4),
                5...8 => .simple(.hashmap, entry_bits),
                else => .global(self.max_bits_in_memory, entry_bits),
            },
            .biomes => switch (entry_bits) {
                0 => .simple(.single_value, 0),
                1...3 => .simple(.linear, entry_bits),
                else => .global(self.max_bits_in_memory, entry_bits),
            },
        };
    }

    pub fn getConfigurationForPaletteSize(self: *const Strategy, palette_size: usize) Configuration {
        const bits = minimumBitsRequiredForDistinctValues(palette_size);
        return self.getConfigurationForBitCount(bits);
    }
};

pub const Data = struct {
    configuration: Configuration,
    storage: BitStorage,
    palette: Palette,
};

pub const BitStorage = struct {
    const short_data = !builtin.optimize.runtimeSafety();
    const BitsData = if (short_data) [*]u64 else []u64;

    const magic = [_][3]u32{
        .{ 0xFFFFFFFF, 0xFFFFFFFF, 0 },
        .{ 0x80000000, 0x00000000, 0 },
        .{ 0x55555555, 0x55555555, 0 },
        .{ 0x80000000, 0x00000000, 1 },
        .{ 0x33333333, 0x33333333, 0 },
        .{ 0x2AAAAAAA, 0x2AAAAAAA, 0 },
        .{ 0x24924924, 0x24924924, 0 },
        .{ 0x80000000, 0x00000000, 2 },
        .{ 0x1C71C71C, 0x1C71C71C, 0 },
        .{ 0x19999999, 0x19999999, 0 },
        .{ 0x1745D174, 0x1745D174, 0 },
        .{ 0x15555555, 0x15555555, 0 },
        .{ 0x13B13B13, 0x13B13B13, 0 },
        .{ 0x12492492, 0x12492492, 0 },
        .{ 0x11111111, 0x11111111, 0 },
        .{ 0x80000000, 0x00000000, 3 },
        .{ 0x0F0F0F0F, 0x0F0F0F0F, 0 },
        .{ 0x0E38E38E, 0x0E38E38E, 0 },
        .{ 0x0D79435E, 0x0D79435E, 0 },
        .{ 0x0CCCCCCC, 0x0CCCCCCC, 0 },
        .{ 0x0C30C30C, 0x0C30C30C, 0 },
        .{ 0x0BA2E8BA, 0x0BA2E8BA, 0 },
        .{ 0x0B21642C, 0x0B21642C, 0 },
        .{ 0x0AAAAAAA, 0x0AAAAAAA, 0 },
        .{ 0x0A3D70A3, 0x0A3D70A3, 0 },
        .{ 0x09D89D89, 0x09D89D89, 0 },
        .{ 0x097B425E, 0x097B425E, 0 },
        .{ 0x09249249, 0x09249249, 0 },
        .{ 0x08D3DCB0, 0x08D3DCB0, 0 },
        .{ 0x08888888, 0x08888888, 0 },
        .{ 0x08421084, 0x08421084, 0 },
        .{ 0x80000000, 0x00000000, 4 },
        .{ 0x07C1F07C, 0x07C1F07C, 0 },
        .{ 0x07878787, 0x07878787, 0 },
        .{ 0x07507507, 0x07507507, 0 },
        .{ 0x071C71C7, 0x071C71C7, 0 },
        .{ 0x06EB3E45, 0x06EB3E45, 0 },
        .{ 0x06BCA1AF, 0x06BCA1AF, 0 },
        .{ 0x06906906, 0x06906906, 0 },
        .{ 0x06666666, 0x06666666, 0 },
        .{ 0x063E7063, 0x063E7063, 0 },
        .{ 0x06186186, 0x06186186, 0 },
        .{ 0x05F417D0, 0x05F417D0, 0 },
        .{ 0x05D1745D, 0x05D1745D, 0 },
        .{ 0x05B05B05, 0x05B05B05, 0 },
        .{ 0x0590B216, 0x0590B216, 0 },
        .{ 0x0572620A, 0x0572620A, 0 },
        .{ 0x05555555, 0x05555555, 0 },
        .{ 0x05397829, 0x05397829, 0 },
        .{ 0x051EB851, 0x051EB851, 0 },
        .{ 0x05050505, 0x05050505, 0 },
        .{ 0x04EC4EC4, 0x04EC4EC4, 0 },
        .{ 0x04D4873E, 0x04D4873E, 0 },
        .{ 0x04BDA12F, 0x04BDA12F, 0 },
        .{ 0x04A7904A, 0x04A7904A, 0 },
        .{ 0x04924924, 0x04924924, 0 },
        .{ 0x047DC11F, 0x047DC11F, 0 },
        .{ 0x0469EE58, 0x0469EE58, 0 },
        .{ 0x0456C797, 0x0456C797, 0 },
        .{ 0x04444444, 0x04444444, 0 },
        .{ 0x04325C53, 0x04325C53, 0 },
        .{ 0x04210842, 0x04210842, 0 },
        .{ 0x04104104, 0x04104104, 0 },
        .{ 0x80000000, 0x00000000, 5 },
    };

    const empty_data = [1]u64{0};

    fn getData(self: *const BitStorage) []u64 {
        const ptr = self.data;
        const estimated_size = @divCeil(self.size, self.values_per_u64);

        if (short_data) return ptr[0..estimated_size];

        assert(ptr.len == estimated_size);
        return ptr;
    }

    fn cellIndex(self: *const BitStorage, bit_index: usize) usize {
        assert(self.bits > 0);
        return (((bit_index *% self.divide_mul) +% self.divide_mul) >> 32) >> @intCast(self.divide_shift);
    }

    data: BitsData,
    size: usize,
    mask: u32,
    divide_mul: u32,
    divide_add: u32,
    divide_shift: u8,
    bits: u8,
    values_per_u64: u8,

    pub fn initZeroBits(size: usize) BitStorage {
        return .{
            .data = if (short_data) empty_data.ptr else empty_data,
            .size = size,
            .mask = 0,
            .divide_mul = 0,
            .divide_add = 0,
            .divide_shift = 0,
            .bits = 0,
            .values_per_u64 = 1,
        };
    }

    pub fn init(gpa: Allocator, bits: u8, size: usize) Allocator.Error!BitStorage {
        assert(bits >= 1 and bits <= 32);

        const data = try gpa.alloc(u64, @divCeil(size * bits, 64));
        @memset(data, 0);

        return initWithData(bits, size, data);
    }

    pub fn initWithData(bits: u8, size: usize, data: []u64) BitStorage {
        assert(bits >= 1 and bits <= 32);
        assert(data.len == @divCeil(size * bits, 64));

        const values_per_u64s = 64 / bits;
        const row = magic[values_per_u64s - 1];

        return .{
            .data = if (short_data) data.ptr else data,
            .size = size,
            .mask = (@as(u32, 1) << @intCast(bits)) - 1,
            .divide_mul = row[0],
            .divide_add = row[1],
            .divide_shift = @intCast(row[2]),
            .bits = bits,
            .values_per_u64 = values_per_u64s,
        };
    }

    pub fn deinit(self: *BitStorage, gpa: Allocator) void {
        if (self.bits == 0) return;

        gpa.free(self.getData());
        self.* = undefined;
    }

    pub fn getAndSet(self: *const BitStorage, index: usize, value: u32) u32 {
        assert(index < self.size);
        assert((value & self.mask) == value);
        if (self.bits == 0) return 0;

        const data = self.getData();

        const cell_idx = self.cellIndex(index);
        const cell_value = data[cell_idx];
        const bit_index = (index - cell_idx * self.values_per_u64) * self.bits;
        const old_value = (cell_value >> bit_index) & self.mask;
        data[cell_idx] = cell_value & ~(self.mask << bit_index) | ((value & self.mask) << bit_index);
        return @truncate(old_value);
    }

    pub inline fn set(self: *const BitStorage, index: usize, value: u32) void {
        _ = self.getAndSet(index, value);
    }

    pub fn fill(self: *const BitStorage, value: u32) void {
        assert((value & self.mask) == value);
        if (self.bits == 0) return;

        const data = self.getData();

        var cell_value = value & self.mask;
        var offset = self.bits;

        while (true) {
            cell_value |= cell_value << @bitCast(offset);
            offset <<= 1;

            if (offset < 64) break;
        }

        @memset(data, cell_value);
    }

    pub fn get(self: *const BitStorage, index: usize) u32 {
        assert(index < self.size);
        if (self.bits == 0) return 0;

        const data = self.getData();

        const cell_idx = self.cellIndex(index);
        const cell_value = data[cell_idx];
        const bit_index = (index - cell_idx * self.values_per_u64) * self.bits;
        return @truncate((cell_value >> bit_index) & self.mask);
    }

    pub const getRaw: fn (*const BitStorage) []const u64 = getData;
};

pub const Palette = union {
    single_value: RegistryEntryId,
    linear: struct {
        values: []const RegistryEntryId,
        bits: u8,
        size: usize,
    },
    hashmap: struct {
        map: std.AutoHashMapUnmanaged(RegistryEntryId, u32),
        by_id: []const RegistryEntryId,
        next_id: u32,
        size: usize,
        bits: u8,
    },
    global: void, // TODO
};
