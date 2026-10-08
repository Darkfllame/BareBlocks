//! Basically my miscelaneous module for when I don't know where to put things lmaoo

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const is_debug = builtin.mode == .debug;
pub const is_safe = switch (builtin.mode) {
    .debug, .safe => true,
    .small, .fast => false,
};

pub const translation = @import("translation.zig");

pub const BitStack = @import("BitStack.zig");
pub const Color = @import("color.zig").Color;
pub const CountingAllocator = @import("CountingAllocator.zig");
pub const GameProfile = @import("GameProfile.zig");
pub const Identifier = @import("Identifier.zig");
pub const Keybind = @import("keybinds.zig").Keybind;
pub const Selector = @import("Selector.zig");
pub const TextComponent = @import("TextComponent.zig");
pub const UUID = @import("uuid.zig").UUID;
pub const Xoroshiro128PlusPLus = @import("Xoroshiro128PlusPlus.zig");

pub fn Range(comptime T: type) type {
    const minT, const maxT, const epsilon = switch (@typeInfo(T)) {
        .int => .{ std.math.minInt(T), std.math.maxInt(T), 1 },
        .comptime_int => .{ std.math.minInt(i64), std.math.maxInt(i64), 1 },
        .float => .{ std.math.floatMin(T), std.math.floatMax(T), std.math.floatEps(T) },
        .comptime_float => .{ std.math.floatMin(f128), std.math.floatMax(f128), std.math.floatEps(f128) },
        else => @compileError("Unkown numeric type: " ++ @typeName(T)),
    };
    return struct {
        min: T = minT,
        max: T = maxT,

        pub const max_range = @This(){};
        pub const positive = @This(){ .min = 0 };
        pub const negative = @This(){ .max = 0 };
        pub const positive_nz = @This(){ .min = epsilon };
        pub const negative_nz = @This(){ .max = -epsilon };

        pub fn init(min: ?T, max: ?T) @This() {
            const real_min = min orelse minT;
            const real_max = max orelse maxT;
            if (@inComptime() and real_min > real_max) {
                @compileError(std.fmt.comptimePrint("Range({s}): {d} is smaller than {d}", .{ @typeName(T), real_min, real_max }));
            }
            assert(real_min <= real_max);

            return .{ .min = real_min, .max = real_max };
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return writer.print("[{d}, {d}]", .{ self.min, self.max });
        }

        pub inline fn clamp(self: @This(), v: T) T {
            return std.math.clamp(v, self.min, self.max);
        }

        pub inline fn inRange(self: @This(), v: T) bool {
            return self.min <= v and v <= self.max;
        }

        pub fn cast(self: @This(), comptime NewT: type) Range(NewT) {
            return .{
                .min = std.math.cast(NewT, self.min).?,
                .max = std.math.cast(NewT, self.max).?,
            };
        }

        pub fn castLossy(self: @This(), comptime NewT: type) Range(NewT) {
            return .{
                .min = std.math.lossyCast(NewT, self.min),
                .max = std.math.lossyCast(NewT, self.max),
            };
        }

        pub fn fitInOther(self: @This(), other: @This()) bool {
            return other.min <= self.min and self.max <= other.max;
        }
    };
}

pub fn OptionalData(comptime T: type, comptime exists: bool) type {
    return struct {
        const Self = @This();

        value: if (exists) T else void,

        pub fn init(value: T) Self {
            return .{ .value = if (exists) value };
        }

        pub fn get(self: *Self) ?T {
            return if (exists) self.value else null;
        }

        pub fn getPtr(self: *Self) ?*T {
            return if (exists) &self.value else null;
        }

        pub fn getPtrConst(self: *const Self) ?*const T {
            return if (exists) &self.value else null;
        }
    };
}

