const Project = @This();
const std = @import("std");

const Build = std.Build;
const Module = Build.Module;
const LazyPath = Build.LazyPath;
const Allocator = std.mem.Allocator;

const TestableModule = struct {
    module: *Module,
    imports: []const []const u8,
};

arena: Allocator,
modules: std.StringHashMapUnmanaged(TestableModule),

pub const AddModuleOptions = struct {
    name: []const u8,
    module: *Module,
    local_imports: []const []const u8 = &.{},
};

pub const CreateModuleOptions = struct {
    name: []const u8,
    local_imports: []const []const u8 = &.{},

    /// This could either be a generated file, in which case the module
    /// contains exactly one file, or it could be a path to the root source
    /// file of directory of files which constitute the module.
    /// If `null`, it means this module is made up of only `link_objects`.
    root_source_file: ?LazyPath = null,

    /// The table of other modules that this module can access via `@import`.
    /// Imports are allowed to be cyclical, so this table can be added to after
    /// the `Module` is created via `addImport`.
    imports: []const Module.Import = &.{},

    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.Optimize = null,

    /// `true` requires a compilation that includes this Module to link libc.
    /// `false` causes a build failure if a compilation that includes this Module would link libc.
    /// `null` neither requires nor prevents libc from being linked.
    link_libc: ?bool = null,
    /// `true` requires a compilation that includes this Module to link libc++.
    /// `false` causes a build failure if a compilation that includes this Module would link libc++.
    /// `null` neither requires nor prevents libc++ from being linked.
    link_libcpp: ?bool = null,
    single_threaded: ?bool = null,
    strip: ?bool = null,
    unwind_tables: ?std.builtin.UnwindTables = null,
    dwarf_format: ?std.dwarf.Format = null,
    code_model: std.builtin.CodeModel = .default,
    stack_protector: ?bool = null,
    stack_check: ?bool = null,
    sanitize_c: ?std.zig.SanitizeC = null,
    sanitize_thread: ?bool = null,
    fuzz: ?bool = null,
    /// Whether to emit machine code that integrates with Valgrind.
    valgrind: ?bool = null,
    /// Position Independent Code
    pic: ?bool = null,
    red_zone: ?bool = null,
    /// Whether to omit the stack frame pointer. Frees up a register and makes it
    /// more difficult to obtain stack traces. Has target-dependent effects.
    omit_frame_pointer: ?bool = null,
    error_tracing: ?bool = null,
    no_builtin: ?bool = null,
};

pub fn addModule(self: *Project, opt: AddModuleOptions) void {
    const imp_copy = self.arena.alloc([]const u8, opt.local_imports.len) catch @panic("OOM");
    for (opt.local_imports, imp_copy) |in, *out| {
        out.* = self.arena.dupe(u8, in) catch @panic("OOM");
    }

    self.modules.put(self.arena, opt.name, .{
        .module = opt.module,
        .imports = imp_copy,
    }) catch @panic("OOM");
}

pub fn createModule(self: *Project, b: *Build, opt: CreateModuleOptions) *Module {
    var mcreate_opt: Module.CreateOptions = undefined;
    inline for (@typeInfo(Module.CreateOptions).@"struct".field_names) |fname| {
        @field(mcreate_opt, fname) = @field(opt, fname);
    }

    const mod = self.arena.create(Module) catch @panic("OOM");
    mod.init(b, .{ .options = mcreate_opt });

    self.addModule(.{
        .name = opt.name,
        .module = mod,
        .local_imports = opt.local_imports,
    });

    return mod;
}

pub fn makeTests(self: *Project, b: *Build, test_step: *Build.Step, check_step: *Build.Step, use_llvm: ?bool) void {
    const target = b.resolveTargetQuery(.{});

    var copied_modules = std.StringHashMapUnmanaged(*Module).empty;
    var mod_it = self.modules.iterator();
    while (mod_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const tmod = entry.value_ptr.*;
        const module = tmod.module;

        const test_mod = b.createModule(.{
            .root_source_file = module.root_source_file,
            .target = target,
            .optimize = .debug,
            .link_libc = module.link_libc,
            .link_libcpp = module.link_libcpp,
            .single_threaded = module.single_threaded,
            .strip = module.strip,
            .unwind_tables = module.unwind_tables,
            .dwarf_format = module.dwarf_format,
            .code_model = module.code_model,
            .stack_protector = module.stack_protector,
            .stack_check = module.stack_check,
            .sanitize_c = module.sanitize_c,
            .sanitize_thread = module.sanitize_thread,
            .fuzz = module.fuzz,
            .valgrind = module.valgrind,
            .pic = module.pic,
            .red_zone = module.red_zone,
            .omit_frame_pointer = module.omit_frame_pointer,
            .error_tracing = module.error_tracing,
            .no_builtin = module.no_builtin,
        });
        test_mod.import_table = module.import_table.clone(self.arena) catch @panic("OOM");
        test_mod.link_objects = module.link_objects.clone(self.arena) catch @panic("OOM");
        
        copied_modules.put(self.arena, name, test_mod) catch @panic("OOM");

        const test_exe = b.addTest(.{
            .name = b.fmt("test-{s}", .{name}),
            .root_module = test_mod,
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });

        test_step.dependOn(&b.addRunArtifact(test_exe).step);
        check_step.dependOn(&test_exe.step);
    }
    mod_it = self.modules.iterator();
    while (mod_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const tmod = entry.value_ptr.*;

        const test_mod = copied_modules.get(name).?;
        for (tmod.imports) |in_name| {
            const in_mod = copied_modules.get(in_name) orelse
                std.debug.panic("Couldn't find internal module for {q}: {q}", .{ name, in_name });
            test_mod.import_table.put(self.arena, in_name, in_mod) catch @panic("OOM");
        }
    }
}

/// Should be called at the very end of the `build()` function
pub fn resolveLocalImports(self: *Project) void {
    var mod_it = self.modules.iterator();
    while (mod_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const tmod = entry.value_ptr.*;

        for (tmod.imports) |in_name| {
            const in_mod = self.modules.get(in_name) orelse
                std.debug.panic("Couldn't find internal module for {q}: {q}", .{ name, in_name });
            tmod.module.import_table.put(self.arena, in_name, in_mod.module) catch @panic("OOM");
        }
    }
}
