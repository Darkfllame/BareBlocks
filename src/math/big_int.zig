const std = @import("std");
const builtin = @import("builtin");
const math = @import("math.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Reciprocal = struct {
    const WideWord = @Int(.unsigned, @bitSizeOf(usize) * 2);

    fn wideningMul(lhs: usize, rhs: usize) struct { usize, usize } {
        const a: WideWord = lhs;
        const b: WideWord = rhs;
        const ret = a * b;
        return .{ @truncate(ret), @truncate(ret >> @bitSizeOf(usize)) };
    }

    fn shortDiv(dividend: u32, dividend_bits: u32, divisor: u32, divisor_bits: u32) u32 {
        const _divisor = divisor << (dividend_bits - divisor_bits);
        var quotient: u32 = 0;
        var i = dividend_bits - divisor_bits + 1;

        while (i > 0) {
            i -= 1;
            const bit = dividend < _divisor;
            dividend = if (bit) dividend else dividend.wrapping_sub(_divisor);
            divisor >>= 1;
            quotient |= if (!bit) @as(u32, 1) << @intCast(i) else 0;
        }

        return quotient;
    }

    const _reciprocal = switch (@bitSizeOf(usize)) {
        32 => reciprocal32,
        64 => reciprocal64,
        else => @compileError("Cannot compile on this platform"),
    };

    fn reciprocal32(d: u32) u32 {
        assert(d >= (1 << 31));

        const d0 = d & 1;
        const d10 = d >> 22;
        const d21 = (d >> 11) + 1;
        const d31 = (d >> 1) + d0;
        const v0 = shortDiv(
            (1 << 24) - (1 << 14) + (1 << 9),
            24,
            d10,
            10,
        );
        _, var hi = wideningMul(v0 * v0, d21);
        const v1 = (v0 << 4) - hi - 1;

        assert(wideningMul(v1, d31)[1] == (1 << 16) - 1);
        const e = (~(v1 *% d31) + 1) + (v1 >> 1) * d0;

        _, hi = wideningMul(v1, e);
        const v2 = (v1 << 15) +% (hi >> 1);

        const x = v2 +% 1;
        _, hi = wideningMul(x, d);
        if (x == 0) hi = d;

        return (v2 -% hi) -% d;
    }

    fn reciprocal64(d: u64) u64 {
        assert(d >= (1 << 63));

        const d0 = d & 1;
        const d9 = d >> 55;
        const d40 = (d >> 24) + 1;
        const d63 = (d >> 1) + d0;
        const v0 = shortDiv(
            (1 << 19) - 3 * (1 << 8),
            19,
            @truncate(d9),
            9,
        );
        const v1 = (v0 << 11) - ((v0 * v0 * d40) >> 40) - 1;
        const v2 = (v1 << 13) + ((v1 * ((1 << 30) - v1 * d40)) >> 47);

        assert(wideningMul(v2, d63)[1] == (1 << 32) - 1);
        const e = (~(v2 *% d63) + 1) + (v2 >> 1) * d0;

        _, var hi = wideningMul(v2, e);
        const v3 = (v2 << 31) +% (hi >> 1);

        const x = v3 +% 1;
        _, hi = wideningMul(x, d);
        if (x == 0) hi = d;

        return (v2 -% hi) -% d;
    }

    divisor_normalized: usize,
    reciprocal: usize,
    shift: u32,

    fn new(divisor: usize) Reciprocal {
        assert(divisor > 0);

        const shift = @clz(divisor);
        const div_norm = divisor << shift;

        return .{
            .divisor_normalized = div_norm,
            .shift = shift,
            .reciprocal = _reciprocal(div_norm),
        };
    }
};

