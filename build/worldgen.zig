//! Turns the data generator's worldgen/ files into Zig data, src/worldgen/data.zig has the types.
//!
//! Density functions and splines that are equal get the same index, vanilla shares its caches
//! between equal functions (references are only equal to themselves, like `Holder`s).
const Generator = @This();
const std = @import("std");
const serial = @import("serial");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = serial.Value;

const Named = std.StringArrayHashMapUnmanaged(Value);
/// Zig literal -> its index
const Interned = std.StringArrayHashMapUnmanaged(void);

const Error = Allocator.Error || error{ UnexpectedToken, MissingField, UnknownReference, Unsupported };

arena: Allocator,
noises: Named = .empty,
named_functions: Named = .empty,
named_rules: Named = .empty,
named_conditions: Named = .empty,
biomes: []const []const u8 = &.{},

functions: Interned = .empty,
splines: Interned = .empty,
rules: std.ArrayList([]const u8) = .empty,
conditions: std.ArrayList([]const u8) = .empty,
resolved_rules: std.StringHashMapUnmanaged(u32) = .empty,
resolved_conditions: std.StringHashMapUnmanaged(u32) = .empty,

const unary = [_][]const u8{ "abs", "square", "cube", "sqrt", "half_negative", "quarter_negative", "reciprocal", "negate", "squeeze", "log", "sign" };
const binary = [_][]const u8{ "add", "sub", "mul", "div", "min", "max" };

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every json file of a worldgen directory, sorted by id.
fn loadDir(self: *Generator, io: Io, worldgen: Io.Dir, path: []const u8) !Named {
    var dir = try worldgen.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(self.arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        try names.append(self.arena, try self.arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    var out: Named = .empty;
    for (names.items) |name| {
        const content = try dir.readFileAlloc(io, name, self.arena, .unlimited);
        var input: Io.Reader = .fixed(content);
        var json_r: serial.JsonReader = undefined;
        // Not deinitialized, the values live in the reader's arena
        json_r.init(self.arena, &input);

        const id = try std.fmt.allocPrint(self.arena, "minecraft:{s}", .{name[0 .. name.len - ".json".len]});
        try out.put(self.arena, id, try Value.deserialize(&json_r.mapr));
    }
    return out;
}

fn print(self: *Generator, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(self.arena, fmt, args);
}

fn intern(self: *Generator, list: *Interned, literal: []const u8) Allocator.Error!u32 {
    const gop = try list.getOrPut(self.arena, literal);
    return @intCast(gop.index);
}

fn field(v: Value, name: []const u8) Error!Value {
    if (v != .aggregate) return error.UnexpectedToken;
    return v.aggregate.get(name) orelse error.MissingField;
}

fn optional(v: Value, name: []const u8) ?Value {
    return v.aggregate.get(name);
}

fn string(v: Value) Error![]const u8 {
    return if (v == .string) v.string else error.UnexpectedToken;
}

fn int(v: Value) Error!i64 {
    return switch (v) {
        .byte, .short, .int, .long => v.asInt().?,
        else => error.UnexpectedToken,
    };
}

fn boolean(v: Value) Error!bool {
    return if (v == .boolean) v.boolean else error.UnexpectedToken;
}

/// The shortest decimal that parses back to the same double, so a float made from it is
/// the same as Java parsing the file's text.
fn float(self: *Generator, v: Value) Error![]const u8 {
    const f = switch (v) {
        .byte, .short, .int, .long, .float, .double => v.asFloat().?,
        else => return error.UnexpectedToken,
    };
    if (!std.math.isFinite(f)) return error.Unsupported;
    if (f == 0 and std.math.signbit(f)) return "-0.0";
    const text = try self.print("{d}", .{f});
    // An integer literal has to be exactly representable, a float one gets rounded
    if (std.mem.indexOfAny(u8, text, ".e") != null) return text;
    return self.print("{s}.0", .{text});
}

fn withoutNamespace(id: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, id, "minecraft:")) id["minecraft:".len..] else id;
}

