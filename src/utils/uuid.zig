const std = @import("std");
const utils = @import("utils.zig");

const assert = std.debug.assert;

fn hexToNimble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => 0xa + c - 'A',
        'a'...'f' => 0xa + c - 'a',
        else => null,
    };
}

comptime {
    // Ensure binary compatibility
    assert(@sizeOf(UUID) == @sizeOf(u128));
    assert(@alignOf(UUID) == @alignOf(u128));
}

pub const UUID = extern union {
    value: u128,
    u64s: [2]u64,
    u32s: [4]u32,
    bytes: [16]u8,
    v1: packed struct(u128) {
        time_low: u32,
        time_mid: u16,
        version_time_high: u16,
        variant_seq: u16,
        node: u48,
    },
    common: packed struct(u128) {
        data: u62,
        variant: u2,
        data2: u12,
        version: u4,
        data3: u48,
    },
    v7: packed struct(u128) {
        random: u62,
        variant: u2,
        random2: u12,
        version: u4,
        timestamp: u48,
    },

    pub const @"null" = UUID{ .value = 0 };
    pub const stringified_length = 36;

    pub const HashCtx = struct {
        pub fn hash(_: HashCtx, uuid: UUID) u64 {
            return std.hash.Wyhash.hash(0, &uuid.bytes);
        }
        pub fn eql(_: HashCtx, a: UUID, b: UUID) bool {
            return a.eql(b);
        }
    };

    pub fn parse(str: *const [stringified_length]u8) error{InvalidCharacter}!UUID {
        const sections: [5][2]usize = .{
            .{ 0, 8 },
            .{ 9, 13 },
            .{ 14, 18 },
            .{ 19, 23 },
            .{ 24, 36 },
        };

        var res: UUID = undefined;
        inline for (sections, 0..) |sec, j| {
            const pairs: *const [sec[1] - sec[0]][2]u8 = @ptrCast(str[sec[0]..sec[1]]);
            inline for (pairs, sec[0]..) |c, i| {
                const high = hexToNimble(c[0]);
                const low = hexToNimble(c[1]);
                if (high == null or low == null) {
                    if (@inComptime()) {
                        @compileError(std.fmt.comptimePrint(
                            "Invalid byte: {s}\x1b[31m{s}\x1b[0m{s}",
                            .{ str[0 .. i % 2], str[i % 2 ..][0..2], str[i % 2 + 2 ..] },
                        ));
                    }
                    return error.InvalidCharacter;
                }
                res.bytes[j + i - sec[0]] = (high.? << 4) | low.?;
            }
        }

        return res;
    }

    pub inline fn parseComptime(str: *const [stringified_length]u8) UUID {
        comptime return parse(str) catch unreachable;
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
            self.v1.time_low,          self.v1.time_mid,
            self.v1.version_time_high, self.v1.variant_seq,
            self.v1.node,
        });
    }

    pub fn serialize(self: UUID, mapw: *utils.serial.MapWriter) utils.serial.MapWriter.WriteError!void {
        switch (mapw.output_type) {
            .human_readable => {
                var buf: [stringified_length]u8 = undefined;
                self.stringify(&buf);
                try mapw.writeString(&buf);
            },
            .text, .binary => {
                try mapw.beginArray(4);
                inline for (self.u32s) |v| {
                    try mapw.writeInt(@bitCast(v));
                }
                try mapw.endArray();
            },
        }
    }

    pub fn deserialize(mapr: *utils.serial.MapReader) utils.serial.MapReader.ReadError!UUID {
        switch (try mapr.next()) {
            .string => |str| {
                if (str.len != stringified_length) return error.LengthMismatch;

                return parse(str[0..stringified_length]);
            },
            .array_start => |arr| {
                if (arr.type) |t| {
                    if (t != .int) return error.UnexpectedToken;
                }
                if (arr.length) |len| {
                    if (len != 4) return error.UnexpectedToken;
                }

                var res: UUID = .null;
                for (&res.u32s) |*o| {
                    const v = try mapr.nextAsIntUnsigned();
                    if (v > std.math.maxInt(u32)) return error.UnexpectedToken;
                    o.* = @truncate(v);
                }

                try mapr.nextExpect(.array_end);

                return res;
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn withAttributes(self: UUID, version: u4, variant: enum { variant1, variant2 }) UUID {
        var out = self;
        out.common.version = version;
        switch (variant) {
            .variant1 => out.common.variant = 0b10,
            .variant2 => {
                out.common.variant = 0b11;
                out.common.data3 >>= 1;
            },
        }
        return out;
    }

    pub fn makeVersion4(io: std.Io) UUID {
        var out: UUID = undefined;
        io.random(@ptrCast(&out));
        return out.withAttributes(4, .variant1);
    }

    pub fn makeVersion7(io: std.Io) UUID {
        var rnd: u80 = undefined;
        io.random(@ptrCast(&rnd));
        const timestamp = std.Io.Timestamp.now(io, .real);
        return UUID{ .v7 = .{
            .timestamp = @truncate(@as(u64, @bitCast(timestamp.toMilliseconds()))),
            .version = 7,
            .random2 = @truncate(rnd >> 62),
            .variant = 0b10,
            .random = @truncate(rnd),
        } };
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(UUID);
}