pub fn BigUInt(comptime Element: type) type {
    const info = switch (@typeInfo(Element)) {
        .int => |i| i,
        inline else => |_, tag| @compileError("BigInt: Element must be an int type, got: " ++ @tagName(tag)),
    };
    assert(info.signedness == .unsigned); // Element must be unsigned
    assert(info.bits == 0 or std.math.isPowerOfTwo(info.bits)); // Elements must be a power of two

    return struct {
        const Self = @This();

        /// Most often times 1e5 as precision would be way enough
        fn maxDigitsForBits(comptime precision: comptime_int, bits: usize) usize {
            const log10_2_scaled: comptime_int = @floor(math.log10_2 * precision + 0.5);
            return ((bits * log10_2_scaled) + (precision - 1)) / precision;
        }

        fn getUseableParts(self: Self) []Element {
            if (self.bit_size == 0) return self.parts[0..0];
            return self.parts[0 .. @divFloor(self.bit_size - 1, @bitSizeOf(Element)) + 1];
        }

        fn getLastElementMask(parts_count: usize, bits: usize) Element {
            // 64 - (total_bit_len - bit_size)
            const last_bit_offset = (parts_count * @bitSizeOf(Element)) - bits;
            return (@as(Element, std.math.maxInt(Element)) >> @intCast(last_bit_offset));
        }

        fn getElement(self: Self, index: usize) Element {
            const parts = self.getUseableParts();
            const mask = if (index == parts.len - 1)
                getLastElementMask(parts.len, self.bit_size)
            else
                ~@as(Element, 0);
            return parts[index] & mask;
        }

        // fn divLimb(self: *Self, a:void) void {
            
        // }

        /// `.len` is the capacity of this number.
        ///
        /// Each elements is organized in little-endian order.
        parts: []Element,
        bit_size: usize,

        pub const max_element_value = std.math.maxInt(Element);
        pub const zero = fromPartsOwned(&.{});

        pub const FormatBase = enum { binary, octal, decimal, hex };

        /// Should be used when an input is not supposed to change in any way,
        /// shape or form. Its total size should be similar to a slice.
        pub const Const = struct {
            /// Its length is equal to `ceil(bit_size / @sizeOf(Element))`.
            /// Use `getSlice()` to safely get a slice with this as `.ptr`.
            parts: [*]const Element,
            bit_size: usize,

            pub const zero = Const.literal(0);
            pub const one = Const.literal(1);

            pub inline fn literal(comptime N: comptime_int) Self.Const {
                comptime {
                    if (N < 0) @compileError("N must be positive!");
                    if (N == 0) return .{ .parts = &[0]Element{}, .bit_size = 0 };

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

            // Normalizes
            pub fn fromParts(parts: []const Element) Self.Const {
                if (parts.len == 0) return .zero;

                var i: usize = parts.len - 1;
                var bits: usize = undefined;
                while (true) : ({
                    if (i == 0) break;
                    i -= 1;
                }) {
                    const clz = @clz(parts[i]);
                    if (clz < @bitSizeOf(Element)) {
                        bits = (i + 1) * @bitSizeOf(Element) - clz;
                        break;
                    }
                }
                return .{
                    .parts = parts.ptr,
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
                    .parts = self.getSlice(),
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

            pub fn getSlice(self: Const) []const Element {
                if (self.bit_size == 0) return self.parts[0..0];
                return self.parts[0 .. @divFloor(self.bit_size - 1, @bitSizeOf(Element)) + 1];
            }

            pub fn isZero(self: Const) bool {
                return self.bit_size == 0;
            }

            pub fn isEven(self: Const) bool {
                if (self.bit_size == 0) return true;
                return (self.parts[0] & 1) == 0;
            }

            pub fn eql(self: Const, other: Const) bool {
                if (self.bit_size != other.bit_size) return false; // Const's are always normalized
                if (self.bit_size == 0) return true; // 0 is represented with 0 bits

                const self_slice = self.getSlice();
                const last_elem_mask = getLastElementMask(self_slice.len, self.bit_size);

                for (self_slice, other.parts[0..self_slice.len], 0..) |a, b, i| {
                    const ma, const mb = if (i == self_slice.len - 1)
                        .{ a & last_elem_mask, b & last_elem_mask }
                    else
                        .{ a, b };
                    if (ma != mb) return false;
                }

                return true;
            }

            pub fn order(self: Const, other: Const) std.math.Order {
                if (self.bit_size < other.bit_size) return .lt;
                if (self.bit_size > other.bit_size) return .gt;
                if (self.bit_size == 0) return .eq; // fast path for zero

                const slice_len = self.getSlice().len;
                const last_elem_mask = getLastElementMask(slice_len, self.bit_size);

                for (0..slice_len) |i| {
                    const index = slice_len - 1 - i;

                    // reverse order means i == 0 is end of slice
                    const ma, const mb = if (i == 0)
                        .{ self.parts[index] & last_elem_mask, other.parts[index] & last_elem_mask }
                    else
                        .{ self.parts[index], other.parts[index] };
                    // so take 35 and 40 as example:
                    // 00100011
                    // 00101000
                    // you need to check each bits in reverse order whether
                    // a[x] is smaller than b[x], if a single bit from a is 0 while
                    // the same bit in b is 1, the number is smaller.
                    // Same principle here but for each elements instead of bits.
                    if (ma == mb) continue;
                    if (ma < mb) return .lt;
                    if (ma > mb) return .gt;
                }

                return .eq;
            }

            pub fn compare(self: Const, op: std.math.CompareOperator, other: Const) bool {
                return self.order(other).compare(op);
            }

            pub fn eqlLiteral(self: Const, comptime N: comptime_int) bool {
                return self.eql(.literal(N));
            }

            pub fn orderLiteral(self: Const, comptime N: comptime_int) std.math.Order {
                return self.order(.literal(N));
            }

            pub fn compareLiteral(self: Const, op: std.math.CompareOperator, comptime N: comptime_int) std.math.Order {
                return self.compare(op, .literal(N));
            }

            pub fn dupe(self: Const, allocator: Allocator) Allocator.Error!Self {
                return .{
                    .parts = try allocator.dupe(Element, self.getSlice()),
                    .bit_size = self.bit_size,
                };
            }

            // pub fn sqrt(self: Const, allocator: Allocator) Allocator.Error!Self {}
        };

        pub const Alt = struct {
            fn writeBits(self: Alt, writer: *Io.Writer) Io.Writer.Error!usize {
                const last_element_mask = getLastElementMask(self.parts.len, self.bit_size);

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
                const last_element_mask = getLastElementMask(self.parts.len, self.bit_size);

                var bits: usize = 0;
                for (1..self.parts.len + 1) |i| {
                    var part = self.parts[self.parts.len - i];
                    bits += @bitSizeOf(Element);
                    if (i == 1) {
                        part &= last_element_mask;
                        bits -= @intCast(@clz(part));
                    }

                    if (i > 1 and self.sep != null) {
                        try writer.writeByte(self.sep.?);
                    }
                    try writer.printInt(part, 16, self.case, .{
                        .width = if (i != 1) 16 else null,
                        .fill = '0',
                    });
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

            sep: ?u8 = '_',
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

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.parts);
        }

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
            assert(self.bit_size == 0 or buf.len >= switch (num.mode) {
                .binary => self.bit_size,
                .octal => @divFloor(self.bit_size - 1, 3) + 1,
                .decimal => maxDigitsForBits(1e9, self.bit_size),
                .hex => @divFloor(self.bit_size - 1, 4) + 1,
                else => |tag| std.debug.panic("Number mode {t} not supported", .{tag}),
            });
            return Alt{
                .parts = self.getUseableParts(),
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
            return .{ .parts = self.parts.ptr, .bit_size = self.bit_size };
        }

        pub fn fromPartsOwned(parts: []Element) Self {
            if (parts.len == 0) return .{ .parts = parts, .bit_size = 0 };

            var i: usize = parts.len - 1;
            var bits: usize = 0;
            while (true) : ({
                if (i == 0) break;
                i -= 1;
            }) {
                const clz = @clz(parts[i]);
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

        pub fn dupe(self: Self, allocator: Allocator) Allocator.Error!Self {
            return .{
                .parts = try allocator.dupe(Element, self.getUseableParts()),
                .bit_size = self.bit_size,
            };
        }

        pub fn dupeInto(self: Self, allocator: Allocator, out: *Self) Allocator.Error!void {
            try out.ensureTotalCapacity(allocator, self.bit_size);
            @memcpy(out.parts.ptr, self.getUseableParts());
            out.bit_size = self.bit_size;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, bit_capacity: usize) Allocator.Error!void {
            if (self.bit_size > bit_capacity) return;
            const real_capacity = @divFloor(@max(1, bit_capacity) - 1, @bitSizeOf(Element)) + 1;
            const best_capcity = std.ArrayList(Element).growCapacity(real_capacity);
            const old_len = self.parts.len;
            self.parts = try allocator.realloc(self.parts, best_capcity);
            @memset(self.parts[old_len..], 0);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, bit_capacity: usize) Allocator.Error!void {
            return self.ensureTotalCapacity(allocator, self.bit_size + bit_capacity);
        }

        pub fn zerofy(self: *Self) void {
            self.bit_size = 0;
            @memset(self.parts, 0);
        }

        pub fn add(self: *Self, allocator: Allocator, other: Const) Allocator.Error!void {
            // at most one bit of carry remaining, which must be stored
            try self.ensureTotalCapacity(allocator, @max(self.bit_size, other.bit_size) + 1);
            self.addAssumeCapacity(other);
        }

        pub fn addAssumeCapacity(self: *Self, other: Const) void {
            const other_slice = other.getSlice();
            var carry: u1 = 0;
            for (other_slice, self.parts[0..other_slice.len]) |elem, *out| {
                const res = @addWithOverflow(out.*, elem);
                out.* = res[0] + carry;
                carry = res[1];
            }
            if (carry != 0) {
                self.parts[other_slice.len] = 1;
            }
            self.bit_size = other_slice.len * @bitSizeOf(usize) + carry;
        }

        pub fn sub(self: *Self, other: Const) void {
            assert(self.toConst().compare(.gte, other));

            const other_slice = other.getSlice();
            var carry: u1 = 0;
            for (other_slice, self.parts[0..other_slice.len]) |elem, *out| {
                const res = @subWithOverflow(out.*, elem);
                // if overflow (res[1] == 1), set the current to 0
                // otherwise just set the result
                out.* = (res[0] * (1 - res[1])) -% carry;
                carry = res[1];
            }
            assert(carry == 0);
            self.bit_size = fromPartsOwned(self.parts[0..other_slice.len]).bit_size;
        }

        pub fn mul(self: *Self, allocator: Allocator, other: Const) Allocator.Error!void {
            // 0b10000000 * 0b10000000 =
            // 0b01000000_00000000 which is 15 bits, same principle
            try self.ensureTotalCapacity(allocator, self.bit_size + other.bit_size - 1);
            self.mulAssumeCapacity(other);
        }

        pub fn mulAssumeCapacity(self: *Self, other: Const) void {
            const other_slice = other.getSlice();
            var add_carry: u1 = 0;
            var mul_carry: Element = 0;
            for (other_slice, self.parts[0..other_slice.len]) |elem, *out| {
                const res = @mulWithOverflow(out.*, elem);
                const add_res = @addWithOverflow(res[0], mul_carry);
                out.* = add_res[0] + add_carry;
                add_carry = add_res[1];
                mul_carry = (~res[0]) * res[1];
            }
            // shouldn't overflow, as there'll always be a free bit at the end
            const full_carry = mul_carry + add_carry;
            if (full_carry != 0) {
                self.parts[other_slice.len] = full_carry;
            }
            self.bit_size = ((other_slice.len + 1) * @bitSizeOf(Element)) - @clz(full_carry);
        }

        // pub fn div(self: *Self, mod_out: *Self, allocator: Allocator, other: Const) Allocator.Error!void {
        //     if ((comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) and
        //         other.bit_size == 0) std.builtin.panic.divideByZero();

        //     if (self.bit_size == 0) {
        //         mod_out.zerofy();
        //         return;
        //     }

        //     if (other.bit_size <= @bitSizeOf(Element)) {
        //         const denom = other.parts[0] & getLastElementMask(1, other.bit_size);

        //     }

        //     try self.dupeInto(allocator, mod_out);
        //     while (mod_out.toConst().compare(.gte, other)) {
        //         mod_out.sub(other);
        //         try self.add(allocator, .one);
        //     }
        // }
    };
}

// TODO: BigInt.compare/order whatever
// TODO: BigInt.add/sub/mul/div/mod
// TODO: BigInt.sqrt/pow (similar to python's pow(x, y, r) preferably)
// TODO: Don't make it like std.math.big.int