fn withNamespace(self: *Generator, id: []const u8) Allocator.Error![]const u8 {
    return if (std.mem.indexOfScalar(u8, id, ':') == null) self.print("minecraft:{s}", .{id}) else id;
}

fn noise(self: *Generator, v: Value) Error!usize {
    return self.noises.getIndex(try self.withNamespace(try string(v))) orelse error.UnknownReference;
}

fn function(self: *Generator, v: Value) Error!u32 {
    return self.intern(&self.functions, try self.functionLiteral(v));
}

fn functionLiteral(self: *Generator, v: Value) Error![]const u8 {
    switch (v) {
        .string => |name| {
            const index = self.named_functions.getIndex(try self.withNamespace(name)) orelse return error.UnknownReference;
            return self.print(".{{ .reference = {d} }}", .{index});
        },
        .aggregate => {},
        else => return self.print(".{{ .constant = {s} }}", .{try self.float(v)}),
    }

    const kind = withoutNamespace(try string(try field(v, "type")));
    for (unary) |op| {
        if (!std.mem.eql(u8, kind, op)) continue;
        return self.print(".{{ .unary = .{{ .op = .{s}, .input = {d} }} }}", .{ op, try self.function(try field(v, "input")) });
    }
    for (binary) |op| {
        if (!std.mem.eql(u8, kind, op)) continue;
        return self.print(".{{ .binary = .{{ .op = .{s}, .left = {d}, .right = {d} }} }}", .{
            op,
            try self.function(try field(v, "left")),
            try self.function(try field(v, "right")),
        });
    }

    const Kind = enum {
        constant,
        clamp,
        lerp,
        range_choice,
        interval_select,
        cache,
        interpolated,
        slice,
        find_top_surface,
        blend_density,
        blend_alpha,
        blend_offset,
        beardifier,
        noise,
        shift_a,
        shift_b,
        shift,
        gradient,
        spline,
        old_blended_noise,
    };
    switch (std.meta.stringToEnum(Kind, kind) orelse return self.print(".{{ .unsupported = \"{s}\" }}", .{kind})) {
        .constant => return self.print(".{{ .constant = {s} }}", .{try self.float(try field(v, "value"))}),
        .clamp => return self.print(".{{ .clamp = .{{ .input = {d}, .min = {s}, .max = {s} }} }}", .{
            try self.function(try field(v, "input")),
            try self.float(try field(v, "min")),
            try self.float(try field(v, "max")),
        }),
        .lerp => return self.print(".{{ .lerp = .{{ .alpha = {d}, .first = {d}, .second = {d} }} }}", .{
            try self.function(try field(v, "alpha")),
            try self.function(try field(v, "first")),
            try self.function(try field(v, "second")),
        }),
        .range_choice => return self.print(
            ".{{ .range_choice = .{{ .input = {d}, .min_inclusive = {s}, .max_exclusive = {s}, .when_in_range = {d}, .when_out_of_range = {d} }} }}",
            .{
                try self.function(try field(v, "input")),
                try self.float(try field(v, "min_inclusive")),
                try self.float(try field(v, "max_exclusive")),
                try self.function(try field(v, "when_in_range")),
                try self.function(try field(v, "when_out_of_range")),
            },
        ),
        .interval_select => {
            const thresholds = try field(v, "thresholds");
            const functions = try field(v, "functions");
            if (thresholds != .array or functions != .array) return error.UnexpectedToken;

            var aw: Io.Writer.Allocating = .init(self.arena);
            const w = &aw.writer;
            const input = try self.function(try field(v, "input"));
            w.print(".{{ .interval_select = .{{ .input = {d}, .thresholds = &.{{", .{input}) catch return error.OutOfMemory;
            for (0..thresholds.array.len) |i| {
                w.print("{s},", .{try self.float(thresholds.array.get(i))}) catch return error.OutOfMemory;
            }
            w.writeAll("}, .functions = &.{") catch return error.OutOfMemory;
            for (0..functions.array.len) |i| {
                w.print("{d},", .{try self.function(functions.array.get(i))}) catch return error.OutOfMemory;
            }
            w.writeAll("} } }") catch return error.OutOfMemory;
            return aw.written();
        },
        .cache => return self.print(".{{ .cache = {d} }}", .{try self.function(try field(v, "input"))}),
        .interpolated => return self.print(".{{ .interpolated = .{{ .input = {d}, .cell_size_xz = {d}, .cell_size_y = {d} }} }}", .{
            try self.function(try field(v, "input")),
            try int(try field(v, "cell_size_xz")),
            try int(try field(v, "cell_size_y")),
        }),
        .slice => return self.print(".{{ .slice = .{{ .axis = .{s}, .coordinate = {d}, .input = {d} }} }}", .{
            try string(try field(v, "axis")),
            try int(try field(v, "coordinate")),
            try self.function(try field(v, "input")),
        }),
        .find_top_surface => return self.print(
            ".{{ .find_top_surface = .{{ .density = {d}, .upper_bound = {d}, .lower_bound = {d}, .cell_height = {d} }} }}",
            .{
                try self.function(try field(v, "density")),
                try self.function(try field(v, "upper_bound")),
                try int(try field(v, "lower_bound")),
                try int(try field(v, "cell_height")),
            },
        ),
        .blend_density => return self.print(".{{ .blend_density = {d} }}", .{try self.function(try field(v, "input"))}),
        .blend_alpha => return ".blend_alpha",
        .blend_offset => return ".blend_offset",
        .beardifier => return ".beardifier",
        .noise => {
            var shifts: [3]u32 = undefined;
            for (&shifts, [_][]const u8{ "shift_x", "shift_y", "shift_z" }) |*shift, name| {
                shift.* = if (optional(v, name)) |s| try self.function(s) else try self.intern(&self.functions, ".{ .constant = 0.0 }");
            }
            return self.print(
                ".{{ .noise = .{{ .noise = {d}, .xz_scale = {s}, .y_scale = {s}, .shift_x = {d}, .shift_y = {d}, .shift_z = {d} }} }}",
                .{
                    try self.noise(try field(v, "noise")),
                    try self.float(try field(v, "xz_scale")),
                    try self.float(try field(v, "y_scale")),
                    shifts[0],
                    shifts[1],
                    shifts[2],
                },
            );
        },
        inline .shift_a, .shift_b, .shift => |tag| return self.print(".{{ ." ++ @tagName(tag) ++ " = {d} }}", .{try self.noise(try field(v, "noise"))}),
        .gradient => return self.print(
            ".{{ .gradient = .{{ .axis = .{s}, .tiling = .{s}, .from_coordinate = {d}, .to_coordinate = {d}, .from_value = {s}, .to_value = {s} }} }}",
            .{
                try string(try field(v, "axis")),
                if (optional(v, "tiling")) |t| try string(t) else "clamp_to_edge",
                try int(try field(v, "from_coordinate")),
                try int(try field(v, "to_coordinate")),
                try self.float(try field(v, "from_value")),
                try self.float(try field(v, "to_value")),
            },
        ),
        .spline => return self.print(".{{ .spline = {d} }}", .{try self.spline(try field(v, "spline"))}),
        .old_blended_noise => return self.print(
            ".{{ .old_blended_noise = .{{ .xz_scale = {s}, .y_scale = {s}, .xz_factor = {s}, .y_factor = {s}, .smear_scale_multiplier = {s} }} }}",
            .{
                try self.float(try field(v, "xz_scale")),
                try self.float(try field(v, "y_scale")),
                try self.float(try field(v, "xz_factor")),
                try self.float(try field(v, "y_factor")),
                try self.float(try field(v, "smear_scale_multiplier")),
            },
        ),
    }
}

