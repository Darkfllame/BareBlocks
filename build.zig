const std = @import("std");
const builtin = @import("builtin");
const buildzigzon: struct {
    name: @EnumLiteral(),
    fingerprint: u64,
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: struct {
        coroutines: Dep,
        vulkan: Dep,
        vulkan_headers: Dep,
        sdl: Dep,
    },
    paths: []const []const u8,

    const Dep = struct {
        path: ?[]const u8 = null,
        url: ?[]const u8 = null,
        hash: ?[]const u8 = null,
        lazy: bool = false,
    };
} = @import("build.zig.zon");

const version = std.SemanticVersion.parse(buildzigzon.version) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .whitelist = &.{
        std.Target.Query{ .cpu_arch = .x86_64, .os_tag = .linux },
    } });
    const optimize = b.standardOptimizeOption(.{});

    const vk_headers = b.dependency("vulkan_headers", .{});
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .dynamic,
    });
    const coro_mod = b.dependency("coroutines", .{ .target = target, .optimize = optimize })
        .module("coroutines");
    const vulkan_mod = b.dependency("vulkan", .{
        .registry = vk_headers.path("registry/vk.xml"),
        .video = vk_headers.path("registry/video.xml"),
    }).module("vulkan-zig");

    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_decls.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addIncludePath(sdl_dep.path("include/"));
    const sdl_mod = sdl_c.createModule();
    sdl_mod.linkLibrary(sdl_dep.artifact("SDL3"));

    const config = b.addOptions();
    config.addOption(std.SemanticVersion, "version", version);
    const config_mod = config.createModule();

    const lm_mod = b.createModule(.{ .root_source_file = b.path("src/lm.zig") });

    const utils_mod = b.createModule(.{ .root_source_file = b.path("src/utils/utils.zig") });

    const net_mod = b.createModule(.{
        .root_source_file = b.path("src/net/net.zig"),
        .imports = &.{
            .{ .name = "coro", .module = coro_mod },
            .{ .name = "utils", .module = utils_mod },
        },
    });
    net_mod.addImport("net", net_mod);

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .imports = &.{
            .{ .name = "coro", .module = coro_mod },
            .{ .name = "lm", .module = lm_mod },
        },
    });
    core_mod.addImport("core", core_mod);
    core_mod.addImport("utils", utils_mod);

    const main_exe = b.addExecutable(.{
        .name = "bare_blocks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "coro", .module = coro_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "net", .module = net_mod },
                .{ .name = "vulkan", .module = vulkan_mod },
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "config", .module = config_mod },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    main_exe.root_module.addAnonymousImport("default_shader_code", .{
        .root_source_file = compileShader(b, b.path("assets/shaders/default.slang")),
    });

    b.installArtifact(main_exe);

    // const download_jar_exe = b.addExecutable(.{
    //     .name = "download_mcjar",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("build/download_jar.zig"),
    //         .target = b.resolveTargetQuery(.{}),
    //         .optimize = .Debug,
    //     }),
    // });

    // const run_download_jar = b.addRunArtifact(download_jar_exe);
    // run_download_jar.addArg("-v1.21.11");
    // const server_jar = run_download_jar.addPrefixedOutputFileArg("-o", "minecraft_1.21.11.jar");
    // b.getInstallStep().dependOn(&run_download_jar.step);

    // const run_datagen = b.addSystemCommand(&.{ "java", "-DbundlerMainClass=net.minecraft.data.Main", "-jar" });
    // run_datagen.addFileArg(server_jar);
    // run_datagen.addArgs(&.{ "--all", "--output" });
    // const generated = run_datagen.addOutputDirectoryArg("generated");
    // const tfiles = b.addTempFiles();
    // run_datagen.setCwd(tfiles.getDirectory());

    // b.installDirectory(.{
    //     .install_dir = .prefix,
    //     .install_subdir = "generated",
    //     .source_dir = generated,
    // });

    const run_exe = b.addRunArtifact(main_exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_exe.addArgs(b.args orelse &.{});
    run_exe.setCwd(b.path("."));

    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_exe.step);
}

fn compileShader(b: *std.Build, path: std.Build.LazyPath) std.Build.LazyPath {
    const run_slangc = b.addSystemCommand(&.{
        "slangc", "-g",           "-target", "spirv",
        "-entry", "vertexMain",   "-stage",  "vertex",
        "-entry", "fragmentMain", "-stage",  "fragment",
    });
    run_slangc.addArg("-o");
    const out = run_slangc.addOutputFileArg("shader.spv");
    run_slangc.addFileArg(path);
    return out;
}
