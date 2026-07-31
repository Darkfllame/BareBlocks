const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coro_mod = b.addModule("coroutines", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exe = b.addTest(.{ .root_module = coro_mod });

    const run_test = b.addRunArtifact(test_exe);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);

    const check_step = b.step("check", "Run semantic analysis");
    check_step.dependOn(&test_exe.step);
}