pub fn EmbeddedArray(comptime attribs: std.builtin.Type.Pointer.Attributes, comptime T: type) type {
    return struct {
        const Self = @This();

        const self_align = attribs.@"align" orelse @max(@alignOf(usize), @alignOf(T));
        const start_offset = std.mem.alignForward(usize, @sizeOf(Self), self_align);
        const aligned_attribs = std.builtin.Type.Pointer.Attributes{
            .@"const" = attribs.@"const",
            .@"volatile" = attribs.@"volatile",
            .@"allowzero" = attribs.@"allowzero",
            .@"addrspace" = attribs.@"addrspace",
            .@"align" = @min(@alignOf(T), self_align),
        };

        const SelfPtr = @Pointer(.one, .{
            .@"const" = attribs.@"const",
            .@"volatile" = attribs.@"volatile",
            .@"allowzero" = attribs.@"allowzero",
            .@"addrspace" = attribs.@"addrspace",
            .@"align" = null,
        }, Self, null);
        const VarPtr = @Pointer(.one, .{
            .@"const" = false,
            .@"volatile" = attribs.@"volatile",
            .@"allowzero" = false,
            .@"addrspace" = attribs.@"addrspace",
            .@"align" = null,
        }, Self, null);

        _: void align(self_align) = {},
        length: usize,
        refc: usize,

        pub const empty = Self{ .length = 0, .refc = 1 };

        pub const SubPtr = @Pointer(.one, aligned_attribs, T, null);
        pub const SubMany = @Pointer(.many, aligned_attribs, T, null);
        pub const SubSlice = @Pointer(.slice, aligned_attribs, T, null);
        pub const SubC = @Pointer(.c, aligned_attribs, T, null);

        pub fn slice(self: SelfPtr) SubSlice {
            const bytes: @Pointer(.many, aligned_attribs, u8, null) = @ptrCast(self);
            return @ptrCast(bytes[start_offset..][0 .. self.length * @sizeOf(T)]);
        }

        pub fn ptrAt(self: SelfPtr, i: usize) SubPtr {
            return &self.slice()[i];
        }

        pub fn getAt(self: SelfPtr, i: usize) T {
            return self.slice()[i];
        }

        pub fn atomicLoad(self: SelfPtr, i: usize, comptime order: std.builtin.AtomicOrder) T {
            return @atomicLoad(T, &self.slice()[i], order);
        }

        pub fn atomicStore(self: SelfPtr, i: usize, value: T, comptime order: std.builtin.AtomicOrder) void {
            @atomicStore(T, &self.slice()[i], value, order);
        }

        pub fn atomicRmw(self: SelfPtr, i: usize, comptime op: std.builtin.AtomicRmwOp, value: T, comptime order: std.builtin.AtomicOrder) T {
            return @atomicRmw(T, &self.slice()[i], op, value, order);
        }

        pub fn cmpxchgWeak(self: SelfPtr, i: usize, expected: T, value: T, comptime success_order: std.builtin.AtomicOrder, comptime fail_order: std.builtin.AtomicOrder) ?T {
            return @cmpxchgWeak(T, &self.slice()[i], expected, value, success_order, fail_order);
        }

        pub fn cmpxchgStrong(self: SelfPtr, i: usize, expected: T, value: T, comptime success_order: std.builtin.AtomicOrder, comptime fail_order: std.builtin.AtomicOrder) ?T {
            return @cmpxchgStrong(T, &self.slice()[i], expected, value, success_order, fail_order);
        }

        pub fn setAt(self: SelfPtr, i: usize, value: T) void {
            self.slice()[i] = value;
        }

        pub fn alloc(allocator: Allocator, size: usize) Allocator.Error!SelfPtr {
            return dupeSlice(@constCast(&empty), allocator, 0, size, 0, 0);
        }

        pub fn dupe(self: SelfPtr, allocator: Allocator, new_len: usize) Allocator.Error!SelfPtr {
            return self.dupeSlice(allocator, 0, new_len, 0, self.length);
        }

        pub fn dupeSlice(self: SelfPtr, allocator: Allocator, dst_start: usize, dst_end: usize, src_start: usize, src_end: usize) Allocator.Error!SelfPtr {
            assert(dst_end >= dst_start);
            assert(src_end >= src_start);

            const min_len = @min(dst_end - dst_start, src_end - src_start);
            
            const source = blk: {
                const elems: []align(aligned_attribs.@"align".?) T = @ptrCast(@constCast(@addrSpaceCast(@volatileCast(self.slice()))));
                break :blk elems[src_start..min_len];
            };

            const new_bytes = try allocator.alignedAlloc(u8, .of(Self), start_offset + dst_end * @sizeOf(T));
            const new: VarPtr = @ptrCast(new_bytes.ptr);
            new.* = .{.length=dst_end,.refc=1};

            const elems: []align(aligned_attribs.@"align".?) T = @ptrCast(@constCast(@addrSpaceCast(@volatileCast(new.slice()))));

            @memcpy(elems[dst_start..min_len], source);
            return @ptrCast(@alignCast(new));
        }

        pub fn acquire(self: SelfPtr) SelfPtr {
            const selfv: VarPtr = @ptrCast(@alignCast(@constCast(self)));
            _=@atomicRmw(usize, &selfv.refc, .Add, 1, .monotonic);
            return self;
        }

        pub fn release(self: SelfPtr, allocator: Allocator) void {
            const selfv: VarPtr = @ptrCast(@alignCast(@constCast(self)));
            if (@atomicRmw(usize, &selfv.refc, .Sub, 1, .release) == 1) {
                const bytes: [*]align(@alignOf(Self)) u8 = @ptrCast(@constCast(@addrSpaceCast(@volatileCast(self))));
                const len = start_offset + self.length * @sizeOf(T);
                allocator.free(bytes[0..len]);
            }
        }
    };
}

