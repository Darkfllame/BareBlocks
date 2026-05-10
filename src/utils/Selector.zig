const Selector = @This();
const std = @import("std");
const Identifier = @import("Identifier.zig");

const math = std.math;
const Allocator = std.mem.Allocator;
const minInt = math.minInt;
const maxInt = math.maxInt;
const floatMin = math.floatMin;
const floatMax = math.floatMax;
const assert = std.debug.assert;
const eql = std.mem.eql;

arena_state: std.heap.ArenaAllocator.State = .{},

args_mask: ArgumentsMask = .{},
args: Arguments = undefined,

type: ?[]const u8 = null,
scores: []const Arguments.Score = &.{},
tags: Arguments.ExcludableSet = .any,
teams: Arguments.ExcludableSet = .any,
name: union(enum) { any, equal: []const u8, exclude: []const []const u8 } = .any,
family: []const Arguments.ExcludableString = &.{},
predicates: []const Arguments.Predicate = &.{},

limit: u32 = maxInt(u32),
sort: enum { nearest, furthest, random, arbitrary } = .arbitrary,

pub const at_p = Selector{ .type = "player", .limit = 1, .sort = .nearest };
pub const at_r = Selector{ .type = "player", .limit = 1, .sort = .random };
pub const at_a = Selector{ .type = "player", .sort = .arbitrary };
pub const at_e = Selector{ .sort = .arbitrary };
pub const at_n = Selector{ .sort = .nearest };

pub const ArgumentsMask = struct {
    const Packed = blk: {
        const info = @typeInfo(Arguments).@"struct";
        var types = [_]type{bool} ** info.fields.len;
        var names: [info.fields.len][]const u8 = undefined;
        for (info.fields, &names) |f, *out| {
            out.* = f.name;
        }

        break :blk @Struct(
            .@"packed",
            @Int(.unsigned, info.fields.len),
            &names,
            &types,
            &([_]std.builtin.Type.StructField.Attributes{
                .{ .default_value_ptr = &@as(bool, false) },
            } ** info.fields.len),
        );
    };

    sub: Packed = .{},

    pub fn new(sub: Packed) ArgumentsMask {
        return .{ .sub = sub };
    }

    pub fn get(self: ArgumentsMask, fmt: Arguments, comptime field: std.meta.FieldEnum(Arguments)) ?@FieldType(Arguments, @tagName(field)) {
        return if (@field(self.sub, @tagName(field)))
            @field(fmt, @tagName(field))
        else
            null;
    }

    pub fn set(self: *ArgumentsMask, fmt: *Arguments, comptime field: std.meta.FieldEnum(Arguments), v: ?@FieldType(Arguments, @tagName(field))) void {
        @field(self.sub, @tagName(field)) = v != null;
        @field(fmt, @tagName(field)) = v orelse undefined;
    }

    pub fn has(self: ArgumentsMask, comptime field: std.meta.FieldEnum(Arguments)) bool {
        return @field(self.dub, @tagName(field));
    }
};
pub const Arguments = struct {
    x: f64,
    y: f64,
    z: f64,
    dx: f64,
    dy: f64,
    dz: f64,
    distance: Range(f64),
    /// pitch
    x_rotation: Range(f64),
    /// yaw
    y_rotation: Range(f64),

    pub const Score = struct { name: []const u8, range: Range(i32) };

    pub const ExcludableString = struct { exclude: bool, name: []const u8 };
    pub const Predicate = struct { exclude: bool, id: Identifier };
    pub const ExcludableSet = union(enum) {
        any,
        zero,
        not_zero,
        many: []const Arguments.ExcludableString,

        fn dupe(self: ExcludableSet, allocator: Allocator) Allocator.Error!ExcludableSet {
            return switch (self.tags) {
                inline .any, .zero, .not_zero => |_, tag| tag,
                .many => |es| many: {
                    const strings = try allocator.alloc(Arguments.ExcludableString, es.len);
                    for (strings, es) |*out, in| {
                        out.* = .{
                            .exclude = in.exclude,
                            .name = try allocator.dupe(u8, in.name),
                        };
                    }
                    break :many .{ .many = strings };
                },
            };
        }
    };
};

pub fn Range(comptime T: type) type {
    const minT, const maxT = switch (@typeInfo(T)) {
        .int => .{ minInt(T), maxInt(T) },
        .float => .{ floatMin(T), floatMax(T) },
        else => @compileError("Unkown numeric type: " ++ @typeName(T)),
    };
    return struct {
        min: T = minT,
        max: T = maxT,

        pub fn init(min: ?T, max: ?T) @This() {
            const real_min = min orelse minT;
            const real_max = max orelse maxT;
            assert(real_min <= real_max);

            return .{ .min = real_min, .max = real_max };
        }

        pub inline fn clamp(self: @This(), v: T) T {
            return math.clamp(v, self.min, self.max);
        }

        pub inline fn inRange(self: @This(), v: T) bool {
            return self.min <= v and v <= self.max;
        }
    };
}

pub fn deinit(self: Selector, gpa: Allocator) void {
    self.arena_state.promote(gpa).deinit();
}

/// TODO: Implement more (?)
pub fn format(self: Selector, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.type) |t| {
        if (eql(u8, t, "player")) {
            if (self.limit == 1) {
                return writer.writeAll(if (self.sort == .nearest) "@p" else "@r");
            } else if (self.sort == .arbitrary) {
                return writer.writeAll("@a");
            }
        }
    }
    return writer.writeAll(if (self.sort == .nearest) "@n" else "@e");
}

pub fn clone(self: Selector, gpa: Allocator) Allocator.Error!Selector {
    var aa = std.heap.ArenaAllocator.init(gpa);
    errdefer aa.deinit();
    const arena = aa.allocator();

    var sel = try self.cloneLeaky(arena);
    sel.arena_state = aa.state;
    return sel;
}

pub fn cloneLeaky(self: Selector, allocator: Allocator) Allocator.Error!Selector {
    var res: Selector = .{};
    res.type = if (self.type) |t| try allocator.dupe(u8, t) else null;
    res.scores = try allocator.alloc(Arguments.Score, res.scores.len);
    for (res.scores, self.scores) |*out, in| {
        out.* = .{
            .name = try allocator.dupe(u8, in.name),
            .range = in.range,
        };
    }
    res.tags = try self.tags.dupe(allocator);
    res.teams = try self.teams.dupe(allocator);
    res.name = switch (self.name) {
        .any => .any,
        .equal => |str| .{ .equal = try allocator.dupe(u8, str) },
        .exclude => |exc| exclude: {
            const list = try allocator.alloc([]const u8, u8);
            for (list, exc) |*out, in| {
                out.* = try allocator.dupe(u8, in);
            }
            break :exclude .{ .exclude = list };
        },
    };
    res.family = try allocator.alloc(Arguments.ExcludableString, self.family.len);
    for (res.family, self.family) |*out, in| {
        out.* = .{
            .exclude = in.exclude,
            .name = try allocator.dupe(u8, in.name),
        };
    }
    res.predicates = try allocator.alloc(Arguments.Predicate, self.predicates.len);
    for (res.predicates, self.predicates) |*out, in| {
        out.* = .{
            .exclude = in.exclude,
            .id = try in.id.dupe(allocator),
        };
    }
    res.limit = self.limit;
    res.sort = self.sort;

    return res;
}
