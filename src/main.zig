const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const core = @import("core");

const Io = std.Io;

const use_debug_allocator = !builtin.cpu.arch.isWasm() and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe => !builtin.link_libc, // Not ideal, but the best we have for now.
    .ReleaseFast, .ReleaseSmall => !builtin.link_libc and builtin.single_threaded, // Also not ideal.
};

var ert_buf: [8 * 1024]usize = undefined;

pub const std_options = std.Options{
    .log_scope_levels = &.{
        // .{ .scope = .@"core/server", .level = .info },
        // .{ .scope = .net, .level = .err },
    },
};

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init.Minimal) @typeInfo(@TypeOf(asyncMain)).@"fn".return_type.? {
    if (@errorReturnTrace()) |ert| {
        ert.instruction_addresses = &ert_buf;
    }

    // Initialization code STRAIGHT stolen from std.start
    var da = if (use_debug_allocator) std.heap.DebugAllocator(.{}).init;
    defer _ = if (use_debug_allocator) da.deinit();

    const gpa = if (use_debug_allocator)
        da.allocator()
    else if (builtin.link_libc)
        std.heap.c_allocator
    else if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else if (!builtin.single_threaded)
        std.heap.smp_allocator
    else
        comptime unreachable;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var environ_map = std.process.Environ.createMap(.{ .block = init.environ.block }, gpa) catch |err|
        std.process.fatal("failed to parse environment variables: {t}", .{err});
    defer environ_map.deinit();

    const preopens = std.process.Preopens.init(arena.allocator()) catch |err|
        std.process.fatal("failted to init preopens: {t}", .{err});

    var rt: zio.Runtime = undefined;
    rt.initStatic(gpa, .{
        .executors = .auto,
    }) catch |err|
        std.process.fatal("failed to initialize ZIO runtime: {t}", .{err});
    defer rt.deinit();

    const io = rt.blockingIo();

    var main_fut = io.async(asyncMain, .{ .{
        .minimal = init,
        .arena = &arena,
        .gpa = gpa,
        .io = rt.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    }, &rt });

    return main_fut.await(io);
}

fn asyncMain(init: std.process.Init, rt: *zio.Runtime) !void {
    var server: core.Server = undefined;
    try server.init(.{
        .allocator = init.gpa,
        .runtime = rt,
        .bind_port_v6 = 35565,
        // .broadcast = true,
    });
    defer server.deinit();

    var sig = try zio.Signal.init(.interrupt);
    server.start.set();

    std.log.info("Listening on {f}", .{server.addressAlt()});

    sig.wait() catch unreachable;
}

test {
    std.testing.refAllDecls(@This());
}
