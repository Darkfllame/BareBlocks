const std = @import("std");
const builtin = @import("builtin");
const Project = @import("build/Project.zig");
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
        openssl: Dep,
    },
    paths: []const []const u8,

    const Dep = struct {
        path: ?[]const u8 = null,
        hash: ?[]const u8 = null,
        url: ?[]const u8 = null,
        lazy: bool = false,
    };
} = @import("build.zig.zon");

const Build = std.Build;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const Step = Build.Step;

const version = std.SemanticVersion.parse(buildzigzon.version) catch unreachable;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) {
        @panic("Target must be x86_64 linux");
    }

    const use_llvm = b.option(bool, "use_llvm", "Force the use of LLVM");
    const mc_version = b.option([]const u8, "mcver", "Version of minecraft (default: 26.2)") orelse "26.2";
    const force_mc_cache_reload = b.option(bool, "mccache_reload", "Force reloading minecraft cache (default: false)") orelse false;

    const old_datagen_cmd = blk: {
        if (std.mem.startsWith(u8, mc_version, "latest")) break :blk false;

        var split = std.mem.splitScalar(u8, mc_version, '.');
        const first_num = std.fmt.parseInt(u8, split.next() orelse @panic("Malformed Version"), 10) catch break :blk true;
        const second_num = std.fmt.parseInt(u8, split.next() orelse @panic("Malformed Version"), 10) catch @panic("Malformed Version");
        if (split.next()) |patch_str| {
            _ = std.fmt.parseInt(u8, patch_str, 10) catch @panic("Malfromed Version");
            if (first_num != 1) @panic("Malformed Version");
            break :blk second_num >= 18;
        } else {
            break :blk false;
        }
    };
    if (old_datagen_cmd) @panic("Minecraft version too old (must be at least 1.18)");

    const vk_headers = b.dependency("vulkan_headers", .{});
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .dynamic,
    });

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

    const ossl_dep = b.dependency("openssl", .{ .target = target, .optimize = optimize });
    const crypto_mod = blk: {
        const tc = b.addTranslateC(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/crypto_decls.h"),
        });
        tc.addIncludePath(ossl_dep.path("include/"));
        const mod = tc.createModule();
        mod.linkSystemLibrary("libcrypto", .{ .needed = true });
        break :blk mod;
    };

    const coro_mod = b.dependency("coroutines", .{
        .target = target,
        .optimize = optimize,
    }).module("coroutines");

    const config = b.addOptions();
    config.addOption(std.SemanticVersion, "version", version);
    const config_mod = config.createModule();

    const mc_downloader = downloadMCExec(b);
    const mcd_cache = try mkdir(b, b.path("."), ".mccache");
    const mc_gendata = genDataMCExec(b);

    const mc26_2_jar = blk: {
        const run_cmd = b.addRunArtifact(mc_downloader);
        if (force_mc_cache_reload) {
            run_cmd.has_side_effects = true;
            run_cmd.stdio = .inherit;
        }
        run_cmd.addDirectoryArg(mcd_cache);
        run_cmd.addArgs(&.{ "jar", "server" });
        const out_jar = run_cmd.addOutputFileArg("minecraft.jar");
        run_cmd.addArg(mc_version);
        break :blk out_jar;
    };
    const mc26_2_assets = blk: {
        const run_cmd = b.addRunArtifact(mc_downloader);
        if (force_mc_cache_reload) {
            run_cmd.has_side_effects = true;
            run_cmd.stdio = .inherit;
        }
        run_cmd.addDirectoryArg(mcd_cache);
        run_cmd.addArg("assets");
        const out_dir = run_cmd.addOutputFileArg("assets");
        run_cmd.addArg(mc_version);
        break :blk out_dir;
    };
    const mc_generated = try mcDatagenDir(b, mc26_2_jar, mc_version);
    const mc_registries = blk: {
        const run_exe = b.addRunArtifact(mc_gendata);
        run_exe.addDirectoryArg(mc_generated);
        run_exe.addArg("registries");
        break :blk run_exe.addOutputFileArg("registries.zig");
    };
    const mc_packets = blk: {
        const run_exe = b.addRunArtifact(mc_gendata);
        run_exe.has_side_effects = true;
        run_exe.addDirectoryArg(mc_generated);
        run_exe.addArg("packets");
        break :blk run_exe.addOutputFileArg("packets.zig");
    };
    const registries_mod = b.createModule(.{ .root_source_file = mc_registries });
    const packets_mod = b.createModule(.{ .root_source_file = mc_packets });

    var proj = Project{
        .arena = b.graph.arena,
        .modules = .empty,
    };

    const math_mod = proj.createModule(b, .{
        .name = "math",
        .root_source_file = b.path("src/math/math.zig"),
    });
    _ = math_mod;
    const utils_mod = proj.createModule(b, .{
        .name = "utils",
        .root_source_file = b.path("src/utils/utils.zig"),
        .local_imports = &.{"serial"},
        .imports = &.{
            .{ .name = "en_us", .module = b.createModule(.{
                .root_source_file = b.path("assets/minecraft/assets/lang/en_us.json"),
            }) },
        },
    });
    const net_mod = proj.createModule(b, .{
        .name = "net",
        .root_source_file = b.path("src/net/net.zig"),
        .imports = &.{
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "config", .module = config_mod },
        },
        .local_imports = &.{
            "coro",
            "core",
            "utils",
            "serial",
        },
    });
    const core_mod = proj.createModule(b, .{
        .name = "core",
        .root_source_file = b.path("src/core/core.zig"),
        .imports = &.{
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "config", .module = config_mod },
        },
        .local_imports = &.{
            "coro",
            "utils",
            "serial",
            "math",
            "net",
            "registries",
            "packets",
        },
    });
    _ = core_mod;
    const serial_mod = proj.createModule(b, .{
        .name = "serial",
        .root_source_file = b.path("src/serial/serial.zig"),
        .local_imports = &.{"utils"},
    });
    _ = serial_mod;

    const client_mod = proj.createModule(b, .{
        .name = "client",
        .root_source_file = b.path("src/client/client.zig"),
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "vulkan", .module = vulkan_mod },
            .{ .name = "sdl", .module = sdl_mod },
            .{ .name = "default_shader_code", .module = b.createModule(.{
                .root_source_file = compileShader(b, b.path("assets/shaders/default.slang")),
            }) },
        },
        .local_imports = &.{
            "utils",
            "math",
        },
    });
    _ = client_mod;

    const main_mod = proj.createModule(b, .{
        .name = "main",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .error_tracing = true,
        .imports = &.{
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "config", .module = config_mod },
        },
        .local_imports = &.{
            "coro",
            "core",
            "utils",
            "serial",
            "math",
            "net",
        },
    });

    const main_client_mod = proj.createModule(b, .{
        .name = "main-client",
        .root_source_file = b.path("src/main_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .error_tracing = true,
        .imports = &.{
            .{ .name = "vulkan", .module = vulkan_mod },
            .{ .name = "sdl", .module = sdl_mod },
        },
        .local_imports = &.{"client"},
    });

    proj.addModule(.{ .name = "registries", .module = registries_mod });
    proj.addModule(.{
        .name = "packets",
        .module = packets_mod,
        .local_imports = &.{ "core", "net" },
    });
    proj.addModule(.{ .name = "coro", .module = coro_mod });

    mc_gendata.root_module.addImport("utils", utils_mod);
    mc_gendata.root_module.addAnonymousImport("net", .{
        .root_source_file = net_mod.root_source_file.?,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const main_exe = b.addExecutable(.{
        .name = "bare_blocks",
        .root_module = main_mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const main_client_exe = b.addExecutable(.{
        .name = "bare_blocks_client",
        .root_module = main_client_mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    b.installArtifact(main_exe);
    b.installArtifact(main_client_exe);

    const run_step = b.step("run", "Run the executable");
    {
        const run_exe = b.addRunArtifact(main_exe);
        run_exe.step.dependOn(b.getInstallStep());
        run_exe.addArgs(b.args orelse &.{});
        run_exe.setCwd(b.path("."));

        run_step.dependOn(&run_exe.step);
    }

    const run_cl_step = b.step("run-client", "Run the executable");
    {
        const run_exe = b.addRunArtifact(main_client_exe);
        run_exe.step.dependOn(b.getInstallStep());
        run_exe.addArgs(b.args orelse &.{});
        run_exe.setCwd(b.path("."));

        run_cl_step.dependOn(&run_exe.step);
    }

    const assets_step = b.step("assets", "Download assets from mojang's servers");
    assets_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = mc26_2_assets,
        .install_dir = .bin,
        .install_subdir = "assets",
    }).step);

    const generated_step = b.step("generated", "Install minecraft generated data");
    generated_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = mc_generated,
        .install_dir = .bin,
        .install_subdir = "generated",
        .include_extensions = &.{".json"},
    }).step);

    const test_step = b.step("test", "Run test untis");
    const check_step = b.step("check", "Run semantic analysis");
    proj.makeTests(b, test_step, check_step, use_llvm);

    proj.resolveLocalImports();
}

