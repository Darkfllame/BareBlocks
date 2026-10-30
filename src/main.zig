const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const core = @import("core");
const utils = @import("utils");

const Io = std.Io;

const use_safe_allocator = !builtin.cpu.arch.isWasm() and switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => !builtin.link_libc and builtin.single_threaded, // Also not ideal.
};

pub const std_options = std.Options{
    // .log_level = .info,
    .log_scope_levels = &.{
        // .{ .scope = .zio, .level = .info },
        // .{ .scope = .@"core/server", .level = .info },
        // .{ .scope = .net, .level = .info },
    },
};

pub const zio_options = zio.Options{
    .scheduling = .work_stealing,
    .backend = .epoll,
    .resolve_beneath_mode = .best_effort,
    .no_hacks = true,
    .scheduler_metrics = true,
};

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init.Minimal) !@typeInfo(@typeInfo(@TypeOf(asyncMain)).@"fn".return_type.?).error_union.payload {
    // Initialization code STRAIGHT stolen from std/start.zig
    var sa = if (use_safe_allocator) std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    defer _ = if (use_safe_allocator) sa.deinit();

    const gpa = if (use_safe_allocator)
        sa.allocator()
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

    var environ_map = std.process.Environ.createMap(.{ .block = init.environ.block }, gpa) catch |err| {
        std.log.err("Failed to parse environment variables", .{});
        return err;
    };
    defer environ_map.deinit();

    const preopens = std.process.Preopens.init(arena.allocator()) catch |err| {
        std.log.err("Failed to init preopens", .{});
        return err;
    };

    var rt: zio.Runtime = undefined;
    rt.initStatic(gpa, .{
        .executors = .auto,
    }) catch |err| {
        std.log.err("Failed to initialize ZIO runtime", .{});
        return err;
    };
    defer rt.deinit();

    utils.translation.init(arena.allocator()) catch |err| {
        std.log.err("Failed to initialize en_us translation table", .{});
        return err;
    };

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
    errdefer if (@errorReturnTrace()) |ert| std.debug.dumpErrorReturnTrace(ert);

    var root_reg = try core.registry.RootRegistry.init(init.gpa);
    defer root_reg.deinit(init.gpa);

    var server: core.Server = undefined;
    try server.init(.{
        .allocator = init.gpa,
        .runtime = rt,
        .bind_port_v6 = 35565,
        // .broadcast = true,
    });
    defer server.deinit();

    const SelectResult = union(enum) {
        sig: @typeInfo(@TypeOf(signalWaiter)).@"fn".return_type.?,
        console: @typeInfo(@TypeOf(readConsole)).@"fn".return_type.?,
    };
    var select_buf: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(init.io, &select_buf);
    defer select.cancelDiscard();

    try select.concurrent(.sig, signalWaiter, .{&server.start});
    try select.concurrent(.console, readConsole, .{ &server, init.gpa, init.environ_map });

    server.start.set();

    var current: ?SelectResult = select.await() catch unreachable;

    while (current) |res| : (current = select.cancel()) {
        const err = sw: switch (res) {
            .sig => |result| if (result) continue else |err| err,
            .console => |result| {
                if (result) {
                    break;
                } else |err| break :sw err;
            },
        };
        if (err == error.Canceled) continue;
        core.logger.err("Error on {t}: {t}", .{ res, err });
    }
}

fn signalWaiter(start_event: *zio.Event) error{ SetConsoleCtrlHandlerFailed, TooManySignalHandlers }!void {
    var sig = try zio.Signal.init(.interrupt);
    start_event.wait() catch return;
    sig.wait() catch {};
}

fn readConsole(server: *core.Server, gpa: std.mem.Allocator, evm: *const std.process.Environ.Map) !void {
    server.start.wait() catch return;

    const stdin = Io.File.stdin();
    const io = server.runtime.io();

    var buf: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var file_reader = stdin.readerStreaming(io, &buf);
    var file_writer = stdin.writerStreaming(io, &buf2);
    const reader = &file_reader.interface;
    var writer = StdinLogger(.@"core/server").init(&file_writer, evm) catch return;

    var w = try Io.Writer.Allocating.initCapacity(gpa, 16);
    defer w.deinit();

    while (true) {
        w.clearRetainingCapacity();
        const n = reader.streamDelimiterEnding(&w.writer, '\n') catch |e| switch (e) {
            error.ReadFailed => return file_reader.err.?,
            error.WriteFailed => return error.OutOfMemory,
        };
        if (n == 0) break;
        reader.toss(1);

        var it = std.mem.splitScalar(u8, w.written(), ' ');
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "close")) {
            break;
        } else {
            writer.err("Couldn't parse command: {s}", .{cmd});
        }
    }
}

fn StdinLogger(comptime scope: @EnumLiteral()) type {
    return struct {
        const Self = @This();

        fn logFn(self: *Self, comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
            if (self.writer) |w| blk: {
                std.log.defaultLogFileTerminal(level, scope, format, args, .{
                    .writer = w,
                    .mode = self.mode,
                }) catch {
                    self.writer = null;
                    break :blk;
                };
                w.flush() catch {
                    self.writer = null;
                    break :blk;
                };
                return;
            }
            return std.options.logFn(level, scope, format, args);
        }

        writer: ?*Io.Writer,
        mode: Io.Terminal.Mode,

        pub fn init(writer: *Io.File.Writer, env: *const std.process.Environ.Map) Io.Cancelable!Self {
            if (!try writer.file.isTty(writer.io)) return .{ .writer = null, .mode = undefined };
            return .{
                .writer = &writer.interface,
                .mode = try .detect(
                    writer.io,
                    writer.file,
                    env.get("NO_COLOR") != null,
                    env.get("CLCOLOR_FORCE") != null,
                ),
            };
        }

        pub fn debug(self: *Self, comptime format: []const u8, args: anytype) void {
            if (comptime !std.log.logEnabled(.debug, scope)) return;

            self.logFn(.debug, format, args);
        }

        pub fn info(self: *Self, comptime format: []const u8, args: anytype) void {
            if (comptime !std.log.logEnabled(.info, scope)) return;

            self.logFn(.info, format, args);
        }

        pub fn warn(self: *Self, comptime format: []const u8, args: anytype) void {
            if (comptime !std.log.logEnabled(.warn, scope)) return;

            self.logFn(.warn, format, args);
        }

        pub fn err(self: *Self, comptime format: []const u8, args: anytype) void {
            if (comptime !std.log.logEnabled(.err, scope)) return;

            self.logFn(.err, format, args);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
