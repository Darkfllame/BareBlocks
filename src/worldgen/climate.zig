//! Picks biomes from climate (vanilla's `Climate`): every biome has a range of temperature, humidity,
//! continentalness, erosion, depth and weirdness, the closest one to a position's values wins.
const std = @import("std");
const java = @import("java.zig");
const data = @import("data.zig");

const Allocator = std.mem.Allocator;

/// Temperature, humidity, continentalness, erosion, depth, weirdness, and 0 for the biomes' offsets.
pub const Target = [7]i64;

/// `Climate.quantizeCoord`
pub fn quantize(coord: f32) i64 {
    return java.toLong(coord * 10000.0);
}

pub fn target(temperature: f32, humidity: f32, continentalness: f32, erosion: f32, depth: f32, weirdness: f32) Target {
    return .{ quantize(temperature), quantize(humidity), quantize(continentalness), quantize(erosion), quantize(depth), quantize(weirdness), 0 };
}

const Range = struct {
    min: i64,
    max: i64,

    fn distance(self: Range, value: i64) i64 {
        const above = value - self.max;
        const below = self.min - value;
        if (above > 0) return above;
        return @max(below, 0);
    }

    fn center(self: Range) i64 {
        return @divTrunc(self.min + self.max, 2);
    }
};

const Node = struct {
    space: [7]Range,
    /// Empty for leaves.
    children: []Node = &.{},
    biome: data.BiomeId = undefined,

    fn distance(self: *const Node, t: Target) i64 {
        var sum: i64 = 0;
        for (self.space, t) |range, value| {
            const d = range.distance(value);
            sum += d * d;
        }
        return sum;
    }

    fn search(self: *const Node, t: Target, candidate: ?*const Node) *const Node {
        if (self.children.len == 0) return self;

        var min_distance: i64 = if (candidate) |c| c.distance(t) else std.math.maxInt(i64);
        var closest = candidate;
        for (self.children) |*child| {
            const child_distance = child.distance(t);
            if (min_distance <= child_distance) continue;
            const leaf = child.search(t, closest);
            const leaf_distance = if (leaf == child) child_distance else leaf.distance(t);
            if (min_distance <= leaf_distance) continue;
            min_distance = leaf_distance;
            closest = leaf;
        }
        return closest.?;
    }
};

/// The biomes in a tree of their ranges (`Climate.RTree`). Built the same way as vanilla's:
/// the order of the nodes decides which biome wins when two are as close.
pub const ParameterList = struct {
    root: Node,

    const children_per_node = 19;

    pub fn init(arena: Allocator, biomes: []const data.BiomeParameters) Allocator.Error!ParameterList {
        const leaves = try arena.alloc(Node, biomes.len);
        for (leaves, biomes) |*leaf, biome| {
            for (&leaf.space, biome.parameters) |*range, p| range.* = .{ .min = p[0], .max = p[1] };
            leaf.children = &.{};
            leaf.biome = biome.biome;
        }
        return .{ .root = try build(arena, leaves) };
    }

    fn subTree(children: []Node) Node {
        var node: Node = .{ .space = children[0].space, .children = children };
        for (children[1..]) |child| {
            for (&node.space, child.space) |*range, other| {
                range.min = @min(range.min, other.min);
                range.max = @max(range.max, other.max);
            }
        }
        return node;
    }

    fn magnitudeLessThan(_: void, a: Node, b: Node) bool {
        var total_a: i64 = 0;
        var total_b: i64 = 0;
        for (a.space, b.space) |range_a, range_b| {
            total_a += @intCast(@abs(range_a.center()));
            total_b += @intCast(@abs(range_b.center()));
        }
        return total_a < total_b;
    }

    const CenterOrder = struct {
        dimension: usize,
        absolute: bool,

        /// By the center on the dimension, then on the next ones.
        fn lessThan(self: CenterOrder, a: Node, b: Node) bool {
            for (0..7) |d| {
                const dimension = (self.dimension + d) % 7;
                var center_a = a.space[dimension].center();
                var center_b = b.space[dimension].center();
                if (self.absolute) {
                    center_a = @intCast(@abs(center_a));
                    center_b = @intCast(@abs(center_b));
                }
                if (center_a != center_b) return center_a < center_b;
            }
            return false;
        }
    };

    fn cost(space: [7]Range) i64 {
        var result: i64 = 0;
        for (space) |range| result += @intCast(@abs(range.max - range.min));
        return result;
    }

    /// Groups of nodes, as many in each as a full tree one level lower has leaves.
    fn bucketize(arena: Allocator, nodes: []const Node) Allocator.Error![]Node {
        const size: f64 = @floatFromInt(nodes.len);
        const levels = @floor(@log(size - 0.01) / @log(@as(f64, children_per_node)));
        const expected: usize = @intCast(java.toInt(std.math.pow(f64, children_per_node, levels)));

        var buckets: std.ArrayList(Node) = .empty;
        var start: usize = 0;
        while (start < nodes.len) : (start += expected) {
            const end = @min(start + expected, nodes.len);
            try buckets.append(arena, subTree(try arena.dupe(Node, nodes[start..end])));
        }
        return buckets.items;
    }

    fn build(arena: Allocator, children: []Node) Allocator.Error!Node {
        if (children.len == 1) return children[0];
        if (children.len <= children_per_node) {
            std.sort.block(Node, children, {}, magnitudeLessThan);
            return subTree(children);
        }

        // The dimension that splits them the tightest
        var min_cost: i64 = std.math.maxInt(i64);
        var min_dimension: usize = 0;
        var min_buckets: []Node = &.{};
        for (0..7) |d| {
            std.sort.block(Node, children, CenterOrder{ .dimension = d, .absolute = false }, CenterOrder.lessThan);
            const buckets = try bucketize(arena, children);
            var total_cost: i64 = 0;
            for (buckets) |bucket| total_cost += cost(bucket.space);
            if (min_cost <= total_cost) continue;
            min_cost = total_cost;
            min_dimension = d;
            min_buckets = buckets;
        }
        std.sort.block(Node, min_buckets, CenterOrder{ .dimension = min_dimension, .absolute = true }, CenterOrder.lessThan);
        for (min_buckets) |*bucket| bucket.* = try build(arena, bucket.children);
        return subTree(min_buckets);
    }

    /// Where the caller's previous search ended (vanilla keeps one per thread), the next one starts
    /// from it: positions next to each other are mostly the same biome.
    pub const Search = struct { last: ?*const Node = null };

    pub fn find(self: *const ParameterList, t: Target, search: *Search) data.BiomeId {
        const leaf = self.root.search(t, search.last);
        search.last = leaf;
        return leaf.biome;
    }
};

