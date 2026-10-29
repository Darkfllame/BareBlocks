const RegistriesReport = @This();
const std = @import("std");
const serial = @import("serial");
const utils = @import("utils");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const IdentifierList = @import("../gen_data.zig").IdentifierList;

entries: IdentifierList(Registry),

pub const Registry = struct { default: ?u32, entries: IdentifierList(void) };

pub fn deserialize(mapr: *serial.MapReader) !RegistriesReport {
    const gpa = mapr.getArena();
    const arena = mapr.getArena();
    try mapr.nextExpect(.aggregate_start);

    var self: RegistriesReport = .{ .entries = .{} };
    try self.entries.ensureTotalCapacity(arena, 128);

    while (true) {
        switch (try mapr.peek()) {
            .string => {},
            .aggregate_end => {
                _ = mapr.next() catch unreachable;
                break;
            },
            else => return error.UnexpectedToken,
        }
        const registry_id = try utils.Identifier.deserialize(mapr);

        var fg = serial.FieldGatherer(&.{
            .{ .name = "entries", .type = .{ .external = IdentifierList(void) } },
            .{ .name = "protocol_id", .type = .int },
            .{ .name = "default", .type = .{ .deserializeable = utils.Identifier } },
        }){ .opts = .{ .ignore_unknown_fields = false } };
        defer fg.deinit(gpa);

        try mapr.nextExpect(.aggregate_start);
        while (try fg.next(gpa, arena, mapr)) |field| {
            // std.log.debug("registries.{f}.{t}", .{ registry_id.alt(.full), field });
            switch (field) {
                .entries => {
                    var values = IdentifierList(void){};

                    try mapr.nextExpect(.aggregate_start);
                    while (true) {
                        switch (try mapr.peek()) {
                            .string => {},
                            .aggregate_end => {
                                _ = mapr.next() catch unreachable;
                                break;
                            },
                            else => return error.UnexpectedToken,
                        }
                        const entry_id = try utils.Identifier.deserialize(mapr);

                        var entry_fg = serial.FieldGatherer(&.{
                            .{ .name = "protocol_id", .type = .int },
                        }){ .opts = .{ .ignore_unknown_fields = false } };
                        defer entry_fg.deinit(gpa);

                        try mapr.nextExpect(.aggregate_start);

                        while (try entry_fg.next(gpa, arena, mapr)) |field2| switch (field2) {
                            .protocol_id => {
                                const val = entry_fg.get(.protocol_id) catch unreachable;
                                if (val < 0 or val > std.math.maxInt(u32)) return error.Overflow;
                            },
                            _ => {},
                        };

                        try values.set(arena, entry_id, @intCast(try entry_fg.get(.protocol_id)), {});
                    }

                    fg.set(.entries, values);
                },
                inline .protocol_id => |tag| {
                    const val = fg.get(tag) catch unreachable;
                    if (val < 0 or val > std.math.maxInt(u32)) return error.Overflow;
                },
                .default => {},
                _ => {},
            }
        }

        const entries: IdentifierList(void) = try fg.get(.entries);
        const idn: u32 = @intCast(try fg.get(.protocol_id));
        try self.entries.set(arena, registry_id, idn, .{
            .entries = entries,
            .default = if (fg.getNullable(.default)) |v|
                entries.map.get(v) orelse return error.MissingField
            else
                null,
        });
    }

    return self;
}
