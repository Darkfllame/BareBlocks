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
    const target = b.standardTargetOptions(.{ .whitelist = &.{
        std.Target.Query{ .cpu_arch = .x86_64, .os_tag = .linux },
    } });
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "use_llvm", "Force the use of LLVM");

    // const vk_headers = b.dependency("vulkan_headers", .{});
    // const sdl_dep = b.dependency("sdl", .{
    //     .target = target,
    //     .optimize = optimize,
    //     .preferred_linkage = .dynamic,
    // });

    // const vulkan_mod = b.dependency("vulkan", .{
    //     .registry = vk_headers.path("registry/vk.xml"),
    //     .video = vk_headers.path("registry/video.xml"),
    // }).module("vulkan-zig");

    // const sdl_c = b.addTranslateC(.{
    //     .root_source_file = b.path("src/sdl_decls.h"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // sdl_c.addIncludePath(sdl_dep.path("include/"));
    // const sdl_mod = sdl_c.createModule();
    // sdl_mod.linkLibrary(sdl_dep.artifact("SDL3"));

    const coro_mod = b.dependency("coroutines", .{
        .target = target,
        .optimize = optimize,
    }).module("coroutines");

    const config = b.addOptions();
    config.addOption(std.SemanticVersion, "version", version);
    const config_mod = config.createModule();

    const mc_downloader = downloadMCExec(b);
    const mc_manifest = blk: {
        const run_cmd = b.addRunArtifact(mc_downloader);
        run_cmd.addArg("manifest");
        break :blk run_cmd.addOutputFileArg("manifest.json");
    };
    const mc26_2_meta = blk: {
        const run_cmd = b.addRunArtifact(mc_downloader);
        run_cmd.addArg("meta");
        run_cmd.addFileArg(mc_manifest);
        const file = run_cmd.addOutputFileArg("meta.json");
        run_cmd.addArg("26.2");
        break :blk file;
    };
    const mc26_2_jar = blk: {
        const run_cmd = b.addRunArtifact(mc_downloader);
        run_cmd.addArg("jar");
        run_cmd.addFileArg(mc26_2_meta);
        run_cmd.addArg("server");
        break :blk run_cmd.addOutputFileArg("minecraft-26.2.jar");
    };
    // const mc_generated = mcDatagenDir(b, mc26_2_v);

    const lm_mod = b.createModule(.{ .root_source_file = b.path("src/lm.zig") });
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/utils.zig"),
        .imports = &.{
            .{ .name = "en_us", .module = b.createModule(.{
                .root_source_file = b.path("assets/minecraft/assets/lang/en_us.json"),
            }) },
        },
    });
    const net_mod = b.createModule(.{ .root_source_file = b.path("src/net/net.zig") });
    const core_mod = b.createModule(.{ .root_source_file = b.path("src/core/core.zig") });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .error_tracing = true,
    });

    const main_exe = b.addExecutable(.{
        .name = "bare_blocks",
        .root_module = main_mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const local_imports = [_]Module.Import{
        .{ .name = "main", .module = main_mod },
        .{ .name = "coro", .module = coro_mod },
        .{ .name = "core", .module = core_mod },
        .{ .name = "utils", .module = utils_mod },
        .{ .name = "lm", .module = lm_mod },
        .{ .name = "net", .module = net_mod },
    };
    const all_imports = local_imports ++ [_]Module.Import{
        // .{ .name = "vulkan", .module = vulkan_mod },
        // .{ .name = "sdl", .module = sdl_mod },
        .{ .name = "config", .module = config_mod },
    };

    b.installArtifact(main_exe);
    // if (false) {
    b.getInstallStep().dependOn(&b.addInstallBinFile(mc_manifest, "manifest.json").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(mc26_2_meta, "meta.json").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(mc26_2_jar, "minecraft-26.2.jar").step);
    // }

    const run_exe = b.addRunArtifact(main_exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_exe.addArgs(b.args orelse &.{});
    run_exe.setCwd(b.path("."));

    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_exe.step);

    const test_step = b.step("test", "Run test untis");
    const check_step = b.step("check", "Run semantic analysis");
    for (local_imports) |imp| {
        imp.module.import_table.ensureUnusedCapacity(b.allocator, all_imports.len) catch @panic("OOM");
        for (all_imports) |imp2| {
            imp.module.addImport(imp2.name, imp2.module);
        }

        const module = if (imp.module.resolved_target == null or imp.module.optimize == null)
            b.createModule(.{
                .root_source_file = imp.module.root_source_file,
                .target = target,
                .optimize = optimize,
                .imports = &all_imports,
            })
        else
            imp.module;
        const test_exe = b.addTest(.{
            .name = b.fmt("test-{s}", .{imp.name}),
            .root_module = module,
        });

        const run_test = b.addRunArtifact(test_exe);

        test_step.dependOn(&run_test.step);
        check_step.dependOn(&test_exe.step);
    }
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
        .optimize = .ReleaseSafe,
    });
    const download_jar_exe = b.addExecutable(.{
        .name = "mc_downloader",
        .root_module = download_jar_mod,
    });
    return download_jar_exe;
}

fn downloadMcVersion(b: *Build, dl_mc_exec: *Step.Compile, _version: ?[]const u8) LazyPath {
    const run_cmd = b.addRunArtifact(dl_mc_exec);
    if (_version) |v| run_cmd.addArg(b.fmt("-v{s}", .{v}));
    run_cmd.has_side_effects = false;
    return run_cmd.addPrefixedOutputFileArg("-o", b.fmt("minecraft_{s}.jar", .{_version orelse "latest"}));
}

fn mcDatagenDir(b: *Build, _version: LazyPath) LazyPath {
    const run_mc = b.addSystemCommand(&.{ "java", "-DbundlerMainClass=net.minecraft.data.Main", "-jar" });
    run_mc.setCwd(mkdir(b, b.path("."), "datagen_run"));
    _ = run_mc.captureStdOut(.{});
    _ = run_mc.captureStdErr(.{});
    run_mc.addFileArg(_version);
    run_mc.addArgs(&.{ "--all", "--output" });
    return run_mc.addOutputFileArg("generated");
}

fn mkdir(b: *Build, root: LazyPath, path: []const u8) LazyPath {
    const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir_cmd.setCwd(root);
    mkdir_cmd.addArg(path);
    const gen = b.allocator.create(Build.GeneratedFile) catch @panic("OOM");
    gen.* = .{ .step = &mkdir_cmd.step, .path = path };
    return .{ .generated = .{ .file = gen } };
}
