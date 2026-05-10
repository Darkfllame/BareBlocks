const Identifier = @This();
const std = @import("std");

const json = std.json;

id: []const u8,
sep_offset: usize,

pub const HashCtx = struct {
    pub fn hash(_: HashCtx, id: Identifier) u64 {
        return std.hash.Wyhash.hash(0, id.id);
    }
    pub fn eql(_: HashCtx, a: Identifier, b: Identifier) bool {
        return a.eql(b);
    }
};

pub const ValidationError = error{
    SeparatorNotFound,
    InvalidCharacter,
};

pub fn namespace(self: Identifier) []const u8 {
    return self.id[0..self.sep_offset];
}

pub fn path(self: Identifier) []const u8 {
    return self.id[self.sep_offset + 1 ..];
}

pub fn dupe(self: Identifier, allocator: std.mem.Allocator) std.mem.Allocator.Error!Identifier {
    return .{
        .id = try allocator.dupe(u8, self.id),
        .sep_offset = self.sep_offset,
    };
}

/// Slice `id` must be valid for the whole use of this Identifier.
pub fn validate(id: []const u8) ValidationError!Identifier {
    var colon_idx: ?usize = null;
    for (id, 0..) |c, i| switch (c) {
        ':' => colon_idx = i,
        '0'...'9', 'a'...'z', '-', '.', '_' => continue,
        else => if (@intFromBool(c == '/') ^ @intFromBool(colon_idx == null) == 0)
            return error.InvalidCharacter
        else
            continue,
    };

    return if (colon_idx) |sepoff| .{
        .id = id,
        .sep_offset = sepoff,
    } else error.SeparatorNotFound;
}

pub inline fn validateComptime(comptime id: []const u8) Identifier {
    comptime {
        @setEvalBranchQuota(id.len * 100);
        var colon_idx: ?usize = null;
        for (id, 0..) |c, i| switch (c) {
            ':' => colon_idx = i,
            '0'...'9', 'a'...'z', '-', '.', '_' => continue,
            else => if (@intFromBool(c == '/') ^ @intFromBool(colon_idx == null) == 0)
                @compileError(std.fmt.comptimePrint(
                    "Invalid character in identifier: {s}\x1b[31m{c}\x1b[0m{s}",
                    .{ id[0..i], id[i], id[i + 1 ..] },
                ))
            else
                continue,
        };

        return if (colon_idx) |sepoff| .{
            .id = id,
            .sep_offset = sepoff,
        } else @compileError("Colon character not found in '" ++ id ++ "'");
    }
}

pub inline fn vanilla(comptime _path: []const u8) Identifier {
    return comptime if (std.mem.startsWith(u8, _path, "minecraft:"))
        validateComptime(_path)
    else
        validateComptime("minecraft:" ++ _path);
}

pub fn format(self: Identifier, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Identifier({s}, {s})", .{ self.namespace(), self.path() });
}

pub fn eql(a: Identifier, b: Identifier) bool {
    return std.mem.eql(u8, a.id, b.id);
}

pub fn jsonStringify(self: Identifier, jw: *json.Stringify) json.Stringify.Error!void {
    try jw.beginWriteRaw();
    defer jw.endWriteRaw();

    try jw.writer.print("\"{s}\"", .{self.id});
}

pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Identifier {
    const str = switch (try source.nextAllocMax(
        allocator,
        .alloc_if_needed,
        options.max_value_len orelse std.math.maxInt(usize),
    )) {
        .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };

    return validate(str) catch |err| switch (err) {
        error.SeparatorNotFound => error.LengthMismatch,
        error.InvalidCharacter => error.InvalidCharacter,
    };
}
