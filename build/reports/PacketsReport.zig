const PacketsReport = @This();
const std = @import("std");
const net = @import("net");
const utils = @import("utils");
const serial = @import("serial");

const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const IdentifierList = @import("../gen_data.zig").IdentifierList;

fn parsePhase(self: *PacketsReport, phase: net.NetworkingPhase, mapr: *serial.MapReader) !void {
    try mapr.nextExpect(.aggregate_start);
    while (true) {
        // std.log.debug("Next phase name: {t}", .{try mapr.peek()});
        const side: net.NetworkingSide = switch (try mapr.next()) {
            .string => |name| if (std.mem.eql(u8, name, "clientbound"))
                .client
            else if (std.mem.eql(u8, name, "serverbound"))
                .server
            else
                return error.UnknownField,
            .aggregate_end => break,
            else => return error.UnexpectedToken,
        };

        const list = self.ids.getPtr(side).getPtr(phase);
        list.clearRetainingCapacity();

        // std.log.debug("Packets.{t}.{t}", .{ side, phase });
        try self.parseSide(list, mapr);
        // std.log.debug("End of Packets.{t}.{t}", .{ side, phase });
    }
}

fn parseSide(self: *PacketsReport, list: *IdentifierList(void), mapr: *serial.MapReader) !void {
    _ = self; // autofix
    const gpa = mapr.getAlloctor();
    const arena = mapr.getArena();

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
        const id = try utils.Identifier.deserialize(mapr);
        // std.log.debug("- {f}", .{id.alt(.full)});

        var fg = serial.FieldGatherer(&.{
            .{ .name = "protocol_id", .type = .int },
        }){};
        defer fg.deinit(gpa);

        try mapr.nextExpect(.aggregate_start);
        while (try fg.next(gpa, arena, mapr)) |field2| switch (field2) {
            .protocol_id => {
                const val = fg.get(.protocol_id) catch unreachable;
                if (val < 0 or val > std.math.maxInt(u32)) return error.Overflow;
            },
            _ => {},
        };
        // std.log.debug("  - End of {f}", .{id.alt(.full)});

        try list.set(arena, id, @intCast(try fg.get(.protocol_id)), {});
    }
}

ids: std.EnumArray(net.NetworkingSide, std.EnumArray(net.NetworkingPhase, IdentifierList(void))),

pub fn deserialize(mapr: *serial.MapReader) !PacketsReport {
    try mapr.nextExpect(.aggregate_start);

    var self: PacketsReport = .{ .ids = .initFill(.initFill(.{})) };

    while (true) {
        const tok = try mapr.next();
        switch (tok) {
            .string => {},
            .aggregate_end => break,
            else => return error.UnexpectedToken,
        }

        // std.log.debug("phase token {f}", .{tok});
        const phase = tok.parseEnum(net.NetworkingPhase) orelse {
            try mapr.skipValue();
            continue;
        };

        try self.parsePhase(phase, mapr);
        // std.log.debug("End of phase {t}", .{phase});
    }

    return self;
}
