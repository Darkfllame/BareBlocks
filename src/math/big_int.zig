const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn BigInt(comptime Element: type) type {
    const info = switch (@typeInfo(Element)) {
        .int => |i| i,
        inline else => |_, tag| @compileError("BigInt: Element must be an int type, got: " ++ @tagName(tag)),
    };
    assert(info.signedness == .unsigned); // Element must be unsigned
    assert(info.bits == 0 or std.math.isPowerOfTwo(info.bits)); // Elements must be a power of two

    return struct {
        const Self = @This();

        const log10_2 = 0.301029995663981195213738894724493027;

        /// Most often times 1e5 as precision would be way enough
        fn maxDigitsForBits(comptime precision: comptime_int, bits: usize) usize {
            const log10_2_scaled: comptime_int = @floor(log10_2 * precision + 0.5);
            return ((bits * log10_2_scaled) + (precision - 1)) / precision;
        }

        fn getUseableParts(self: Self) []Element {
            if (self.bit_size == 0) return self.parts;
            const elem_count = @divFloor(self.bit_size - 1, @bitSizeOf(Element)) + 1;
            return self.parts[0..elem_count];
        }

        /// `.len` is the capacity of this number.
        ///
        /// Each elements is organized in little-endian order.
        parts: []Element,
        bit_size: usize,

        pub const max_element_value = std.math.maxInt(Element);
        pub const zero = Self.Const{ .parts = &.{}, .bit_size = 0 };

        pub const FormatBase = enum { binary, octal, decimal, hex };

        /// Should be used when an input is not supposed to change in any way,
        /// shape or form.
        pub const Const = struct {
            parts: []const Element,
            bit_size: usize,

            pub inline fn literal(comptime N: comptime_int) Self.Const {
                comptime {
                    var arr_count = 0;
                    var N_cpy = N;
                    while (N_cpy >= max_element_value) {
                        arr_count += 1;
                        N_cpy >>= @bitSizeOf(Element);
                    }
                    if (N_cpy != 0) {
                        arr_count += 1;
                    }

                    var parts_array: [arr_count]Element = undefined;
                    var bit_len: usize = 0;
                    N_cpy = N;
                    var i = 0;
                    while (N_cpy >= max_element_value) {
                        // @compileLog(N_cpy);
                        parts_array[i] = N_cpy & max_element_value;
                        bit_len += @bitSizeOf(Element);
                        i += 1;
                        N_cpy >>= @bitSizeOf(Element);
                    }
                    if (N_cpy != 0) {
                        parts_array[i] = N_cpy;
                        bit_len += @bitSizeOf(Element) - @clz(@as(Element, N_cpy));
                    }

                    const parts_cpy = parts_array;
                    return .{ .parts = &parts_cpy, .bit_size = bit_len };
                }
            }

            pub fn fromParts(parts: []const Element) Self.Const {
                if (parts.len == 0) return zero;

                var i: usize = parts.len - 1;
                var bits: usize = undefined;
                while (true) : ({
                    if (i == 0) break;
                    i -= 1;
                }) {
                    const p = parts[i];
                    const clz = @clz(p);
                    if (clz < @bitSizeOf(Element)) {
                        bits = (i + 1) * @bitSizeOf(Element) - clz;
                        break;
                    }
                }
                return .{
                    .parts = parts[0 .. i + 1],
                    .bit_size = bits,
                };
            }

            /// `allocator` is used for internal pre-allocation.\
            /// `decimal_precision` is only used when `num.mode == .decimal`, to calculate the length of
            ///     an internal array to print said decimal number.\
            /// `num.mode` cannot be `.scientific`.\
            ///
            /// Call `.deinit` on returned `Alt` to free allocated memory.
            pub fn alt(self: Const, allocator: Allocator, comptime decimal_precision: comptime_int, num: std.fmt.Number) Allocator.Error!Alt {
                const buf = if (num.mode == .decimal)
                    try allocator.alloc(u8, maxDigitsForBits(decimal_precision, self.bit_size))
                else if (num.width != null and num.alignment != .right) blk: {
                    const len: usize = switch (num.mode) {
                        .binary => self.bit_size,
                        .octal => @divFloor(self.bit_size - 1, 3) + 1,
                        .decimal => unreachable,
                        .hex => @divFloor(self.bit_size - 1, 4) + 1,
                        else => |tag| std.debug.panic("Number mode {t} not supported", .{tag}),
                    };
                    break :blk try allocator.alloc(u8, len);
                } else @as([]u8, &.{});
                return self.altBuf(buf, num);
            }

            pub fn altBuf(self: Const, buf: []u8, num: std.fmt.Number) Alt {
                if (num.width != null) {
                    assert(buf.len >= switch (num.mode) {
                        .binary => self.bit_size,
                        .octal => @divFloor(self.bit_size - 1, 3) + 1,
                        .decimal => maxDigitsForBits(1e9, self.bit_size),
                        .hex => @divFloor(self.bit_size - 1, 4) + 1,
                        else => |tag| std.debug.panic("Number mode {t} not supported", .{tag}),
                    });
                }
                return Alt{
                    .parts = self.parts[0 .. @divFloor(self.bit_size - 1, @bitSizeOf(Element)) + 1],
                    .bit_size = self.bit_size,
                    .buf = buf,
                    .base = switch (num.mode) {
                        inline .binary, .octal, .decimal, .hex => |tag| @field(FormatBase, @tagName(tag)),
                        else => unreachable,
                    },
                    .case = num.case,
                    .options = .{ .precision = num.precision, .width = num.width, .alignment = num.alignment, .fill = num.fill },
                };
            }

            pub fn format(self: Const, writer: *Io.Writer) Io.Writer.Error!void {
                // 4096 is enough for more than 10240 bits!!
                // that's like a 80KiB BigInt, way more than enough.
                var dec_buf: [4096]u8 = undefined;
                try Alt.format(self.altBuf(&dec_buf, .{}), writer);
            }
        };

        pub const Alt = struct {
            fn getLastElementMask(self: Alt) Element {
                // 64 - (total_bit_len - bit_size)
                const last_bit_offset = (self.parts.len * @bitSizeOf(Element)) - self.bit_size;
                return (@as(Element, std.math.maxInt(Element)) >> @intCast(last_bit_offset));
            }

            fn writeBits(self: Alt, writer: *Io.Writer) Io.Writer.Error!usize {
                const last_element_mask = self.getLastElementMask();

                var bits: usize = 0;
                for (1..self.parts.len + 1) |i| {
                    var part = self.parts[self.parts.len - i];
                    bits += @bitSizeOf(Element);
                    if (i == self.parts.len) {
                        part &= last_element_mask;
                        bits -= @clz(part);
                    }

                    try writer.printInt(part, 2, self.case, .{});
                }
                return bits;
            }

            fn writeOctal(self: Alt, writer: *Io.Writer) Io.Writer.Error!usize {
                var chars: usize = 0;
                var bit_offset: usize = self.bit_size;
                while (bit_offset > 0) {
                    bit_offset -= 3;
                    const octal_num = self.getOctalAt(bit_offset, -1);

                    try writer.writeByte(std.fmt.digitToChar(octal_num, self.case));
                    chars += 1;
                }
                return chars;
            }

            fn getOctalAt(self: Alt, bit_offset: usize, inc: i2) u3 {
                const index = bit_offset / @bitSizeOf(Element);
                const bit_index = bit_offset % @bitSizeOf(Element);
                // 0b1111111111111111111111111111111111111111111111111111111111111111
                //    | 62
                var res: usize = self.parts[index] >> @intCast(bit_index);
                // 0b0000000000000000000000000000000000000000000000000000000000000011
                res &= 0b111;
                // 62 > ((64 - 3) = 63)
                if (bit_index > (@bitSizeOf(Element) - 3)) {
                    // 3 - ((64 - 62) = 2) = 1
                    // 3 - ((64 - 63) = 1) = 2
                    const new_bit_index = 3 - (@bitSizeOf(Element) - bit_index);
                    // new_bit_index can only be 1 or 2 (0b10)
                    // so just or it with 1 to get the correct mask
                    res |= self.parts[@bitCast(@as(isize, @bitCast(index)) + inc)] & (new_bit_index | 1);
                }
                return @truncate(res);
            }

            fn writeHex(self: Alt, writer: *Io.Writer) Io.Writer.Error!usize {
                const last_element_mask = self.getLastElementMask();

                var bits: usize = 0;
                for (1..self.parts.len + 1) |i| {
                    var part = self.parts[self.parts.len - i];
                    bits += @bitSizeOf(Element);
                    if (i == 1) {
                        part &= last_element_mask;
                        bits -= @intCast(@clz(part));
                    }

                    if (i > 1) {
                        try writer.writeByte('_');
                    }
                    try writer.printInt(part, 16, self.case, .{});
                }
                return @divFloor(bits - 1, 4) + 1;
            }

            fn addPartToBuf(self: Alt, part: Element) bool {
                var a: Element = part;
                var index: usize = self.buf.len;
                while (a > 0) : ({
                    a /= 10;
                    if (index == 0) break;
                }) {
                    index -= 1;
                    const addend = a % 10;
                    // std.log.debug("bi: {d}, a: {d}, addent: {d}", .{
                    // index, a, addend,
                    // });

                    const res = self.buf[index] - '0' + addend;
                    self.buf[index] = @truncate('0' + (res % 10));
                }
                // std.log.debug("remainder: {d}, buffered: {s}", .{ a, self.buf });
                return a == 0;
            }

            parts: []const Element,
            bit_size: usize,
            buf: []u8,

            base: FormatBase,
            case: std.fmt.Case,
            options: std.fmt.Options,

            pub fn deinit(self: Alt, allocator: Allocator) void {
                allocator.free(self.buf);
            }

            pub fn format(self: Alt, writer: *Io.Writer) Io.Writer.Error!void {
                var buf_writer = Io.Writer.fixed(self.buf);
                var fill_char_buf = [1][]const u8{(&self.options.fill)[0..1]};

                if (self.bit_size == 0) return writer.alignBufferOptions("0", self.options);

                switch (self.base) {
                    .binary => {
                        if (self.options.width == null) {
                            _ = try self.writeBits(writer);
                            return;
                        }

                        switch (self.options.alignment) {
                            .right => {
                                const bits = try self.writeBits(writer);
                                const width = self.options.width.?;
                                if (width > bits) {
                                    try writer.writeSplatAll(&fill_char_buf, width - bits);
                                }
                            },
                            .center, .left => {
                                _ = try self.writeBits(&buf_writer);

                                try writer.alignBufferOptions(buf_writer.buffered(), self.options);
                            },
                        }
                    },
                    .octal => {
                        if (self.options.width == null) {
                            _ = try self.writeOctal(writer);
                            return;
                        }

                        switch (self.options.alignment) {
                            .right => {
                                const bytes = try self.writeOctal(writer);
                                const width = self.options.width.?;
                                if (width > bytes) {
                                    try writer.writeSplatAll(&fill_char_buf, width - bytes);
                                }
                            },
                            .center, .left => {
                                _ = try self.writeOctal(&buf_writer);

                                try writer.alignBufferOptions(buf_writer.buffered(), self.options);
                            },
                        }
                    },
                    .decimal => {
                        @memset(self.buf, '0');

                        for (self.parts) |part| {
                            if (!self.addPartToBuf(part)) {
                                @branchHint(.unlikely);
                                return writer.writeAll("(BigInt)");
                            }
                        }

                        const start = search_start: for (self.buf, 0..) |c, i| {
                            if (c != '0') break :search_start i;
                        } else unreachable;

                        return writer.alignBufferOptions(self.buf[start..], self.options);
                    },
                    .hex => {
                        if (self.options.width == null) {
                            _ = try self.writeHex(writer);
                            return;
                        }

                        switch (self.options.alignment) {
                            .right => {
                                const bits = try self.writeHex(writer);
                                const width = self.options.width.?;
                                if (width > bits) {
                                    try writer.writeSplatAll(&fill_char_buf, width - bits);
                                }
                            },
                            .center, .left => {
                                _ = try self.writeHex(&buf_writer);

                                try writer.alignBufferOptions(buf_writer.buffered(), self.options);
                            },
                        }
                    },
                }
            }
        };

        pub const literal = Const.literal;

        /// `allocator` is used for internal pre-allocation.\
        /// `decimal_precision` is only used when `num.mode == .decimal`, to calculate the length of
        ///     an internal array to print said decimal number.\
        /// `num.mode` cannot be `.scientific`.\
        ///
        /// Call `.deinit` on returned `Alt` to free allocated memory.
        pub fn alt(self: Self, allocator: Allocator, comptime decimal_precision: comptime_int, num: std.fmt.Number) Allocator.Error!Alt {
            const buf = if (num.width != null and num.alignment != .right) blk: {
                const len: usize = switch (num.mode) {
                    .binary => self.bit_size,
                    .octal => @divFloor(self.bit_size - 1, 3) + 1,
                    .decimal => maxDigitsForBits(decimal_precision, self.bit_size),
                    .hex => @divFloor(self.bit_size - 1, 4) + 1,
                    else => |tag| std.debug.panic("Number mode {t} not supported", .{tag}),
                };
                break :blk try allocator.alloc(u8, len);
            } orelse &.{};
            return self.altBuf(buf, num);
        }

        pub fn altBuf(self: Self, buf: []u8, num: std.fmt.Number) Alt {
            assert(buf.len >= switch (num.mode) {
                .binary => self.bit_size,
                .octal => @divFloor(self.bit_size - 1, 3) + 1,
                .decimal => maxDigitsForBits(1e9, self.bit_size),
                .hex => @divFloor(self.bit_size - 1, 4) + 1,
                else => |tag| std.debug.panic("Number mode {t} not supported", .{tag}),
            });
            return Alt{
                .parts = self.parts[0 .. @divFloor(self.bit_size - 1, @bitSizeOf(Element)) + 1],
                .bit_size = self.bit_size,
                .buf = buf,
                .base = switch (num.mode) {
                    inline .binary, .octal, .decimal, .hex => |tag| @field(FormatBase, @tagName(tag)),
                    else => unreachable,
                },
                .case = num.case,
                .options = .{ .precision = num.precision, .width = num.width, .alignment = num.alignment, .fill = num.fill },
            };
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            // 4096 is enough for more than 10240 bits!!
            // that's like a 80KiB BigInt, way more than enough.
            var dec_buf: [4096]u8 = undefined;
            try Alt.format(self.altBuf(&dec_buf, .{}), writer);
        }

        pub fn toConst(self: Self) Self.Const {
            return .{ .parts = self.getUseableParts(), .bit_size = self.bit_size };
        }

        pub fn fromPartsOwned(parts: []Element) Self {
            if (parts.len == 0) return zero;

            var i: usize = parts.len - 1;
            var bits: usize = undefined;
            while (true) : ({
                if (i == 0) break;
                i -= 1;
            }) {
                const p = parts[i];
                const clz = @clz(p);
                if (clz < @bitSizeOf(Element)) {
                    bits = (i + 1) * @bitSizeOf(Element) - clz;
                    break;
                }
            }
            return .{
                .parts = parts[0 .. i + 1],
                .bit_size = bits,
            };
        }
    };
}

// TODO: BigInt.compare/order whatever
// TODO: BigInt.add/sub/mul/div/mod
// TODO: BigInt.sqrt/pow (similar to python's pow(x, y, r) preferably)
// TODO: Don't make it like std.math.big.int