fn spline(self: *Generator, v: Value) Error!u32 {
    if (v != .aggregate) return self.intern(&self.splines, try self.print(".{{ .constant = {s} }}", .{try self.float(v)}));

    const points = try field(v, "points");
    if (points != .array) return error.UnexpectedToken;

    var locations: Io.Writer.Allocating = .init(self.arena);
    var values: Io.Writer.Allocating = .init(self.arena);
    var derivatives: Io.Writer.Allocating = .init(self.arena);
    for (0..points.array.len) |i| {
        const point = points.array.get(i);
        locations.writer.print("{s},", .{try self.float(try field(point, "location"))}) catch return error.OutOfMemory;
        values.writer.print("{d},", .{try self.spline(try field(point, "value"))}) catch return error.OutOfMemory;
        derivatives.writer.print("{s},", .{try self.float(try field(point, "derivative"))}) catch return error.OutOfMemory;
    }
    return self.intern(&self.splines, try self.print(
        ".{{ .multipoint = .{{ .coordinate = {d}, .locations = &.{{{s}}}, .values = &.{{{s}}}, .derivatives = &.{{{s}}} }} }}",
        .{ try self.function(try field(v, "coordinate")), locations.written(), values.written(), derivatives.written() },
    ));
}

/// Only block states without properties for now, vanilla's rules don't have any other.
fn blockState(self: *Generator, v: Value) Error![]const u8 {
    switch (v) {
        .string => |name| return self.withNamespace(name),
        .aggregate => |agg| {
            if (agg.get("Properties")) |props| {
                if (props != .aggregate or props.aggregate.count != 0) return error.Unsupported;
            }
            return self.withNamespace(try string(try field(v, "Name")));
        },
        else => return error.UnexpectedToken,
    }
}

