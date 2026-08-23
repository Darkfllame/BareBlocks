const std = @import("std");
const core = @import("core");
const utils = @import("utils");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const prov = core.IntProvider{ .trapezoid = .{
        .plateau = 50,
        .range = .init(-50, 150),
    } };
    _ = &prov;
    var xoroshiro128pp = utils.Xoroshiro128PlusPLus.init(0xDEADBEEF);
    var rnd = utils.RandomPair.new(xoroshiro128pp.random());

    std.log.debug("rnd seed: {x} {x}", .{ xoroshiro128pp.s[0], xoroshiro128pp.s[1] });
    std.log.debug("{d}", .{prov.sample(&rnd)});
    std.log.debug("{d}", .{prov.sample(&rnd)});
    std.log.debug("{d}", .{prov.sample(&rnd)});
    std.log.debug("{d}", .{prov.sample(&rnd)});
}
