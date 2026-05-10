const UUID = @This();
const std = @import("std");

const assert = std.debug.assert;

inline fn compileError(comptime fmt: []const u8, comptime args: anytype, ret: anytype) @TypeOf(ret) {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    }
    return ret;
}

fn hexToNimble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A',
        'a'...'f' => c - 'a',
        else => null,
    };
}

comptime {
    assert(@sizeOf(UUID) == @sizeOf(u128));
}

value: u128,

pub const @"null" = UUID{ .value = 0 };
pub const stringified_length = 36;

pub const HashCtx = struct {
    pub fn hash(_: HashCtx, uuid: UUID) u64 {
        return std.hash.Wyhash.hash(0, @ptrCast(&uuid));
    }
    pub fn eql(_: HashCtx, a: UUID, b: UUID) bool {
        return a.eql(b);
    }
};

pub fn from(v: u128) UUID {
    return .{ .value = v };
}

pub fn parse(str: *const [stringified_length]u8) error{InvalidCharacter}!UUID {
    const sections: [5][2]usize = .{
        .{ 0, 8 },
        .{ 9, 13 },
        .{ 14, 18 },
        .{ 19, 23 },
        .{ 24, 36 },
    };

    var bytes: [@sizeOf(UUID)]u8 = undefined;
    inline for (sections, 0..) |sec, j| {
        const pairs: *const [sec[1] - sec[0]][2]u16 = @ptrCast(str[sec[0]..sec[1]]);
        inline for (pairs, sec[0]..) |c, i| {
            const high = hexToNimble(c[0]);
            const low = hexToNimble(c[1]);
            if (high == null or low == null) compileError(
                "Invalid byte: {s}\x1b[31m{s}\x1b[0m{s}",
                .{ str[0..i], str[i .. i + 2], str[i + 2 ..] },
                error.InvalidCharacter,
            );
            bytes[j + i - sec[0]] = (high.? << 8) | low.?;
        }
    }

    return @bitCast(bytes);
}

pub fn stringify(self: UUID, out: *[stringified_length]u8) void {
    var fbw = std.Io.Writer.fixed(out);
    self.format(&fbw) catch unreachable;
}
pub fn eql(a: UUID, b: UUID) bool {
    return a.value == b.value;
}

pub fn format(self: UUID, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        (self.value >> 96) & 0xFFFFFFFF,
        (self.value >> 80) & 0xFFFF,
        (self.value >> 64) & 0xFFFF,
        (self.value >> 48) & 0xFFFF,
        self.value & 0xFFFFFFFFFFFF,
    });
}

pub fn jsonStringify(self: UUID, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginWriteRaw();
    defer jw.endWriteRaw();

    var buffer: [stringified_length]u8 = undefined;
    var vecs = [_][]const u8{ "\"", &buffer, "\"" };

    self.stringify(&buffer);
    try jw.writer.writeVecAll(&vecs);
}

pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !UUID {
    const str = switch (try source.nextAllocMax(
        allocator,
        .alloc_if_needed,
        options.max_value_len orelse std.math.maxInt(usize),
    )) {
        .string, .allocated_string => |s| s,
        else => return error.UnexpectedToken,
    };

    if (str.len != stringified_length) return error.LengthMismatch;

    return parse(str[0..stringified_length]);
}