fn anchor(self: *Generator, v: Value) Error![]const u8 {
    inline for (.{ "absolute", "above_bottom", "below_top" }) |kind| {
        if (optional(v, kind)) |y| return self.print(".{{ ." ++ kind ++ " = {d} }}", .{try int(y)});
    }
    return error.Unsupported;
}

fn rule(self: *Generator, v: Value) Error!u32 {
    if (v == .string) {
        const name = try self.withNamespace(v.string);
        if (self.resolved_rules.get(name)) |id| return id;
        const id = try self.rule(self.named_rules.get(name) orelse return error.UnknownReference);
        try self.resolved_rules.put(self.arena, name, id);
        return id;
    }

    const Kind = enum { block, bandlands, sequence, condition, ore_vein };
    const kind = withoutNamespace(try string(try field(v, "type")));
    const literal = switch (std.meta.stringToEnum(Kind, kind) orelse return error.Unsupported) {
        .block => try self.print(".{{ .block = \"{s}\" }}", .{try self.blockState(try field(v, "result_state"))}),
        .bandlands => ".bandlands",
        .sequence => blk: {
            const sequence = try field(v, "sequence");
            if (sequence != .array) return error.UnexpectedToken;
            var aw: Io.Writer.Allocating = .init(self.arena);
            aw.writer.writeAll(".{ .sequence = &.{") catch return error.OutOfMemory;
            for (0..sequence.array.len) |i| {
                aw.writer.print("{d},", .{try self.rule(sequence.array.get(i))}) catch return error.OutOfMemory;
            }
            aw.writer.writeAll("} }") catch return error.OutOfMemory;
            break :blk aw.written();
        },
        .condition => try self.print(".{{ .condition = .{{ .if_true = {d}, .then_run = {d} }} }}", .{
            try self.condition(try field(v, "if_true")),
            try self.rule(try field(v, "then_run")),
        }),
        .ore_vein => try self.print(
            ".{{ .ore_vein = .{{ .ore_block = \"{s}\", .raw_ore_block = \"{s}\", .filler_block = \"{s}\", .raw_ore_chance = {s}, .density = {d}, .richness = {d}, .filler_gap = {d} }} }}",
            .{
                try self.blockState(try field(v, "ore_block")),
                try self.blockState(try field(v, "raw_ore_block")),
                try self.blockState(try field(v, "filler_block")),
                try self.float(try field(v, "raw_ore_chance")),
                try self.function(try field(v, "density")),
                try self.function(try field(v, "richness")),
                try self.function(try field(v, "filler_gap")),
            },
        ),
    };
    try self.rules.append(self.arena, literal);
    return @intCast(self.rules.items.len - 1);
}

