const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");
const utils = @import("utils.zig");

const assert = std.debug.assert;

fn hexToNimble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F', 'a'...'f' => 0xa + (c | 32) - 'a',
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
        node: u48,
        variant_seq: u16,
        ver_time_hi: packed struct(u16) {
            time_high: u12,
            version: u4,
        },
        time_mid: u16,
        time_low: u32,

        pub fn variant(self: @This()) u2 {
            assert(self.version == 1);
            return switch (self.variant_seq & 0xE000) {
                0x8000, 0xA000 => 1,
                0xC000 => 2,
                else => unreachable, // bad UUIDv1
            };
        }
    },
    v3: V35,
    v2: packed struct(u128) {
        node: u48,
        local_id_domain: u8,
        variant: u2,
        clock_seq_low: u6,
        ver_time_hi: packed struct(u16) {
            time_high: u12,
            version: u4,
        },
        time_mid: u16,
        local_id: u32,
    },
    v4: packed struct(u128) {
        random5: u56,
        variant_random2: u16,
        version: u4,
        random0: u52,

        pub fn variant(self: @This()) u2 {
            assert(self.version == 1);
            return switch (self.variant_random2 & 0xE000) {
                0x8000, 0xA000 => 1,
                0xC000 => 2,
                else => unreachable, // bad UUIDv1
            };
        }
    },
    v5: V35,
    v6: packed struct(u128) {
        node: u48,
        variant: u2,
        variant_seq: u14,
        ver_time_lo: packed struct(u16) {
            time_low: u12,
            version: u4,
        },
        time_mid: u16,
        time_high: u32,
    },
    v7: packed struct(u128) {
        random2: u56,
        variant: u2,
        random1: u6,
        version_rnd0: packed struct(u16) {
            random: u12,
            version: u4,
        },
        timestamp: u48,
    },

    pub const @"null" = UUID{ .value = 0 };
    pub const stringified_length = 36;

    pub const V35 = packed struct(u128) {
        data5: u56,
        variant: u2,
        data2: u14,
        version: u4,
        data0: u52,
    };

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
            const pairs: *const [@divExact(sec[1] - sec[0], 2)][2]u8 = @ptrCast(str[sec[0]..sec[1]]);
            inline for (pairs, 0..) |c, off| {
                const i = sec[0] + (off * 2);
                const be_index = @divExact(i - j, 2);
                const byte_index = switch (std.builtin.Endian.native) {
                    .little => res.bytes.len - be_index - 1,
                    .big => be_index,
                };

                const high = hexToNimble(c[0]);
                const low = hexToNimble(c[1]);
                if (high == null or low == null) {
                    if (@inComptime()) {
                        @compileError(std.fmt.comptimePrint(
                            "Invalid byte: {s}\x1b[31m{s}\x1b[0m{s}",
                            .{ str[0..i], str[i..][0..2], str[i + 2 ..] },
                        ));
                    }
                    return error.InvalidCharacter;
                }
                res.bytes[byte_index] = (high.? << 4) | low.?;
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
        assert(fbw.end == stringified_length);
    }

    pub fn eql(a: UUID, b: UUID) bool {
        return a.value == b.value;
    }

    pub fn format(self: UUID, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const info = @typeInfo(@FieldType(UUID, "v1")).@"struct";
        inline for (0..info.fields.len) |i| {
            const f = info.fields[info.fields.len - i - 1];
            if (i != 0) try writer.writeByte('-');
            const bits = @bitSizeOf(f.type);
            const I = @Int(.unsigned, bits);
            try writer.printInt(@as(I, @bitCast(@field(self.v1, f.name))), 16, .lower, .{
                .fill = '0',
                .alignment = .right,
                .width = bits / 4,
            });
        }
    }

    pub fn serialize(self: UUID, mapw: *serial.MapWriter) serial.MapWriter.WriteError!void {
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

    pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!UUID {
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
        out.v1.ver_time_hi.version = version;
        switch (variant) {
            .variant1 => out.v1.variant_seq = (out.v1.variant_seq & 0x3FFF) | 0x8000,
            .variant2 => out.v1.variant_seq = (out.v1.variant_seq & 0x1FFF) | 0xC000,
        }
        return out;
    }

    pub fn makeVersion3(name: []const u8) UUID {
        var hash = std.crypto.hash.Md5.init(.{});
        hash.update(name);
        var out: UUID = undefined;
        hash.final(&out.bytes);
        out.value = @byteSwap(out.value);
        return out.withAttributes(3, .variant1);
    }

    pub fn makeVersion5(name: []const u8) UUID {
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(name);
        var bytes: [20]u8 = undefined;
        hash.final(&bytes);
        return withAttributes(.{ .bytes = bytes[0..16].* }, 5, .variant1);
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
            .version_rnd0 = .{
                .random = @truncate(rnd),
                .version = 7,
            },
            .random1 = @truncate(rnd >> 12),
            .variant = 0b10,
            .random2 = @truncate(rnd >> 18),
        } };
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(UUID);
}

test "UUID.makeVersion3" {
    const uuid = UUID.makeVersion3("Offline: Darkfllame");
    try std.testing.expectEqual(0xf87c8a30_3786_3502_9d64_3e54fe0cebf4, uuid.value);
}

test "UUID.parse" {
    const uuid = try UUID.parse("f87c8a30-3786-3502-9d64-3e54fe0cebf4");
    try std.testing.expectEqual(0xf87c8a30_3786_3502_9d64_3e54fe0cebf4, uuid.value);
}

test "UUID" {
    const uuid = UUID{ .value = 0xf87c8a30_3786_3502_9d64_3e54fe0cebf4 };
    var buf: [UUID.stringified_length]u8 = undefined;
    uuid.stringify(&buf);
    try std.testing.expectEqualStrings("f87c8a30-3786-3502-9d64-3e54fe0cebf4", &buf);
}
