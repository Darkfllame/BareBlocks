const std = @import("std");

const http = std.http;
const json = std.json;
const Uri = std.Uri;

const Io = std.Io;
const net = Io.net;
const IpAddress = net.IpAddress;
const Stream = net.Stream;
const HostName = net.HostName;

const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const default_uris = &[_]Uri{
    Uri.parse("https://piston-meta.mojang.com/mc/game/version_manifest.json") catch unreachable,
    Uri.parse("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") catch unreachable,
};

const ressource_base_url = "https://resources.download.minecraft.net/";

const DownloadMode = enum { manifest, meta, jar, assets };
const JarMode = enum { client, server };

/// Command line:\
/// `<exe> manifest <out_file> (<url> ...)`\
/// `<exe> meta <manifest_file> <out_file> (<version>)`\
/// `<exe> jar <meta_file> [client/server] <out_file>`\
/// `<exe> assets json <meta_file> <out_file>`\
/// `<exe> assets file <json_file> <out_file>`\
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var cl: http.Client = .{ .allocator = init.gpa, .io = init.io };
    try cl.initDefaultProxies(arena, init.environ_map);
    defer cl.deinit();

    const cwd = Io.Dir.cwd();
    const redibuf = try init.gpa.alloc(u8, 8 * 1024);
    defer init.gpa.free(redibuf);
    const decomp_buffer = try arena.alloc(u8, @max(
        std.compress.flate.max_window_len,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    ));
    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var name_buffer: [std.Progress.Node.max_name_len]u8 = undefined;
    var name_writer = std.Io.Writer.fixed(&name_buffer);

    var args_it = try init.minimal.args.iterateAllocator(arena);
    _ = args_it.skip();
    const mode = std.meta.stringToEnum(DownloadMode, args_it.next() orelse return error.BadArgument) orelse
        return error.BadArgument;

    switch (mode) {
        .manifest => {
            var manifest_urls = try std.ArrayList(Uri).initCapacity(init.gpa, default_uris.len);
            defer manifest_urls.deinit(init.gpa);

            const filename = args_it.next() orelse return error.BadArgument;

            while (args_it.next()) |arg| {
                try manifest_urls.append(init.gpa, try Uri.parse(try arena.dupe(u8, arg)));
            }

            if (manifest_urls.items.len == 0) {
                manifest_urls.appendSliceAssumeCapacity(default_uris);
            }

            const file = try cwd.createFile(
                init.io,
                filename,
                .{ .lock = .exclusive, .truncate = true },
            );
            errdefer cwd.deleteFile(init.io, filename) catch {};
            defer file.close(init.io);

            var fw = file.writer(init.io, &write_buffer);

            const man_prog = std.Progress.start(init.io, .{});
            defer man_prog.end();

            for (manifest_urls.items) |uri| {
                name_writer.end = 0;
                name_writer.print("downloading manifest: {f}", .{uri}) catch {};
                man_prog.setName(name_writer.buffered());

                _ = streamFromUri(
                    man_prog,
                    &cl,
                    uri,
                    redibuf,
                    &read_buffer,
                    decomp_buffer,
                    &name_buffer,
                    &fw.interface,
                ) catch |e| {
                    const real_error = if (e != error.WriteFailed) e else return fw.err.?;

                    std.log.err("Error downloading manifest file: {t}", .{real_error});

                    try fw.seekTo(0);
                };
                man_prog.end();
                return;
            }

            return error.DownloadFailed;
        },
        .meta => {
            const manifest_path = args_it.next() orelse return error.BadArgument;
            const filename = args_it.next() orelse return error.BadArgument;
            const version = args_it.next();

            const meta_uri = blk: {
                const man_file = try cwd.openFile(init.io, manifest_path, .{});
                defer man_file.close(init.io);

                var fr = man_file.reader(init.io, &read_buffer);
                var json_r = json.Reader.init(init.gpa, &fr.interface);
                defer json_r.deinit();

                const value = try json.parseFromTokenSourceLeaky(
                    json.Value,
                    init.arena.allocator(),
                    &json_r,
                    .{},
                );
                const release = version orelse
                    value.object.get("latest").?.object.get("release").?.string;
                const versions = value.object.get("versions").?.array.items;

                for (versions) |v| {
                    if (eql(u8, v.object.get("id").?.string, release)) {
                        break :blk try Uri.parse(v.object.get("url").?.string);
                    }
                }
                return error.MetaUrlNotFound;
            };

            name_writer.print("downloading meta {s}: {f}", .{ version orelse "latest", meta_uri }) catch {};

            const out_file = try cwd.createFile(
                init.io,
                filename,
                .{ .lock = .exclusive, .truncate = true },
            );
            errdefer cwd.deleteFile(init.io, filename) catch {};
            defer out_file.close(init.io);

            var fw = out_file.writer(init.io, &write_buffer);

            const meta_prog = std.Progress.start(init.io, .{});
            defer meta_prog.end();
            meta_prog.setName(name_writer.buffered());

            _ = streamFromUri(
                meta_prog,
                &cl,
                meta_uri,
                redibuf,
                &read_buffer,
                decomp_buffer,
                &name_buffer,
                &fw.interface,
            ) catch |e| return switch (e) {
                error.WriteFailed => fw.err.?,
                else => |err| err,
            };
        },
        .jar => {
            const meta_path = args_it.next() orelse return error.BadArgument;
            const jar_mode = std.meta.stringToEnum(JarMode, args_it.next() orelse return error.BadArgument) orelse
                return error.BadArgument;
            const filename = args_it.next() orelse return error.BadArgument;

            const meta_file = try cwd.openFile(init.io, meta_path, .{});
            defer meta_file.close(init.io);

            const value = blk: {
                var fr = meta_file.reader(init.io, &read_buffer);
                var json_r = json.Reader.init(init.gpa, &fr.interface);
                defer json_r.deinit();

                break :blk try json.parseFromTokenSourceLeaky(
                    json.Value,
                    init.arena.allocator(),
                    &json_r,
                    .{},
                );
            };

            const dlinfo = value.object.get("downloads").?.object.get(@tagName(jar_mode)).?.object;

            // const size = dlinfo.get("size").?.integer;
            const requested_uri = try Uri.parse(dlinfo.get("url").?.string);

            const out_file = try cwd.createFile(init.io, filename, .{
                .lock = .exclusive,
                .truncate = true,
            });
            errdefer cwd.deleteFile(init.io, filename) catch {};
            defer out_file.close(init.io);

            var fw = out_file.writer(init.io, &write_buffer);

            name_writer.print("downloading {s} jar: {f}", .{ value.object.get("id").?.string, requested_uri }) catch {};
            const man_prog = std.Progress.start(init.io, .{});
            defer man_prog.end();
            man_prog.setName(name_writer.buffered());

            _ = streamFromUri(
                man_prog,
                &cl,
                requested_uri,
                redibuf,
                &read_buffer,
                decomp_buffer,
                &name_buffer,
                &fw.interface,
            ) catch |e| return switch (e) {
                error.WriteFailed => fw.err.?,
                else => |err| err,
            };
        },
        else => return error.NotYetImplemented,
    }
}

