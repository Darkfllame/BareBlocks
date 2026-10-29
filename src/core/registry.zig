const registry = @This();
const std = @import("std");
const utils = @import("utils");
const registries = @import("registries");

const Allocator = std.mem.Allocator;
const Identifier = utils.Identifier;
const assert = std.debug.assert;

const logger = std.log.scoped(.@"bare_blocks/registry");

pub const max_registry_id = std.math.maxInt(i32);

pub const RegistryType = registries.RegistryType;

pub const RegistryEntryId = enum(u32) { _ };

pub const TypeErasedRegistry = struct {
    const IdInt = @typeInfo(RegistryEntryId).@"enum".tag_type;
    const max_id = std.math.maxInt(IdInt);

    fn resizeIfNeeded(self: *TypeErasedRegistry, gpa: Allocator, new_len: usize) Allocator.Error!void {
        if (new_len > std.math.maxInt(u32)) return error.OutOfMemory;

        if (new_len > self.nid_mask.capacity()) {
            try self.nid_mask.resize(gpa, new_len, false);
        }
        if (new_len > self.ids.len) {
            self.ids = try gpa.realloc(self.ids, new_len);
        }
        if (new_len > self.data.len) {
            self.data = try gpa.realloc(self.data, new_len);
        }
        try self.id2num.ensureTotalCapacity(gpa, @intCast(new_len));
    }

    fn newNumericId(self: *TypeErasedRegistry, gpa: Allocator, id: Identifier) Allocator.Error!RegistryEntryId {
        const idx = blk: {
            if (self.nid_continuous) |next| {
                if (next >= max_id) return error.OutOfMemory;

                const next_continuous = next + 1;
                try self.resizeIfNeeded(gpa, next_continuous);
                self.nid_continuous = next_continuous;

                break :blk next;
            }

            var it = self.nid_mask.iterator(.{ .kind = .unset });
            break :blk it.next() orelse {
                const next_idx = self.nid_mask.capacity();
                if (next_idx >= max_id) return error.OutOfMemory;
                const new_len = next_idx + (2 * @bitSizeOf(usize));
                try self.resizeIfNeeded(gpa, new_len);
                self.nid_continuous = @as(IdInt, @intCast(next_idx)) +| 1;
                break :blk next_idx;
            };
        };

        self.nid_mask.set(idx);
        self.ids[idx] = id;
        return @fromBackingInt(@intCast(idx));
    }

    /// Returns the same value as passed in `nid`.
    fn newNumericIdFixed(self: *TypeErasedRegistry, gpa: Allocator, nid: RegistryEntryId, id: Identifier) !RegistryEntryId {
        const int = @backingInt(nid);
        blk: {
            if (self.nid_continuous) |value| {
                if (value == int) {
                    self.nid_continuous.? +|= 1;
                    break :blk;
                }
                if (value > int) {
                    return error.InvalidNumericId;
                }
                self.nid_continuous = null;
            }
            try self.resizeIfNeeded(gpa, int);
            if (self.nid_mask.isSet(int)) return error.InvalidNumericId;
        }

        self.nid_mask.set(int);
        self.ids[int] = id;
        return nid;
    }

    fn removeNumericId(self: *TypeErasedRegistry, nid: RegistryEntryId) void {
        const int = @backingInt(nid);
        if (self.nid_continuous) |value| {
            if (int == value - 1) {
                self.nid_continuous.? -|= 1;
                self.nid_mask.unset(int);
                return;
            }
        }
    }

    type: RegistryType,
    frozen: bool = false,
    /// Check if numeric id is valid
    nid_mask: std.bit_set.Dynamic = .{},
    nid_continuous: ?IdInt = 0,
    /// Named ids to numeric ids
    id2num: std.HashMapUnmanaged(Identifier, IdInt, Identifier.HashCtx, std.hash_map.default_max_load_percentage) = .empty,
    /// Named ids
    ids: []Identifier = &.{},
    data: []*anyopaque = &.{},

    pub const RegisterError = Allocator.Error || error{
        DuplicateEntry,
        RegisterFrozen,
        InvalidNumericId,
    };

    pub const RegisterOptions = struct {
        gpa: Allocator,
        arena: Allocator,
        id: Identifier,
        nid: ?RegistryEntryId = null,

        pub fn named(gpa: Allocator, arena: Allocator, id: Identifier) RegisterOptions {
            return .{ .gpa = gpa, .arena = arena, .id = id };
        }
        pub fn namedNumeric(gpa: Allocator, arena: Allocator, id: Identifier, nid: RegistryEntryId) RegisterOptions {
            return .{ .gpa = gpa, .arena = arena, .id = id, .nid = nid };
        }

        pub fn fromManyOptions(m: RegisterManyOptions, id: Identifier) RegisterOptions {
            return .{ .gpa = m.gpa, .arena = m.arena, .id = id };
        }

        pub fn fromManyOptionsNumeric(m: RegisterManyOptions, id: Identifier, nid: RegistryEntryId) RegisterOptions {
            return .{ .gpa = m.gpa, .arena = m.arena, .id = id, .nid = nid };
        }
    };

    pub const RegisterManyOptions = struct {
        gpa: Allocator,
        arena: Allocator,
    };

    pub const RegisterManyEntry = struct {
        id: Identifier,
        nid: ?RegistryEntryId = null,
        value: *anyopaque,
    };

    pub fn new(@"type": RegistryType) TypeErasedRegistry {
        return .{ .type = @"type" };
    }

    pub fn freeze(self: *TypeErasedRegistry) void {
        self.id2num.rehash(Identifier.HashCtx{});
        self.frozen = true;
    }

    pub inline fn register(self: *TypeErasedRegistry, options: RegisterOptions, value: *anyopaque) RegisterError!RegistryEntryId {
        var out: RegistryEntryId = undefined;
        try self.registerInto(options, value, &out);
        return out;
    }

    pub fn registerInto(self: *TypeErasedRegistry, options: RegisterOptions, value: *anyopaque, out: *RegistryEntryId) RegisterError!void {
        try self.registerMany(
            .{ .gpa = options.gpa, .arena = options.arena },
            &.{.{
                .id = options.id,
                .nid = options.nid,
                .value = value,
            }},
            out[0..1],
        );
    }

    pub fn registerMany(self: *TypeErasedRegistry, options: RegisterManyOptions, entries: []const RegisterManyEntry, out: []RegistryEntryId) RegisterError!void {
        assert(entries.len == out.len);
        if (self.frozen) return error.RegisterFrozen;

        const size = @min(self.nid_mask.count(), self.ids.len, self.data.len);
        try self.resizeIfNeeded(options.gpa, size + entries.len);
        var id_len: usize = 0;
        for (entries) |entry| {
            id_len, const ov = @addWithOverflow(id_len, entry.id.dupeLen());
            if (ov == 1) return error.OutOfMemory;
        }
        const buf = try options.arena.alloc(u8, id_len);
        const fba = std.heap.FixedBufferAllocator.init(&buf);

        for (entries, out) |entry, *nid_out| {
            const id = try entry.id.dupe(fba.allocator());

            nid_out.* = if (entry.nid) |nid|
                try self.newNumericIdFixed(options.gpa, nid, id)
            else
                try self.newNumericId(options.gpa, id);
            self.id2num.putAssumeCapacityNoClobber(id, nid_out.*);
            self.data[@backingInt(nid_out.*)] = entry.value;
        }
    }

    pub fn getEntry(self: *TypeErasedRegistry, nid: RegistryEntryId) ?*anyopaque {
        const idx = @backingInt(nid);
        const size = @min(self.nid_mask.capacity(), self.ids.len, self.data.len);
        if (idx >= size or !self.nid_mask.isSet(idx)) return null;
        return self.data[idx];
    }

    pub fn getNamedEntry(self: *TypeErasedRegistry, id: Identifier) ?*anyopaque {
        if (self.id2num.get(id)) |nid| {
            const idx = @backingInt(nid);
            const size = @min(self.nid_mask.count(), self.ids.len, self.data.len);
            if (idx >= size or !self.nid_mask.isSet(idx)) {
                @branchHint(.unlikely);
                logger.warn("Ghost entry discovered in registry.{t}@{x} for {f}: FIX YO REGISTRY DAWG", .{ self.type, self, id.alt(.omit_minecraft) });
                assert(self.id2num.remove(id));
                if (idx < size) self.nid_mask.unset(idx);
                return null;
            }
            return self.data[idx];
        }
        return null;
    }
};

