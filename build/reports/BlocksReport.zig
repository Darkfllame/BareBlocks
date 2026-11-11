const BlocksReport = @This();
const std = @import("std");
const serial = @import("serial");
const utils = @import("utils");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Identifier = utils.Identifier;

/// Properties are identified by their name *and* their values, names alone aren't unique.
/// e.g. `facing` is 3 different properties (horizontal, all 6 directions and the hopper one).
pub const Property = struct {
    pub const Data = union(enum) {
        bool,
        /// Always linear and ascending.
        integer: []const i32,
        enumeration: std.StringArrayHashMapUnmanaged(void),
    };

    pub const Kind = @typeInfo(Data).@"union".tag_type.?;

    const HashCtx = struct {
        pub fn hash(_: HashCtx, a: *const Property) u64 {
            var wh = std.hash.Wyhash.init(0);
            wh.update(a.name);
            wh.update(@tagName(a.data));
            switch (a.data) {
                .bool => {},
                .integer => |ints| wh.update(std.mem.sliceAsBytes(ints)),
                .enumeration => |values| for (values.keys()) |value| {
                    wh.update(value);
                    wh.update(&.{0}); // so ["ab", "c"] and ["a", "bc"] don't hash the same
                },
            }
            return wh.final();
        }

        pub fn eql(_: HashCtx, a: *const Property, b: *const Property) bool {
            if (a == b) return true;
            if (!std.mem.eql(u8, a.name, b.name) or @as(Kind, a.data) != @as(Kind, b.data)) return false;
            return switch (a.data) {
                .bool => true,
                .integer => |ints| std.mem.eql(i32, ints, b.data.integer),
                .enumeration => |values| {
                    const a_keys = values.keys();
                    const b_keys = b.data.enumeration.keys();
                    if (a_keys.len != b_keys.len) return false;
                    for (a_keys, b_keys) |ak, bk| {
                        if (!std.mem.eql(u8, ak, bk)) return false;
                    }
                    return true;
                },
            };
        }
    };

    name: []const u8,
    data: Data,
};

pub const State = struct {
    owner_id: utils.Identifier,
    id: u32,
    default: bool,
    /// Which field is active depends on the kind of the owner's property with the same name.
    properties: std.StringHashMapUnmanaged(union { bool: bool, integer: i32, enumeration: []const u8 }),
};

pub const Entry = struct {
    /// NOTE: State ids are ordered by the property names sorted alphabetically, the last one
    /// NOTE: changing the fastest. Not by the order in blocks.json (chests and pistons list `type` first).
    properties: std.StringHashMapUnmanaged(*const Property),
    states: []const *const State,
};

fn statesGrow(self: *BlocksReport, arena: Allocator, new_len: usize) !void {
    if (self.states_data.len < new_len) {
        const old_len = self.states_data.len;
        self.states_data = try arena.realloc(self.states_data, @max(new_len, old_len * 2));
        @memset(self.states_data[old_len..], undefined);
    }
    if (self.states_mask.bit_length < self.states_data.len) {
        try self.states_mask.resize(arena, self.states_data.len, false);
    }
}

fn parseProperties(self: *BlocksReport, mapr: *serial.MapReader, entry: *Entry) !void {
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const name = (try mapr.nextExpectFieldName()) orelse break;

        var values = std.ArrayList([]const u8).empty;
        defer values.deinit(gpa);

        _ = try mapr.nextExpect(.array_start);
        while (true) {
            const v = switch (try mapr.next()) {
                .string => |s| try arena.dupe(u8, s),
                .array_end => break,
                else => return error.UnexpectedToken,
            };

            try values.append(gpa, v);
        }

        const kind: Property.Kind = blk: {
            // Checks whether the property is a bool, integer or enum

            if (values.items.len == 2) {
                var has_false: bool = false;
                var has_true: bool = false;
                for (values.items) |val| {
                    if (std.mem.eql(u8, val, "false")) {
                        has_false = true;
                    } else if (std.mem.eql(u8, val, "true")) {
                        has_true = true;
                    } else break;
                }
                if (has_false and has_true) break :blk .bool;
            }
            // If any of the property values cannot parse to an int, it's probably an enum)
            for (values.items) |value| {
                _ = std.fmt.parseInt(i32, value, 10) catch break :blk .enumeration;
            }
            break :blk .integer;
        };

        var prop: Property = .{ .name = name, .data = undefined };
        switch (kind) {
            .bool => prop.data = .bool,
            .integer => {
                var ints = try std.ArrayList(i32).initCapacity(arena, values.items.len);
                for (values.items) |sval| {
                    const val = std.fmt.parseInt(i32, sval, 10) catch unreachable;
                    if (ints.getLastOrNull()) |lv| {
                        // Always linear
                        if (val != (lv + 1)) return error.UnexpectedToken; // TODO: Add new error code ? Some SchemaMismatch or sum
                    }
                    ints.appendAssumeCapacity(val);
                }
                prop.data = .{ .integer = ints.items };
            },
            .enumeration => {
                var names = std.StringArrayHashMapUnmanaged(void).empty;
                try names.ensureTotalCapacity(arena, values.items.len);
                for (values.items) |sval| {
                    const egop = names.getOrPutAssumeCapacity(sval);
                    if (egop.found_existing) return error.DuplicateField;
                }
                prop.data = .{ .enumeration = names };
            },
        }

        // Check existing property or make a new one
        const gop = try self.all_properties.getOrPut(arena, &prop);
        if (!gop.found_existing) {
            const ptr = try arena.create(Property);
            ptr.* = prop;
            gop.key_ptr.* = ptr;
        }

        const egop = try entry.properties.getOrPut(arena, name);
        if (egop.found_existing) return error.DuplicateField;
        egop.value_ptr.* = gop.key_ptr.*;
    }
}

