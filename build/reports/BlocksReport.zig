const BlocksReport = @This();
const std = @import("std");
const serial = @import("serial");
const utils = @import("utils");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Identifier = utils.Identifier;

const Property = struct {
    const Data = union(enum) {
        bool,
        integer: []const i32,
        enumeration: std.StringArrayHashMapUnmanaged(void),
    };

    const Kind = @typeInfo(Data).@"union".tag_type.?;

    const HashCtx = struct {
        pub fn hash(_: HashCtx, a: *const Property) u64 {
            var wh = std.hash.Wyhash.init(0);
            wh.update(a.name);
            wh.update(@tagName(a.data));
            switch (a.data) {
                .bool => {},
                .integer => |ints| {
                    var min: i32 = 0;
                    var max: i32 = 0;
                    for (ints) |value| {
                        min = @min(min, value);
                        max = @max(max, value);
                    }
                    wh.update(@ptrCast(&min));
                    wh.update(@ptrCast(&max));
                },
                .enumeration => |values| {
                    for (values.keys()) |value| {
                        _ = value; // autofix
                    }
                },
            }
        }

        pub fn eql(_: HashCtx, a: *const Property, b: *const Property) bool {
            if (a == b) return true;
            if (!std.mem.eql(u8, a.name, b.name) or a.data != b.data) return false;
        }
    };

    name: []const u8,
    data: Data,
};

const State = struct {
    owner_id: utils.Identifier,
    id: u32,
    properties: std.StringHashMapUnmanaged(union { bool: bool, integer: i32, enumeration: []const u8 }),
};

const Entry = struct {
    properties: std.StringHashMapUnmanaged(*const Property),
    states: []const *const State,
};

fn statesGrow(self: *BlocksReport, gpa: Allocator, new_len: usize) !void {
    if (self.states_data.len < new_len) {
        self.states_data = try gpa.realloc(self.states_data, new_len);
    }
    if (self.states_mask.bit_length < new_len) {
        try self.states_mask.resize(gpa, new_len, false);
    }
}

fn parseEntry(self: *BlocksReport, id: Identifier, mapr: *serial.MapReader) !void {
    _ = id; // autofix
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    var fg = serial.FieldGatherer(&.{
        .{ .name = "properties", .type = .{ .external = void } },
        .{ .name = "states", .type = .{ .external = void } },
    }){};
    defer fg.deinit(gpa);

    try mapr.nextExpect(.aggregate_start);
    while (try fg.next(gpa, arena, mapr)) |field| switch (field) {
        .properties => {
            try mapr.nextExpect(.aggregate_start);
            while (true) {
                const name = (try mapr.nextExpectFieldName()) orelse break;

                const gop = try self.all_properties.getOrPut(arena, name);
                const prop_ptr: *Property = if (gop.found_existing) gop.value_ptr.* else blk: {
                    const ptr = try arena.create(Property);
                    gop.value_ptr = ptr;
                    break :blk ptr;
                };

                var values = std.ArrayList([]const u8).empty;
                errdefer values.deinit(gpa);

                _ = try mapr.nextExpect(.array_start);
                while (true) {
                    const v = switch (try mapr.next()) {
                        .string => |s| try arena.dupe(u8, s),
                        .array_end => break,
                        else => return error.UnexpectedToken,
                    };

                    try values.append(gpa, v);
                }

                const Kind = @typeInfo(Property).@"union".tag_type.?;
                const kind: Kind = blk: {
                    // Checks whether the property is a bool, integer or enum

                    if (values.items.len == 2) {
                        var has_false: bool = false;
                        var has_true: bool = false;
                        for (values.items) |val| {
                            if (std.mem.eql(u8, val, "false")) {
                                has_false = true;
                            } else if (std.mem.eql(u8, val, "true")) {
                                has_true = true;
                            } else break :blk .enumeration;
                        }
                        if (!has_false or !has_true) break :blk .enumeration;
                        break :blk .bool;
                    }
                    // If any of the property values cannot parse to an int, it's probably an enum)
                    for (values.items) |value| {
                        _ = std.fmt.parseInt(i32, value, 10) catch break :blk .enumeration;
                    }
                    break :blk .integer;
                };

                // Check existing property or make a new one
                if (gop.found_existing) {
                    if (kind != prop_ptr.*) return error.UnexpectedToken; // TODO: Add new error code ? Some SchemaMismatch or sum

                    switch (prop_ptr.*) {
                        .bool => {},
                        .integer => |ivalues| {
                            if (ivalues.len != values.items.len) return error.LengthMismatch;
                            for (ivalues, values.items) |ivalue, svalue| {
                                const val = std.fmt.parseInt(i32, svalue, 10) catch unreachable;
                                if (ivalue != val) return error.UnexpectedToken; // TODO: Same as above
                            }
                        },
                        .enumeration => |names| {
                            if (names.count() != values.items.len) return error.LengthMismatch;
                            // I love array hash maps :drool:
                            for (names.keys(), values.items) |present, new| {
                                if (!std.mem.eql(u8, present, new)) return error.UnexpectedToken;
                            }
                        },
                    }
                } else switch (kind) {
                    .bool => {},
                    .integer => {
                        var ints = try std.ArrayList(i32).initCapacity(arena, values.items.len);
                        for (values) |sval| {
                            const val = std.fmt.parseInt(i32, sval, 10) catch unreachable;
                            if (ints.last()) |lv| {
                                // Always linear
                                if (val != (lv - 1)) return error.UnexpectedToken;
                            }
                            ints.appendAssumeCapacity(val);
                        }
                        prop_ptr.* = .{ .integer = ints.items };
                    },
                    .enumeration => {
                        var names = std.StringArrayHashMapUnmanaged(void).empty;
                        try names.ensureTotalCapacity(arena, values.items.len);
                        for (values) |sval| {
                            const egop = names.getOrPutAssumeCapacity(sval);
                            if (egop.found_existing) return error.DuplicateField;
                        }
                        prop_ptr.* = .{ .enumeration = names };
                    },
                }
            }
        },
        .states => {
            _ = try mapr.nextExpect(.array_start);
        },
        _ => continue,
    };
}

fn maybeAddProperty(self: *BlocksReport) !void {
    _ = self; // autofix

}

states_mask: std.DynamicBitSetUnmanaged,
states_data: []State,
all_properties: std.HashMapUnmanaged(*const Property, void, Property.HashCtx, std.hash_map.default_max_load_percentage),
entries: std.HashMapUnmanaged(Identifier, Entry, Identifier.HashCtx, std.hash_map.default_max_load_percentage),

pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!BlocksReport {
    var self = BlocksReport{
        .states_mask = .{},
        .states_data = &.{},
        .all_properties = .empty,
        .entries = .empty,
    };

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const s = (try Identifier.deserializeFieldName(mapr)) orelse break;

        try self.parseEntry(s, mapr);
    }

    return self;
}
