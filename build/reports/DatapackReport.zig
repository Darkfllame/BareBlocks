const DatapackReport = @This();
const std = @import("std");
const serial = @import("serial");
const utils = @import("utils");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const IdentifierList = @import("../gen_data.zig").IdentifierList;

fn parseOthers(self: *DatapackReport, mapr: *serial.MapReader) !void {
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    self.others.clearRetainingCapacity();

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const name = switch (try mapr.next()) {
            .string => |s| try arena.dupe(u8, s),
            .aggregate_end => break,
            else => return error.UnexpectedToken,
        };

        var fg = serial.FieldGatherer(&.{
            .{ .name = "format", .type = .{ .enumeration = .{ .type = StructureReportFormat } } },
            .{ .name = "elements", .type = .boolean },
            .{ .name = "stable", .type = .boolean },
            .{ .name = "tags", .type = .boolean },
        }){ .opts = .{ .ignore_unknown_fields = false } };
        defer fg.deinit(gpa);

        try mapr.nextExpect(.aggregate_start);
        while (try fg.next(gpa, arena, mapr)) |_| {}

        const gop = try self.others.getOrPut(arena, name);
        if (gop.found_existing) return error.DuplicateField;
        gop.value_ptr.* = .{
            .format = try fg.get(.format),
            .common = .{
                .dynamic = try fg.get(.elements),
                .stable = try fg.get(.stable),
                .has_tags = try fg.get(.tags),
            },
        };
    }
}

fn parseRegistries(self: *DatapackReport, mapr: *serial.MapReader) !void {
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

    self.registries.clearRetainingCapacity();

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const tok = try mapr.peek();
        switch (tok) {
            .string => {},
            .aggregate_end => {
                _ = mapr.next() catch unreachable;
                break;
            },
            else => return error.UnexpectedToken,
        }
        const name = try utils.Identifier.deserialize(mapr);

        var fg = serial.FieldGatherer(&.{
            .{ .name = "elements", .type = .boolean },
            .{ .name = "stable", .type = .boolean },
            .{ .name = "tags", .type = .boolean },
        }){ .opts = .{ .ignore_unknown_fields = false } };
        defer fg.deinit(gpa);

        try mapr.nextExpect(.aggregate_start);
        while (try fg.next(gpa, arena, mapr)) |_| {}

        const gop = try self.registries.getOrPut(arena, name);
        if (gop.found_existing) return error.DuplicateField;
        gop.value_ptr.* = .{
            .dynamic = try fg.get(.elements),
            .stable = try fg.get(.stable),
            .has_tags = try fg.get(.tags),
        };
    }
}

others: std.StringHashMapUnmanaged(CustomPackEntry),
registries: std.HashMapUnmanaged(utils.Identifier, PackEntry, utils.Identifier.HashCtx, std.hash_map.default_max_load_percentage),

pub const StructureReportFormat = enum { structure, mcfunction };

pub const PackEntry = struct { dynamic: bool, has_tags: bool, stable: bool };
pub const CustomPackEntry = struct { format: StructureReportFormat, common: PackEntry };

pub fn deserialize(mapr: *serial.MapReader) !DatapackReport {
    var self: DatapackReport = .{
        .others = .empty,
        .registries = .{},
    };

    const Field = enum { others, registries };

    try mapr.nextExpect(.aggregate_start);
    while (true) {
        const field = switch (try mapr.next()) {
            .string => |s| std.meta.stringToEnum(Field, s) orelse return error.UnknownField,
            .aggregate_end => break,
            else => return error.UnexpectedToken,
        };

        switch (field) {
            .others => try self.parseOthers(mapr),
            .registries => try self.parseRegistries(mapr),
        }
    }

    return self;
}