fn compileShader(b: *Build, path: LazyPath) LazyPath {
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

fn downloadMCExec(b: *Build) *Step.Compile {
    const download_jar_mod = b.createModule(.{
        .root_source_file = b.path("build/mc_downloader.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    const download_jar_exe = b.addExecutable(.{
        .name = "mc_downloader",
        .root_module = download_jar_mod,
    });
    return download_jar_exe;
}
fn genDataMCExec(b: *Build) *Step.Compile {
    const gendata_mod = b.createModule(.{
        .root_source_file = b.path("build/gen_data.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    const gendata_exe = b.addExecutable(.{
        .name = "gen_data",
        .root_module = gendata_mod,
    });
    return gendata_exe;
}

fn mcDatagenDir(b: *Build, jar_path: LazyPath, _version: []const u8) !LazyPath {
    const data_gen_dir = try mkdir(b, b.path("."), b.fmt("run_datagen_{s}", .{_version}));
    const run_mc = b.addSystemCommand(&.{ "java", "-DbundlerMainClass=net.minecraft.data.Main", "-jar" });
    run_mc.setCwd(data_gen_dir);
    run_mc.addFileArg(jar_path);
    _ = run_mc.captureStdOut(.{});
    _ = run_mc.captureStdErr(.{});
    run_mc.addArgs(&.{ "--all", "--output" });
    return run_mc.addOutputDirectoryArg("generated");
}

fn mkdir(b: *Build, root: LazyPath, path: []const u8) !LazyPath {
    // b.root.createDirPath(b.graph.io, path) catch @panic("Failed to make path");
    // if (true) return b.path(path);
    if (true) {
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p" });
        mkdir_cmd.setCwd(root);
        mkdir_cmd.addArg(path);
        const gen = b.allocator.create(Build.GeneratedFile) catch @panic("OOM");
        gen.* = .{ .step = &mkdir_cmd.step, .path = path };
        return .{ .generated = .{ .file = gen } };
    }
    unreachable;
}
