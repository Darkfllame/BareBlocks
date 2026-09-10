const Identifier = @This();
const std = @import("std");
const serial = @import("serial");

const json = std.json;
const MapWriter = serial.MapWriter;
const MapReader = serial.MapReader;

namespace_ptr: [*]const u8,
path_ptr: [*]const u8,
namespace_len: u16,
path_len: u16,

pub const ValidationError = error{
    SeparatorNotFound,
    InvalidCharacter,
    NamespaceTooLong,
    PathTooLong,
};

pub const HashCtx = struct {
    pub fn hash(_: HashCtx, id: Identifier) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(id.namespace());
        hasher.update(id.path());
        return hasher.final();
    }
    pub fn eql(_: HashCtx, a: Identifier, b: Identifier) bool {
        return a.eql(b);
    }
};

pub const Alt = struct {
    id: Identifier,
    mode: Mode,

    pub const Mode = enum { full, omit_minecraft };

    pub fn format(self: Alt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        sw: switch (self.mode) {
            .full => try writer.print("{s}:{s}", .{ self.id.namespace(), self.id.path() }),
            .omit_minecraft => {
                if (std.mem.eql(u8, self.id.namespace(), "minecraft")) {
                    try writer.writeAll(self.id.path());
                } else continue :sw .full;
            },
        }
    }
};

pub fn namespace(self: Identifier) []const u8 {
    return self.namespace_ptr[0..self.namespace_len];
}

pub fn path(self: Identifier) []const u8 {
    return self.path_ptr[0..self.path_len];
}

pub fn dupe(self: Identifier, allocator: std.mem.Allocator) std.mem.Allocator.Error!Identifier {
    const duped = try allocator.alloc(u8, self.namespace_len + self.path_len);
    @memcpy(duped[0..self.namespace_len], self.namespace_ptr);
    @memcpy(duped[self.namespace_len..], self.path_ptr);
    return .{
        .namespace_ptr = duped.ptr,
        .path_ptr = duped.ptr + self.namespace_len,
        .namespace_len = self.namespace_len,
        .path_len = self.path_len,
    };
}

/// Slice `id` must be valid for the whole use of this Identifier.
pub fn validate(id: []const u8) ValidationError!Identifier {
    var colon_idx: ?usize = null;
    for (id, 0..) |c, i| switch (c) {
        ':' => {
            if (i > std.math.maxInt(@FieldType(Identifier, "namespace_len")))
                return error.NamespaceTooLong;
            colon_idx = i;
        },
        '0'...'9', 'a'...'z', '-', '.', '_' => continue,
        else => if (colon_idx == null or c != '/') {
            if (@inComptime()) {
                @compileError(std.fmt.comptimePrint("Invalid character in id: {s}\x1b[31m{s}\x1b[39m{s}", .{
                    id[0 .. i - 1], id[i .. i + 1], id[i + 1 ..],
                }));
            }
            return error.InvalidCharacter;
        } else continue,
    };
    var path_off = colon_idx orelse {
        return error.SeparatorNotFound;
    };
    path_off += 1;
    if (id.len - path_off > std.math.maxInt(@FieldType(Identifier, "path_len")))
        return error.PathTooLong;

    return .{
        .namespace_ptr = id.ptr,
        .namespace_len = @intCast(path_off - 1),
        .path_ptr = id.ptr + path_off,
        .path_len = @intCast(id.len - path_off),
    };
}

pub inline fn literal(comptime id: []const u8) Identifier {
    comptime {
        @setEvalBranchQuota(id.len * 100);
        return validate(id) catch unreachable;
    }
}

pub inline fn vanilla(comptime _path: []const u8) Identifier {
    comptime return if (std.mem.startsWith(u8, _path, "minecraft:"))
        literal(_path)
    else
        literal("minecraft:" ++ _path);
}

pub fn format(self: Identifier, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Identifier({s}:{s})", .{ self.namespace(), self.path() });
}

pub fn alt(self: Identifier, mode: Alt.Mode) Alt {
    return .{ .id = self, .mode = mode };
}

pub fn eql(a: Identifier, b: Identifier) bool {
    return std.mem.eql(u8, a.namespace(), b.namespace()) and
        std.mem.eql(u8, a.path(), b.path());
}

pub fn deserialize(mapr: *MapReader) MapReader.ReadError!Identifier {
    const tok_cpy = try mapr.nextDupeExpectString();
    errdefer mapr.getArena().free(tok_cpy);

    return validate(tok_cpy) catch error.UnexpectedToken;
}

pub fn serialize(self: Identifier, mapw: *MapWriter) MapWriter.WriteError!void {
    const w = try mapw.stringWriter(self.namespace_len + self.path_len + 1, &.{});
    try w.print("{s}:{s}", .{ self.namespace(), self.path() });
    try w.flush();
}

test {
    std.testing.refAllDecls(@This());
}