/// What's added to the seed for the biome zoom: the first 8 bytes of its sha256 (`BiomeManager.obfuscateSeed`).
pub fn obfuscateSeed(seed: i64) i64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, seed, .little);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &hash, .{});
    return std.mem.readInt(i64, hash[0..8], .little);
}

fn lcg(seed: i64, salt: i64) i64 {
    return seed *% (seed *% 6364136223846793005 +% 1442695040888963407) +% salt;
}

fn fiddle(seed: i64) f64 {
    const uniform = @as(f64, @floatFromInt(@mod(seed >> 24, 1024))) / 1024.0;
    return (uniform - 0.5) * 0.9;
}

fn fiddledDistance(seed: i64, x: i32, y: i32, z: i32, distance_x: f64, distance_y: f64, distance_z: f64) f64 {
    var rval = seed;
    rval = lcg(rval, x);
    rval = lcg(rval, y);
    rval = lcg(rval, z);
    rval = lcg(rval, x);
    rval = lcg(rval, y);
    rval = lcg(rval, z);
    const fiddle_x = fiddle(rval);
    rval = lcg(rval, seed);
    const fiddle_y = fiddle(rval);
    rval = lcg(rval, seed);
    const fiddle_z = fiddle(rval);
    const dz = distance_z + fiddle_z;
    const dy = distance_y + fiddle_y;
    const dx = distance_x + fiddle_x;
    return dz * dz + dy * dy + dx * dx;
}

/// The quart (4x4x4 cell) a block gets its biome from (`BiomeManager.getBiome`): the closest of the
/// 8 around it, each moved a bit by the seed so borders aren't straight lines.
pub fn zoom(zoom_seed: i64, x: i32, y: i32, z: i32) [3]i32 {
    const abs_x = x -% 2;
    const abs_y = y -% 2;
    const abs_z = z -% 2;
    const parent_x = abs_x >> 2;
    const parent_y = abs_y >> 2;
    const parent_z = abs_z >> 2;
    const fract_x = @as(f64, @floatFromInt(abs_x & 3)) / 4.0;
    const fract_y = @as(f64, @floatFromInt(abs_y & 3)) / 4.0;
    const fract_z = @as(f64, @floatFromInt(abs_z & 3)) / 4.0;

    var min_i: u3 = 0;
    var min_distance = std.math.inf(f64);
    for (0..8) |i| {
        const x_even = i & 4 == 0;
        const y_even = i & 2 == 0;
        const z_even = i & 1 == 0;
        const distance = fiddledDistance(
            zoom_seed,
            if (x_even) parent_x else parent_x + 1,
            if (y_even) parent_y else parent_y + 1,
            if (z_even) parent_z else parent_z + 1,
            if (x_even) fract_x else fract_x - 1.0,
            if (y_even) fract_y else fract_y - 1.0,
            if (z_even) fract_z else fract_z - 1.0,
        );
        if (min_distance > distance) {
            min_i = @intCast(i);
            min_distance = distance;
        }
    }
    return .{
        if (min_i & 4 == 0) parent_x else parent_x + 1,
        if (min_i & 2 == 0) parent_y else parent_y + 1,
        if (min_i & 1 == 0) parent_z else parent_z + 1,
    };
}