fn biome(self: *Generator, v: Value) Error!usize {
    const name = try self.withNamespace(try string(v));
    for (self.biomes, 0..) |b, i| {
        if (std.mem.eql(u8, b, name)) return i;
    }
    // Tags aren't used by vanilla's rules
    return if (std.mem.startsWith(u8, name, "#")) error.Unsupported else error.UnknownReference;
}

fn condition(self: *Generator, v: Value) Error!u32 {
    if (v == .string) {
        const name = try self.withNamespace(v.string);
        if (self.resolved_conditions.get(name)) |id| return id;
        const id = try self.condition(self.named_conditions.get(name) orelse return error.UnknownReference);
        try self.resolved_conditions.put(self.arena, name, id);
        return id;
    }

    const Kind = enum { biome, noise_threshold, vertical_gradient, y_above, water, temperature, steep, not, hole, above_preliminary_surface, stone_depth };
    const kind = withoutNamespace(try string(try field(v, "type")));
    const literal = switch (std.meta.stringToEnum(Kind, kind) orelse return error.Unsupported) {
        .biome => blk: {
            const biomes = try field(v, "biome_is");
            var aw: Io.Writer.Allocating = .init(self.arena);
            aw.writer.writeAll(".{ .biome = &.{") catch return error.OutOfMemory;
            if (biomes == .array) {
                for (0..biomes.array.len) |i| {
                    aw.writer.print("{d},", .{try self.biome(biomes.array.get(i))}) catch return error.OutOfMemory;
                }
            } else {
                aw.writer.print("{d}", .{try self.biome(biomes)}) catch return error.OutOfMemory;
            }
            aw.writer.writeAll("} }") catch return error.OutOfMemory;
            break :blk aw.written();
        },
        .noise_threshold => try self.print(".{{ .noise_threshold = .{{ .noise = {d}, .min = {s}, .max = {s}, .is_3d = {} }} }}", .{
            try self.noise(try field(v, "noise")),
            try self.float(try field(v, "min_threshold")),
            try self.float(try field(v, "max_threshold")),
            if (optional(v, "is_3d")) |b| try boolean(b) else false,
        }),
        .vertical_gradient => try self.print(
            ".{{ .vertical_gradient = .{{ .random_name = \"{s}\", .true_at_and_below = {s}, .false_at_and_above = {s} }} }}",
            .{
                try self.withNamespace(try string(try field(v, "random_name"))),
                try self.anchor(try field(v, "true_at_and_below")),
                try self.anchor(try field(v, "false_at_and_above")),
            },
        ),
        .y_above => try self.print(".{{ .y_above = .{{ .anchor = {s}, .surface_depth_multiplier = {d}, .add_stone_depth = {} }} }}", .{
            try self.anchor(try field(v, "anchor")),
            try int(try field(v, "surface_depth_multiplier")),
            try boolean(try field(v, "add_stone_depth")),
        }),
        .water => try self.print(".{{ .water = .{{ .offset = {d}, .surface_depth_multiplier = {d}, .add_stone_depth = {} }} }}", .{
            try int(try field(v, "offset")),
            try int(try field(v, "surface_depth_multiplier")),
            try boolean(try field(v, "add_stone_depth")),
        }),
        .stone_depth => try self.print(
            ".{{ .stone_depth = .{{ .offset = {d}, .add_surface_depth = {}, .secondary_depth_range = {d}, .surface_type = .{s} }} }}",
            .{
                try int(try field(v, "offset")),
                try boolean(try field(v, "add_surface_depth")),
                try int(try field(v, "secondary_depth_range")),
                try string(try field(v, "surface_type")),
            },
        ),
        .not => try self.print(".{{ .not = {d} }}", .{try self.condition(try field(v, "invert"))}),
        inline .temperature, .steep, .hole, .above_preliminary_surface => |tag| "." ++ @tagName(tag),
    };
    try self.conditions.append(self.arena, literal);
    return @intCast(self.conditions.items.len - 1);
}