fn parseState(self: *BlocksReport, id: Identifier, mapr: *serial.MapReader, entry: *const Entry) !*const State {
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    const state = try arena.create(State);
    state.* = .{
        .owner_id = id,
        .id = undefined,
        .default = false,
        .properties = .empty,
    };
    try state.properties.ensureTotalCapacity(arena, entry.properties.count());

    var fg = serial.FieldGatherer(&.{
        .{ .name = "id", .type = .int },
        .{ .name = "default", .type = .boolean },
        .{ .name = "properties", .type = .{ .external = void } },
    }){};
    defer fg.deinit(gpa);

    try mapr.nextExpect(.aggregate_start);
    while (try fg.next(gpa, arena, mapr)) |field| switch (field) {
        .properties => {
            try mapr.nextExpect(.aggregate_start);
            while (true) {
                const field_name = (try mapr.nextExpectFieldName()) orelse break;
                // Use the entry's string, no need for a copy per state
                const name = entry.properties.getKey(field_name) orelse return error.UnknownField;
                const prop = entry.properties.get(name).?;
                const value = try mapr.nextExpect(.string);

                const sgop = state.properties.getOrPutAssumeCapacity(name);
                if (sgop.found_existing) return error.DuplicateField;
                sgop.value_ptr.* = switch (prop.data) {
                    .bool => .{ .bool = if (std.mem.eql(u8, value, "true"))
                        true
                    else if (std.mem.eql(u8, value, "false"))
                        false
                    else
                        return error.UnexpectedToken },
                    .integer => |ints| blk: {
                        const val = std.fmt.parseInt(i32, value, 10) catch return error.UnexpectedToken;
                        if (val < ints[0] or val > ints[ints.len - 1]) return error.Overflow;
                        break :blk .{ .integer = val };
                    },
                    // Use the property's string so they're all the same pointer
                    .enumeration => |names| .{ .enumeration = names.getKey(value) orelse return error.InvalidEnumTag },
                };
            }
        },
        else => continue,
    };

    if (state.properties.count() != entry.properties.count()) return error.MissingField;

    const state_id = try fg.get(.id);
    if (state_id < 0 or state_id > std.math.maxInt(u32)) return error.Overflow;
    state.id = @intCast(state_id);
    state.default = fg.getNullable(.default) orelse false;

    try self.statesGrow(arena, state.id + 1);
    if (self.states_mask.isSet(state.id)) return error.DuplicateField;
    self.states_mask.set(state.id);
    self.states_data[state.id] = state;
    self.states_count += 1;

    return state;
}

fn parseEntry(self: *BlocksReport, id: Identifier, mapr: *serial.MapReader) !void {
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    var entry: Entry = .{ .properties = .empty, .states = &.{} };

    var fg = serial.FieldGatherer(&.{
        .{ .name = "properties", .type = .{ .external = void } },
        .{ .name = "states", .type = .{ .external = void } },
    }){};
    defer fg.deinit(gpa);

    try mapr.nextExpect(.aggregate_start);
    while (try fg.next(gpa, arena, mapr)) |field| switch (field) {
        .properties => try self.parseProperties(mapr, &entry),
        .states => {
            // `properties` comes before `states` in blocks.json, which is needed to parse the states' values.
            var states = std.ArrayList(*const State).empty;
            _ = try mapr.nextExpect(.array_start);
            while (try mapr.peek() != .array_end) {
                try states.append(arena, try self.parseState(id, mapr, &entry));
            }
            _ = try mapr.nextExpect(.array_end);
            entry.states = states.items;
        },
        _ => continue,
    };

    if (entry.states.len == 0) return error.MissingField;

    const gop = try self.entries.getOrPut(arena, id);
    if (gop.found_existing) return error.DuplicateField;
    gop.value_ptr.* = entry;
}

/// Which `states_data` elements are set.
states_mask: std.DynamicBitSetUnmanaged,
/// Indexed by state id.
states_data: []*const State,
states_count: usize,
all_properties: std.HashMapUnmanaged(*const Property, void, Property.HashCtx, std.hash_map.default_max_load_percentage),
entries: std.HashMapUnmanaged(Identifier, Entry, Identifier.HashCtx, std.hash_map.default_max_load_percentage),

pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!BlocksReport {
    var self = BlocksReport{
        .states_mask = .{},
        .states_data = &.{},
        .states_count = 0,
        .all_properties = .empty,
        .entries = .empty,
    };

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const s = (try Identifier.deserializeFieldName(mapr)) orelse break;

        try self.parseEntry(s, mapr);
    }

    // State ids must be dense, the protocol relies on it.
    self.states_data = self.states_data[0..self.states_count];
    for (0..self.states_count) |i| {
        if (!self.states_mask.isSet(i)) return error.MissingField;
    }

    return self;
}