fn streamFromUri(
    progress: std.Progress.Node,
    client: *http.Client,
    uri: Uri,
    redibuf: []u8,
    readbuf: []u8,
    decomp_buffer: []u8,
    name_buffer: []u8,
    writer: *std.Io.Writer,
) !usize {
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    var resp = try req.receiveHead(redibuf);
    var decomp: http.Decompress = undefined;
    const reader = resp.readerDecompressing(
        readbuf,
        &decomp,
        decomp_buffer,
    );

    const total_info = progress.start("[total] 0s | 0B/0B (0%)", 0);
    defer total_info.end();

    const recv_info = progress.start("[receiving] 0B/s", 0);
    defer recv_info.end();

    const avg_info = progress.start("[average] 0B/s", 0);
    defer avg_info.end();

    progress.setCompletedItems(0);
    progress.setEstimatedTotalItems(resp.head.content_length orelse 0);

    var name_writer = Io.Writer.fixed(name_buffer);

    var now = Io.Timestamp.now(client.io, .boot);
    const start_time = now;

    var offset: usize = 0;
    var last_time = now;
    var avg_delta = Io.Duration.zero;
    var bytes_received: i96 = 0;
    var avg_bytes: i96 = 0;
    while (true) {
        const amt = reader.stream(writer, .unlimited) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return resp.bodyErr() orelse req.connection.?.stream_reader.err.?,
            error.WriteFailed => return error.WriteFailed,
        };
        if (amt == 0) continue;
        offset += amt;
        bytes_received += amt;
        progress.setCompletedItems(@intCast(offset));

        now = Io.Timestamp.now(client.io, .boot);
        const dt = last_time.durationTo(now);
        const time_offset = start_time.durationTo(now);
        last_time = now;
        avg_delta.nanoseconds += dt.nanoseconds;

        if (avg_delta.nanoseconds >= (std.time.ns_per_s / 4)) {
            avg_bytes = bytes_received + @divTrunc((avg_bytes - bytes_received) * 3, 4);
            avg_delta.nanoseconds = 0;
            bytes_received = 0;
        }

        if (resp.head.content_length) |len| {
            if (offset >= len) break;
            const progress_bar_len = 20;
            const hash_count = @min(progress_bar_len, (offset * progress_bar_len) / len);
            const empty_count = progress_bar_len - hash_count;
            name_write: {
                name_writer.end = 0;
                name_writer.print("[total] {f} | {Bi:.2}/{Bi:.2} ({d}% [", .{
                    time_offset, offset,
                    len,         (offset * 100) / len,
                }) catch break :name_write;
                var hash_buf = [_][]const u8{"#"};
                var empty_buf = [_][]const u8{"="};
                name_writer.writeSplatAll(&hash_buf, hash_count) catch break :name_write;
                name_writer.writeSplatAll(&empty_buf, empty_count) catch break :name_write;
                name_writer.writeAll("])") catch break :name_write;
            }
            total_info.setName(name_writer.buffered());
        } else {
            setNameFmt(total_info, &name_writer, "[total] {f} | {Bi:.2}", .{ time_offset, offset });
        }

        const recvd = @as(u64, @intCast(@divTrunc(@as(i96, amt) * std.time.ns_per_s, dt.nanoseconds)));
        setNameFmt(recv_info, &name_writer, "[receiving] {Bi:.2}/s", .{recvd});
        setNameFmt(avg_info, &name_writer, "[average] {Bi:.2}/s", .{@as(u64, @intCast(avg_bytes))});

        // std.log.debug("{f} | {Bi} in {f} | received: {Bi:.2}/s | avg: {Bi:.2}/s", .{
        //     time_offset,                   amt,
        //     dt,                            recvd,
        //     @as(u64, @intCast(avg_bytes)),
        // });
    }

    try writer.flush();

    return offset;
}

fn setNameFmt(progress: std.Progress.Node, writer: *Io.Writer, comptime fmt: []const u8, args: anytype) void {
    writer.end = 0;
    writer.print(fmt, args) catch {};
    progress.setName(writer.buffered());
}
