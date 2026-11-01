const registry = @This();
const std = @import("std");
const utils = @import("utils");
const registries = @import("registries");

const Allocator = std.mem.Allocator;
const Identifier = utils.Identifier;
const ArenaState = std.heap.ArenaAllocator.State;
const assert = std.debug.assert;

const logger = std.log.scoped(.@"bare_blocks/registry");

pub const max_registry_id = std.math.maxInt(i32);

pub const RegistryType = registries.RegistryType;
pub const BuiltinRegistry = registries.BuiltinRegistry;

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
        copy_id: bool = true,

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
        copy_ids: bool = true,
    };

    pub const RegisterManyEntry = struct {
        id: Identifier,
        nid: ?RegistryEntryId = null,
        value: *anyopaque,
    };

    pub const Dynamic = struct {
        type_erased: TypeErasedRegistry,
        arena_state: ArenaState = .init,

        pub const RegisterOptions = struct {
            gpa: Allocator,
            id: Identifier,
            nid: ?RegistryEntryId = null,

            pub fn named(gpa: Allocator, id: Identifier) Dynamic.RegisterOptions {
                return .{ .gpa = gpa, .id = id };
            }
            pub fn namedNumeric(gpa: Allocator, id: Identifier, nid: RegistryEntryId) Dynamic.RegisterOptions {
                return .{ .gpa = gpa, .id = id, .nid = nid };
            }

            pub fn fromManyOptions(m: Dynamic.RegisterManyOptions, id: Identifier) Dynamic.RegisterOptions {
                return .{ .gpa = m.gpa, .arena = m.arena, .id = id };
            }

            pub fn fromManyOptionsNumeric(m: Dynamic.RegisterManyOptions, id: Identifier, nid: RegistryEntryId) Dynamic.RegisterOptions {
                return .{ .gpa = m.gpa, .arena = m.arena, .id = id, .nid = nid };
            }
        };

        pub const RegisterManyOptions = struct { gpa: Allocator };

        pub fn new() TypeErasedRegistry.Dynamic {
            return .{ .type_erased = .{} };
        }

        pub fn deinit(self: *Dynamic, gpa: Allocator) void {
            self.type_erased.deinit(gpa);
            self.arena_state.promote(gpa).deinit();
        }

        pub fn clearRetainingCapacity(self: *Dynamic, gpa: Allocator) void {
            self.type_erased.clearRetainingCapacity();
            _ = self.arena_state.promote(gpa).reset(.retain_capacity);
        }

        pub inline fn freeze(self: *Dynamic) void {
            self.type_erased.freeze();
        }

        pub inline fn register(self: *Dynamic, options: Dynamic.RegisterOptions, value: *anyopaque) RegisterError!RegistryEntryId {
            var out: RegistryEntryId = undefined;
            try self.registerInto(options, value, &out);
            return out;
        }

        pub inline fn registerInto(self: *Dynamic, options: Dynamic.RegisterOptions, value: *anyopaque, out: *RegistryEntryId) RegisterError!void {
            return self.registerMany(.{ .gpa = options.gpa }, &.{.{
                .id = options.id,
                .nid = options.nid,
                .value = value,
            }}, out[0..1]);
        }

        pub fn registerMany(self: *Dynamic, options: Dynamic.RegisterManyOptions, entries: []const RegisterManyEntry, out: []RegistryEntryId) RegisterError!void {
            var aa = self.arena_state.promote(options.gpa);
            defer self.arena_state = aa.state;

            return self.type_erased.registerMany(.{ .gpa = options.gpa, .arena = aa.allocator() }, entries, out);
        }

        pub inline fn getEntry(self: *Dynamic, nid: RegistryEntryId) ?*anyopaque {
            return self.type_erased.getEntry(nid);
        }

        pub inline fn getNamedEntry(self: *Dynamic, id: Identifier) ?*anyopaque {
            return self.type_erased.getNamedEntry(id);
        }
    };

    pub fn new() TypeErasedRegistry {
        return .{};
    }

    pub fn deinit(self: *TypeErasedRegistry, gpa: Allocator) void {
        self.nid_mask.deinit(gpa);
        self.id2num.deinit(gpa);
        gpa.free(self.ids);
        gpa.free(self.data);
    }

    pub fn clearRetainingCapacity(self: *TypeErasedRegistry) void {
        self.frozen = false;
        self.nid_mask.unsetAll();
        self.nid_continuous = 0;
        self.id2num.clearRetainingCapacity();
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
            .{
                .gpa = options.gpa,
                .arena = options.arena,
                .copy_ids = options.copy_id,
            },
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

        if (options.copy_ids) {
            var id_len: usize = 0;
            for (entries) |entry| {
                id_len, const ov = @addWithOverflow(id_len, entry.id.dupeLen());
                if (ov == 1) return error.OutOfMemory;
            }
            options.arena.free(try options.arena.alloc(u8, id_len));
        }

        for (entries, out) |entry, *nid_out| {
            const id = if (options.copy_ids) try entry.id.dupe(options.arena) else entry.id;

            logger.debug("Setting id {?d} to {f}", .{ entry.nid, id.alt(.omit_minecraft) });
            nid_out.* = if (entry.nid) |nid|
                try self.newNumericIdFixed(options.gpa, nid, id)
            else
                try self.newNumericId(options.gpa, id);
            const idx = @backingInt(nid_out.*);
            logger.debug("  - Set id {d} to {f}", .{ idx, id.alt(.omit_minecraft) });
            self.id2num.putAssumeCapacityNoClobber(id, idx);
            self.data[idx] = entry.value;
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

// TODO: 1 arena for all static registries.
// TODO: 1 arena per dynamic registry.
// TODO:   - Same for tags registries.
pub const RootRegistry = struct {
    const props = registries.properties;
    const props_calc = blk: {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var fixed_buf: [props.keys().len]?RegistryEntryId = @splat(null);
        var _max_id_len: usize = 0;

        var fixed_arr = std.ArrayList(?RegistryEntryId).initBuffer(&fixed_buf);
        var dynamic_count: usize = 0;

        for (props.keys()) |key| {
            const id = Identifier.validate(key) catch unreachable;
            const id_s = std.fmt.comptimePrint("{f}", .{id.alt(.omit_minecraft)});
            _max_id_len = @max(_max_id_len, std.fmt.count("{f}", .{id.alt(.full)}));
            if (std.meta.stringToEnum(BuiltinRegistry, id_s)) |val| {
                fixed_arr.appendAssumeCapacity(@fromBackingInt(@backingInt(val)));
            } else {
                dynamic_count += 1;
            }
        }
        const c_nids = fixed_arr.items.* ++ @as([dynamic_count]?RegistryEntryId, @splat(null));
        break :blk .{ &c_nids, _max_id_len };
    };
    const nids = props_calc[0];
    const max_id_len = props_calc[1];

    fn freeAtIndex(self: *RootRegistry, gpa: Allocator, buf: []u8, idx: usize) !void {
        const id = self.type_erased.ids[idx];
        const id_s = try std.mem.print(buf, "{f}", .{id.alt(.full)});
        const entry_props = props.get(id_s) orelse return error.IdkThisGuy; // #ref #tuff #jjs #imgoingmadithink
        const reg: *TypeErasedRegistry = @ptrCast(@alignCast(self.type_erased.data[idx]));
        if (entry_props.dynamic) {
            const dreg: *TypeErasedRegistry.Dynamic = @fieldParentPtr("type_erased", reg);
            dreg.deinit(gpa);
        } else {
            reg.deinit(gpa);
        }
    }

    allocator: Allocator,
    static_arena: ArenaState = .init,
    type_erased: TypeErasedRegistry = .{},

    pub fn init(gpa: Allocator) TypeErasedRegistry.RegisterError!RootRegistry {
        var self = RootRegistry{ .allocator = gpa };

        var aa = self.static_arena.promote(gpa);
        // defer self.static_arena = aa.state; // So this causes a memory leak work somehow ????
        errdefer aa.deinit();

        const arena = aa.allocator();

        try self.type_erased.resizeIfNeeded(gpa, props.keys().len);
        errdefer self.type_erased.deinit(gpa);

        for (nids, props.keys(), props.values()) |nid, key, value| {
            const ptr = blk: {
                if (value.dynamic) {
                    const dreg = try arena.create(TypeErasedRegistry.Dynamic);
                    dreg.* = .new();
                    break :blk &dreg.type_erased;
                } else {
                    const reg = try arena.create(TypeErasedRegistry);
                    reg.* = .new();
                    break :blk reg;
                }
            };

            _ = try self.type_erased.register(.{
                .gpa = gpa,
                .arena = arena,
                .id = Identifier.validate(key) catch unreachable,
                .nid = nid,
                .copy_id = false,
            }, ptr);
        }

        self.type_erased.freeze();
        self.static_arena = aa.state;

        return self;
    }

    pub fn deinit(self: *RootRegistry, gpa: Allocator) void {
        var buf: [max_id_len]u8 = undefined;
        var it = self.type_erased.id2num.valueIterator();
        while (it.next()) |idx| {
            const id = self.type_erased.ids[idx.*];
            self.freeAtIndex(gpa, &buf, idx.*) catch |err| {
                logger.warn("I don't know what is RootRegistry[{f}] ({t})", .{ id.alt(.omit_minecraft), err });
            };
        }
        self.type_erased.deinit(gpa);
        self.static_arena.promote(gpa).deinit();
    }

    pub fn get(self: *RootRegistry, comptime T: type, typ: RegistryType) ?*Registry(T) {
        const id = Identifier.validate(typ.getIdentifier()) catch unreachable;
        const _props = typ.getProperties();
        if (_props.dynamic) {
            logger.err("Registry {f} is not static", .{id.alt(.full)});
            return null;
        }
        return @ptrCast(@alignCast(self.type_erased.getNamedEntry(id)));
    }

    pub fn getDynamic(self: *RootRegistry, comptime T: type, typ: RegistryType) ?*DynamicRegistry(T) {
        const id = Identifier.validate(typ.getIdentifier()) catch unreachable;

        const _props = typ.getProperties();
        if (!_props.dynamic) {
            logger.err("Registry {f} is not dynamic", .{id.alt(.full)});
            return null;
        }
        const ptr: *TypeErasedRegistry = @ptrCast(@alignCast(self.type_erased.getNamedEntry(id) orelse return null));
        return @fieldParentPtr("type_erased", ptr);
    }
};

pub fn Registry(comptime SubType: type) type {
    return struct {
        const Self = @This();

        comptime SubType: type = SubType,
        type_erased: TypeErasedRegistry = .new(),

        pub fn new() Self {
            return .{};
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.type_erased.deinit(gpa);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.type_erased.clearRetainingCapacity();
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

pub fn DynamicRegistry(comptime SubType: type) type {
    return struct {
        const Self = @This();

        comptime SubType: type = SubType,
        type_erased: TypeErasedRegistry.Dynamic = .new(),

        pub fn new() Self {
            return .{};
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.type_erased.deinit(gpa);
        }

        pub fn clearRetainingCapacity(self: *Self, gpa: Allocator) void {
            self.type_erased.clearRetainingCapacity(gpa);
        }

        pub inline fn freeze(self: *Self) void {
            return self.type_erased.freeze();
        }

        pub inline fn register(self: *Self, options: TypeErasedRegistry.Dynamic.RegisterOptions, value: *SubType) TypeErasedRegistry.RegisterError!RegistryEntryId {
            return self.type_erased.register(options, value);
        }

        pub inline fn registerInto(self: *Self, options: TypeErasedRegistry.Dynamic.RegisterOptions, value: *SubType, out: *RegistryEntryId) TypeErasedRegistry.RegisterError!void {
            return self.type_erased.registerInto(options, value, out);
        }

        pub inline fn registerMany(self: *Self, options: TypeErasedRegistry.Dynamic.RegisterManyOptions, entries: []const TypeErasedRegistry.RegisterManyEntry, out: []RegistryEntryId) TypeErasedRegistry.RegisterError!void {
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
    comptime return @hasField(T, "SubType") and
        @FieldType(T, "SubType") == type and
        T == Registry(@as(T, undefined).SubType);
}

comptime {
    const types2test: []const type = &.{ u32, void, struct { []const u8, u32 } };

    for (types2test) |T| {
        std.debug.assert(@sizeOf(TypeErasedRegistry), @sizeOf(Registry(T)));
        std.debug.assert(@sizeOf(TypeErasedRegistry.Dynamic), @sizeOf(DynamicRegistry(T)));
    }
}

test {
    std.testing.refAllDecls(@This());
    inline for (comptime std.meta.declarations(registries)) |decl| {
        const T = @field(registries, decl);
        if (@TypeOf(T) == type) _ = std.testing.refAllDecls(T);
    }
}

test isRegistry {
    try std.testing.expect(isRegistry(Registry(struct {})));
    try std.testing.expect(isRegistry(Registry(u32)));
    try std.testing.expect(isRegistry(Registry(enum { a, b, c })));
}