pub const Utf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn init(bytes: []const u8) Utf8Iterator {
        return .{ .bytes = bytes, .i = 0 };
    }

    pub fn nextCodepointSlice(it: *Utf8Iterator) error{InvalidUTF8}!?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch return error.InvalidUTF8;
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }

    pub fn nextCodepoint(it: *Utf8Iterator) error{InvalidUTF8}!?u21 {
        const slice = (try it.nextCodepointSlice()) orelse return null;
        return std.unicode.utf8Decode(slice) catch return error.InvalidUTF8;
    }

    /// Look ahead at the next n codepoints without advancing the iterator.
    /// If fewer than n codepoints are available, then return the remainder of the string.
    pub fn peek(it: *Utf8Iterator, n: usize) error{InvalidUTF8}![]const u8 {
        const original_i = it.i;
        defer it.i = original_i;

        var end_ix = original_i;
        var found: usize = 0;
        while (found < n) : (found += 1) {
            const next_codepoint = (try it.nextCodepointSlice()) orelse return it.bytes[original_i..];
            end_ix += next_codepoint.len;
        }

        return it.bytes[original_i..end_ix];
    }
};

pub const RandomPair = struct {
    rnd: std.Random,
    next_next_gaussian: ?f64 = null,

    pub const float_unit: f32 = 5.9604645e-8;
    pub const double_unit: f64 = 1.110223e-16;

    pub fn new(rnd: std.Random) RandomPair {
        return .{ .rnd = rnd };
    }

    pub fn nextGaussian(self: *RandomPair) f64 {
        if (self.next_next_gaussian) |res| {
            self.next_next_gaussian = null;
            return res;
        }

        var x: f64, var y: f64, var radius_squared: f64 = .{ undefined, undefined, undefined };
        while (true) {
            x = 2 * self.float(f64) - 1;
            y = 2 * self.float(f64) - 1;
            radius_squared = x * x + y * y;
            if (radius_squared >= 1 or radius_squared == 0) continue;
            break;
        }

        const multiplier = @sqrt(-2 * @log(radius_squared) / radius_squared);
        self.next_next_gaussian = y * multiplier;
        return x * multiplier;
    }

    pub fn normal(self: *RandomPair, mean: f32, deviation: f32) f32 {
        return mean + @as(f32, @floatCast(self.nextGaussian())) * deviation;
    }

    pub fn bytes(self: *const RandomPair, buf: []u8) void {
        return self.rnd.bytes(buf);
    }
    pub fn array(self: *const RandomPair, comptime E: type, comptime N: usize) [N]E {
        return self.rnd.array(E, N);
    }
    pub fn boolean(self: *const RandomPair) bool {
        return self.rnd.boolean();
    }
    pub fn enumValue(self: *const RandomPair, comptime EnumType: type) EnumType {
        return self.rnd.enumValue(EnumType);
    }
    pub fn enumValueWithIndex(self: *const RandomPair, comptime EnumType: type, comptime Index: type) EnumType {
        return self.rnd.enumValueWithIndex(EnumType, Index);
    }
    pub fn int(self: *const RandomPair, comptime T: type) T {
        return self.rnd.int(T);
    }
    pub fn uintLessThanBiased(self: *const RandomPair, comptime T: type, less_than: T) T {
        return self.rnd.uintLessThanBiased(T, less_than);
    }
    pub fn uintLessThan(self: *const RandomPair, comptime T: type, less_than: T) T {
        return self.rnd.uintLessThan(T, less_than);
    }
    pub fn uintAtMostBiased(self: *const RandomPair, comptime T: type, at_most: T) T {
        return self.rnd.uintAtMostBiased(T, at_most);
    }
    pub fn uintAtMost(self: *const RandomPair, comptime T: type, at_most: T) T {
        return self.rnd.uintAtMost(T, at_most);
    }
    pub fn intRangeLessThanBiased(self: *const RandomPair, comptime T: type, at_least: T, less_than: T) T {
        return self.rnd.intRangeLessThanBiased(T, at_least, less_than);
    }
    pub fn intRangeLessThan(self: *const RandomPair, comptime T: type, at_least: T, less_than: T) T {
        return self.rnd.intRangeLessThan(T, at_least, less_than);
    }
    pub fn intRangeAtMostBiased(self: *const RandomPair, comptime T: type, at_least: T, at_most: T) T {
        return self.rnd.intRangeAtMostBiased(T, at_least, at_most);
    }
    pub fn intRangeAtMost(self: *const RandomPair, comptime T: type, at_least: T, at_most: T) T {
        return self.rnd.intRangeAtMost(T, at_least, at_most);
    }
    /// Implemented in the same way vanilla minecraft does instead
    /// of how zig did
    pub fn float(self: *const RandomPair, comptime T: type) T {
        switch (T) {
            f32 => {
                const rand = self.rnd.int(u64) >> (64 - 24);
                return @as(f32, @floatFromInt(rand)) * float_unit;
            },
            f64 => {
                const rand = self.rnd.int(u64) >> (64 - 53);
                return @as(f64, @floatFromInt(rand)) * double_unit;
            },
            else => @compileError("unknown floating point type"),
        }
    }
    pub fn floatNorm(self: *const RandomPair, comptime T: type) T {
        return self.rnd.floatNorm(T);
    }
    pub fn floatExp(self: *const RandomPair, comptime T: type) T {
        return self.rnd.floatExp(T);
    }
    pub fn shuffle(self: *const RandomPair, comptime T: type, buf: []T) void {
        return self.rnd.shuffle(T, buf);
    }
    pub fn shuffleWithIndex(self: *const RandomPair, comptime T: type, buf: []T, comptime Index: type) void {
        return self.rnd.shuffleWithIndex(T, buf, Index);
    }
    pub fn weightedIndex(self: *const RandomPair, comptime T: type, proportions: []const T) usize {
        return self.rnd.weightedIndex(T, proportions);
    }
};