pub const RootRegistry = struct {
    type_erased: TypeErasedRegistry = .{ .type = .registry_type },

    // pub fn register(self: *RootRegistry, )
};

pub fn Registry(comptime SubType: type, comptime enum_type: RegistryType) type {
    return struct {
        const Self = @This();

        comptime SubType: type = SubType,
        comptime type: RegistryType = enum_type,
        type_erased: TypeErasedRegistry = .{ .type = enum_type },

        pub fn new() Self {
            return .{};
        }

        pub inline fn freeze(self: *Self) void {
            return self.type_erased.freeze();
        }

        pub inline fn register(self: *Self, options: TypeErasedRegistry.RegisterOptions, value: *SubType) TypeErasedRegistry.RegisterError!RegistryEntryId {
            return self.type_erased.register(options, value);
        }

        pub inline fn registerInto(self: *Self, options: TypeErasedRegistry.RegisterOptions, value: *SubType, out: *RegistryEntryId) TypeErasedRegistry.RegisterError!void {
            return self.type_erased.registerInto(options, value, out);
        }

        pub inline fn registerMany(self: *Self, options: TypeErasedRegistry.RegisterManyOptions, entries: []const TypeErasedRegistry.RegisterManyEntry, out: []RegistryEntryId) TypeErasedRegistry.RegisterError!void {
            return self.type_erased.registerMany(options, entries, out);
        }

        pub inline fn getEntry(self: *Self, nid: RegistryEntryId) ?*SubType {
            return @ptrCast(@alignCast(self.type_erased.getEntry(nid)));
        }

        pub inline fn getNamedEntry(self: *Self, id: Identifier) ?*SubType {
            return @ptrCast(@alignCast(self.type_erased.getNamedEntry(id)));
        }
    };
}

/// Tell whether `T` is a product of `Registry()` or not.
pub inline fn isRegistry(comptime T: type) bool {
    comptime return @hasField(T, "SubType") and @hasField(T, "type") and
        @FieldType(T, "SubType") == type and @FieldType(T, "type") == RegistryType and
        T == Registry(@as(T, undefined).SubType, @as(T, undefined).type);
}

test {
    std.testing.refAllDecls(@This());
    inline for (comptime std.meta.declarations(registries)) |decl| {
        const T = @field(registries, decl);
        if (@TypeOf(T) == type) _ = std.testing.refAllDecls(T);
    }
}

test isRegistry {
    try std.testing.expect(isRegistry(Registry(struct {}, .registry_type)));
    try std.testing.expect(isRegistry(Registry(u32, .block)));
    try std.testing.expect(isRegistry(Registry(enum { a, b, c }, .@"worldgen/feature")));
}