/// `synced` is DumpVanilla's registries (biomes get their network ids from it), `biome_parameters` its
/// multi noise presets.
pub fn generate(
    arena: Allocator,
    io: Io,
    data_dir: Io.Dir,
    synced: []const u8,
    biome_parameters: []const u8,
    out: *Io.Writer,
) !void {
    var self: Generator = .{ .arena = arena };

    var worldgen = try data_dir.openDir(io, "data/minecraft/worldgen", .{});
    defer worldgen.close(io);

    self.noises = try self.loadDir(io, worldgen, "noise");
    self.named_functions = try self.loadDir(io, worldgen, "density_function");
    self.named_rules = try self.loadDir(io, worldgen, "material_rule");
    self.named_conditions = try self.loadDir(io, worldgen, "material_condition");
    const biomes = try self.loadDir(io, worldgen, "biome");
    const noise_settings = try self.loadDir(io, worldgen, "noise_settings");

    var lines = std.mem.tokenizeScalar(u8, synced, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next().?, "registry")) continue;
        if (!std.mem.eql(u8, parts.next() orelse return error.BadSyncedRegistries, "minecraft:worldgen/biome")) continue;

        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, parts.next() orelse return error.BadSyncedRegistries, ',');
        while (it.next()) |name| try names.append(arena, name);
        self.biomes = names.items;
    }
    if (self.biomes.len == 0) return error.BadSyncedRegistries;

    // Everything first, the functions get their indices on the way
    const named_function_ids = try arena.alloc(u32, self.named_functions.count());
    for (named_function_ids, self.named_functions.values()) |*id, v| id.* = try self.function(v);

    const Settings = struct { id: []const u8, literal: []const u8 };
    var settings: std.ArrayList(Settings) = .empty;
    for (noise_settings.keys(), noise_settings.values()) |id, v| {
        const noise_shape = try field(v, "noise");
        const router = try field(v, "noise_router");
        try settings.append(arena, .{ .id = id, .literal = try self.print(
            \\.{{
            \\    .id = "{s}",
            \\    .min_y = {d},
            \\    .height = {d},
            \\    .sea_level = {d},
            \\    .default_block = "{s}",
            \\    .default_fluid = "{s}",
            \\    .legacy_random_source = {},
            \\    .temperature = {d},
            \\    .vegetation = {d},
            \\    .continents = {d},
            \\    .erosion = {d},
            \\    .depth = {d},
            \\    .ridges = {d},
            \\    .chunk_surface_level = {d},
            \\    .final_density = {d},
            \\    .material_rule = {d},
            \\}}
        , .{
            id,
            try int(try field(noise_shape, "min_y")),
            try int(try field(noise_shape, "height")),
            try int(try field(v, "sea_level")),
            try self.blockState(try field(v, "default_block")),
            try self.blockState(try field(v, "default_fluid")),
            try boolean(try field(v, "legacy_random_source")),
            try self.function(try field(router, "temperature")),
            try self.function(try field(router, "vegetation")),
            try self.function(try field(router, "continents")),
            try self.function(try field(router, "erosion")),
            try self.function(try field(router, "depth")),
            try self.function(try field(router, "ridges")),
            try self.function(try field(router, "chunk_surface_level")),
            try self.function(try field(router, "final_density")),
            try self.rule(try field(v, "material_rule")),
        }) });
    }

    try out.writeAll(
        \\/// `t` is src/worldgen/data.zig
        \\pub fn Data(comptime t: type) type {
        \\    return struct {
        \\        pub const noises = [_]t.NamedNoise{
        \\
    );
    for (self.noises.keys(), self.noises.values()) |id, v| {
        try out.print(".{{ .id = \"{s}\", .parameters = .{{ .base_octave = {d}", .{ id, try int(try field(v, "base_octave")) });
        if (optional(v, "base_amplitude")) |a| try out.print(", .base_amplitude = {s}", .{try self.float(a)});
        if (optional(v, "octave_count")) |c| try out.print(", .octave_count = {d}", .{try int(c)});
        if (optional(v, "normalize")) |n| {
            try out.print(", .normalize = .{s}", .{switch (n) {
                .boolean => |b| if (b) "enabled" else "disabled",
                .string => "legacy",
                else => return error.UnexpectedToken,
            }});
        }
        if (optional(v, "amplitude_modifiers")) |modifiers| {
            if (modifiers != .array) return error.UnexpectedToken;
            try out.writeAll(", .amplitude_modifiers = &.{");
            for (0..modifiers.array.len) |i| try out.print("{s},", .{try self.float(modifiers.array.get(i))});
            try out.writeAll("}");
        }
        try out.writeAll(" } },\n");
    }

    try out.writeAll("};\n\npub const functions = [_]t.DensityFunction{\n");
    for (self.functions.keys()) |literal| try out.print("{s},\n", .{literal});

    try out.writeAll("};\n\n/// What `DensityFunction.reference` is an index of.\npub const named_functions = [_]t.NamedFunction{\n");
    for (self.named_functions.keys(), named_function_ids) |id, function_id| {
        try out.print(".{{ .id = \"{s}\", .function = {d} }},\n", .{ id, function_id });
    }

    try out.writeAll("};\n\npub const splines = [_]t.Spline{\n");
    for (self.splines.keys()) |literal| try out.print("{s},\n", .{literal});

    try out.writeAll("};\n\npub const rules = [_]t.Rule{\n");
    for (self.rules.items) |literal| try out.print("{s},\n", .{literal});

    try out.writeAll("};\n\npub const conditions = [_]t.Condition{\n");
    for (self.conditions.items) |literal| try out.print("{s},\n", .{literal});

    try out.writeAll("};\n\n/// In the order of their network ids.\npub const biomes = [_]t.Biome{\n");
    for (self.biomes) |id| {
        const v = biomes.get(id) orelse return error.UnknownReference;
        try out.print(".{{ .id = \"{s}\", .temperature = {s}, .frozen = {} }},\n", .{
            id,
            try self.float(try field(v, "temperature")),
            if (optional(v, "temperature_modifier")) |m| std.mem.eql(u8, try string(m), "frozen") else false,
        });
    }

    try out.writeAll("};\n\npub const noise_settings = [_]t.NoiseSettings{\n");
    for (settings.items) |s| try out.print("{s},\n", .{s.literal});
    try out.writeAll("};\n\n");

    // `biome_parameters <preset> <biome> <min> <max> (x6) <offset>`, a preset's lines are together
    var preset: ?[]const u8 = null;
    lines = std.mem.tokenizeScalar(u8, biome_parameters, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next().?, "biome_parameters")) continue;
        const name = parts.next() orelse return error.BadBiomeParameters;
        if (preset == null or !std.mem.eql(u8, preset.?, name)) {
            if (preset != null) try out.writeAll("};\n\n");
            preset = name;
            try out.print("/// The multi noise biome source's `{s}` preset, already quantized.\n", .{name});
            try out.print("pub const {s}_biomes = [_]t.BiomeParameters{{\n", .{withoutNamespace(name)});
        }
        const biome_id = try self.biome(.{ .string = parts.next() orelse return error.BadBiomeParameters });
        try out.print(".{{ .biome = {d}, .parameters = .{{", .{biome_id});
        for (0..6) |_| {
            const min = parts.next() orelse return error.BadBiomeParameters;
            const max = parts.next() orelse return error.BadBiomeParameters;
            try out.print(".{{ {s}, {s} }},", .{ min, max });
        }
        const offset = parts.next() orelse return error.BadBiomeParameters;
        try out.print(".{{ {s}, {s} }} }} }},\n", .{ offset, offset });
    }
    if (preset != null) try out.writeAll("};\n");

    try out.writeAll("};\n}\n");
}