pub fn err(logger: anytype, comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    }
    logger.err(fmt, args);
}

pub fn compileError(comptime fmt: []const u8, args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

pub fn validateMethod(comptime Base: type, comptime name: []const u8, comptime params: []const type, comptime ReturnType: type) void {
    const fn_type_str, const fn_args_str = blk: {
        var str: []const u8 = "fn (" ++ @typeName(Base);
        for (params) |T| str = str ++ ", " ++ @typeName(T);
        const arg_end = str.len;
        str = str ++ ") " ++ @typeName(ReturnType);
        break :blk .{ str, str["fn (".len..arg_end] };
    };
    if (!@hasDecl(Base, name)) {
        compileError("{any}.{s}({s}) missing", .{ Base, name, fn_args_str });
    }
    const bad_fn_msg = std.fmt.comptimePrint("{any}.{s} must be a method of type {s}", .{
        Base, name, fn_type_str,
    });
    const info = sw: switch (@typeInfo(@TypeOf(@field(Base, name)))) {
        .@"fn" => |info| info,
        .pointer => |ptr| {
            if (@typeInfo(ptr.child) != .@"fn") @compileError(bad_fn_msg);
            if (ptr.size != .one) @compileError(bad_fn_msg);
            if (!ptr.is_const) @compileError(bad_fn_msg);
            break :sw @typeInfo(ptr.child).@"fn";
        },
        else => @compileError(bad_fn_msg),
    };
    if (info.params.len != params.len + 1) @compileError(bad_fn_msg);
    if (info.params[0].type) |SelfType| switch (SelfType) {
        Base, *Base, *const Base => {},
        else => switch (@typeInfo(SelfType)) {
            .pointer => |ptr| if (ptr.child != Base or ptr.size != .one) @compileError(bad_fn_msg),
            else => @compileError(bad_fn_msg),
        },
    };
    for (params, info.params[1..]) |T, p| {
        if (p.type != T) @compileError(bad_fn_msg);
    }
    // TODO: Make a 'canBeCastedTo' funtion
    if (info.return_type.? != ReturnType) @compileError(bad_fn_msg);
}

test {
    std.testing.refAllDecls(@This());
    inline for (&[_]type{ u8, u16, u32, usize }) |T| {
        inline for (0..5) |alignment| {
            std.testing.refAllDecls(EmbeddedArray(.{
                .@"align" = 1 << alignment,
            }, T));
            std.testing.refAllDecls(EmbeddedArray(.{
                .@"volatile" = true,
                .@"align" = 1 << alignment,
            }, T));
            std.testing.refAllDecls(EmbeddedArray(.{
                .@"allowzero" = true,
                .@"align" = 1 << alignment,
            }, T));
            std.testing.refAllDecls(EmbeddedArray(.{
                .@"volatile" = true,
                .@"allowzero" = true,
                .@"align" = 1 << alignment,
            }, T));
        }
    }
}
