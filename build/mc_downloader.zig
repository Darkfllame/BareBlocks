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

const AssetResult = struct {
    name: ?[]const u8,
    err: ?anyerror,
};

const AssetRequest = struct {
    name: []const u8,
    hash: []const u8,
};

const DownloadMode = enum { manifest, meta, jar, assets };
const JarMode = enum { client, server };
const AssetsMode = enum { json, files };

/// Command line:\
/// `<exe> manifest <out_file> (<url> ...)`\
/// `<exe> meta <manifest_file> <out_file> (<version>)`\
/// `<exe> jar [client/server] <meta_file> <out_file>`\
/// `<exe> assets json <meta_file> <out_file>`\
/// `<exe> assets files <json_file> <out_dir>`\
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var cl: http.Client = .{ .allocator = init.gpa, .io = init.io };
    try cl.initDefaultProxies(arena, init.environ_map);
    defer cl.deinit();

    const cwd = Io.Dir.cwd();
    var redibuf = try init.gpa.alloc(u8, 8 * 1024);
    defer init.gpa.free(redibuf);
    const decomp_buffer = try arena.alloc(u8, @max(
        std.compress.flate.max_window_len,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    ));
    var read_buffer: [4096]u8 = undefined;
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

            for (manifest_urls.items, 0..) |uri, i| {
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
                    true,
                ) catch |e| {
                    const real_error = if (e != error.WriteFailed) e else return fw.err.?;

                    std.log.err("Error downloading manifest file: {t}", .{real_error});

                    try fw.seekTo(0);

                    if (i + 1 >= manifest_urls.items.len) {
                        return real_error;
                    }
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
                true,
            ) catch |e| return switch (e) {
                error.WriteFailed => fw.err.?,
                else => |err| err,
            };
        },
        .jar => {
            const jar_mode = std.meta.stringToEnum(JarMode, args_it.next() orelse return error.BadArgument) orelse
                return error.BadArgument;
            const meta_path = args_it.next() orelse return error.BadArgument;
            const filename = args_it.next() orelse return error.BadArgument;

            const value = blk: {
                const meta_file = try cwd.openFile(init.io, meta_path, .{});
                defer meta_file.close(init.io);

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
            const jar_prog = std.Progress.start(init.io, .{});
            defer jar_prog.end();
            jar_prog.setName(name_writer.buffered());

            _ = streamFromUri(
                jar_prog,
                &cl,
                requested_uri,
                redibuf,
                &read_buffer,
                decomp_buffer,
                &name_buffer,
                &fw.interface,
                true,
            ) catch |e| return switch (e) {
                error.WriteFailed => fw.err.?,
                else => |err| err,
            };
        },
        .assets => {
            const assets_mode = std.meta.stringToEnum(AssetsMode, args_it.next() orelse return error.BadArgument) orelse
                return error.BadArgument;
            if (assets_mode == .files) {
                _ = init.arena.reset(.free_all);
                redibuf = init.gpa.realloc(redibuf, 0) catch unreachable;
            }
            const json_path = args_it.next() orelse return error.BadArgument;
            const filename = args_it.next() orelse return error.BadArgument;

            const value = blk: {
                const json_file = try cwd.openFile(init.io, json_path, .{});
                defer json_file.close(init.io);

                var fr = json_file.reader(init.io, &read_buffer);
                var json_r = json.Reader.init(init.gpa, &fr.interface);
                defer json_r.deinit();

                break :blk try json.parseFromTokenSourceLeaky(
                    json.Value,
                    init.arena.allocator(),
                    &json_r,
                    .{},
                );
            };

            const assets_prog = std.Progress.start(init.io, .{});
            defer assets_prog.end();

            switch (assets_mode) {
                .json => {
                    const requested_uri = try Uri.parse(value.object.get("assetIndex").?.object.get("url").?.string);

                    const out_file = try cwd.createFile(init.io, filename, .{
                        .lock = .exclusive,
                        .truncate = true,
                    });
                    errdefer cwd.deleteFile(init.io, filename) catch {};
                    defer out_file.close(init.io);

                    var fw = out_file.writer(init.io, &write_buffer);

                    name_writer.print("downloading minecraft {s} assets json: {f}", .{ value.object.get("id").?.string, requested_uri }) catch {};
                    assets_prog.setName(name_writer.buffered());

                    _ = streamFromUri(
                        assets_prog,
                        &cl,
                        requested_uri,
                        redibuf,
                        &read_buffer,
                        decomp_buffer,
                        &name_buffer,
                        &fw.interface,
                        true,
                    ) catch |e| return switch (e) {
                        error.WriteFailed => fw.err.?,
                        else => |err| err,
                    };
                },
                .files => {
                    const out_dir = try cwd.openDir(init.io, filename, .{});
                    defer out_dir.close(init.io);

                    const objects = value.object.get("objects").?.object;
                    if (objects.count() == 0) return;

                    name_writer.print("downloading minecraft assets", .{}) catch {};
                    assets_prog.setName(name_writer.buffered());
                    assets_prog.setEstimatedTotalItems(objects.count());

                    var group = Io.Group.init;
                    defer group.cancel(init.io);

                    var in_queue_buffer: [32]AssetRequest = undefined;
                    var in_queue = Io.Queue(AssetRequest).init(&in_queue_buffer);

                    var out_queue_buffer: [32]AssetResult = undefined;
                    var out_queue = Io.Queue(AssetResult).init(&out_queue_buffer);

                    for (0..try std.Thread.getCpuCount()) |_| {
                        try group.concurrent(init.io, assetWorker, .{
                            &cl, assets_prog, init.gpa, out_dir, &in_queue, &out_queue,
                        });
                    }

                    try group.concurrent(init.io, assetAppender, .{ init.io, objects, &in_queue });

                    var had_error: bool = false;
                    var count: usize = 0;
                    while (out_queue.getOneUncancelable(init.io)) |res| {
                        count += 1;
                        if (res.err) |e| {
                            if (res.name) |nm| {
                                std.log.err("Error downloading asset \"{s}\": {t}", .{ nm, e });
                            } else {
                                std.log.err("Error downloading asset, couldn't start thread: {t}", .{e});
                            }
                            had_error = true;
                        }
                        if (count >= objects.count()) break;
                    } else |_| {}

                    if (had_error) {
                        return error.DownloadFailed;
                    }
                },
            }
        },
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
    extra_info: bool,
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

    const Node = std.Progress.Node;

    const total_info: Node, const recv_info: Node, const avg_info: Node = if (extra_info)
        .{
            progress.start("[total] 0s | 0B/0B (0%)", 0),
            progress.start("[receiving] 0B/s", 0),
            progress.start("[average] 0B/s", 0),
        }
    else
        .{ undefined, undefined, undefined };

    defer if (extra_info) {
        total_info.end();
        recv_info.end();
        avg_info.end();
    };

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
            error.ReadFailed => return resp.bodyErr() orelse (req.connection.?.stream_reader.err orelse switch (decomp) {
                .none => unreachable,
                .flate => |fd| fd.err.?,
                .zstd => |zd| zd.err.?,
            }),
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
            if (extra_info) {
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
            }
        } else if (extra_info) {
            setNameFmt(total_info, &name_writer, "[total] {f} | {Bi:.2}", .{ time_offset, offset });
        }

        if (extra_info) {
            const recvd = @as(u64, @intCast(@divTrunc(@as(i96, amt) * std.time.ns_per_s, dt.nanoseconds)));
            setNameFmt(recv_info, &name_writer, "[receiving] {Bi:.2}/s", .{recvd});
            setNameFmt(avg_info, &name_writer, "[average] {Bi:.2}/s", .{@as(u64, @intCast(avg_bytes))});
        }
    }

    try writer.flush();

    return offset;
}

fn setNameFmt(progress: std.Progress.Node, writer: *Io.Writer, comptime fmt: []const u8, args: anytype) void {
    writer.end = 0;
    writer.print(fmt, args) catch {};
    progress.setName(writer.buffered());
}

fn assetAppender(io: Io, objects: json.ObjectMap, in_queue: *Io.Queue(AssetRequest)) Io.Cancelable!void {
    var it = objects.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const hash = entry.value_ptr.object.get("hash").?.string;

        in_queue.putOneUncancelable(io, .{
            .name = name,
            .hash = hash,
        }) catch unreachable;
    }
    in_queue.close(io);
}

fn assetWorker(
    cl: *http.Client,
    progress_node: std.Progress.Node,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    in_queue: *Io.Queue(AssetRequest),
    out_queue: *Io.Queue(AssetResult),
) Io.Cancelable!void {
    const redibuf = gpa.alloc(u8, 8 * 1024) catch |e| {
        out_queue.putOneUncancelable(cl.io, .{ .name = null, .err = e }) catch {};
        return;
    };
    defer gpa.free(redibuf);
    const decomp_buffer = gpa.alloc(u8, @max(
        std.compress.flate.max_window_len,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    )) catch |e| {
        out_queue.putOneUncancelable(cl.io, .{ .name = null, .err = e }) catch {};
        return;
    };
    defer gpa.free(decomp_buffer);

    while (in_queue.getOne(cl.io)) |req| {
        const res = assetWorkerDownload(cl, progress_node, gpa, out_dir, req, redibuf, decomp_buffer);
        out_queue.putOneUncancelable(cl.io, .{
            .name = req.name,
            .err = if (res) |_| null else |e| e,
        }) catch return;
    } else |e| return switch (e) {
        error.Closed => {},
        error.Canceled => error.Canceled,
    };
}

fn assetWorkerDownload(
    cl: *http.Client,
    progress_node: std.Progress.Node,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    req: AssetRequest,
    redibuf: []u8,
    decomp_buffer: []u8,
) !void {
    var do_close = false;
    var asset_filename = req.name;
    const file_dir = if (std.mem.findScalarLast(u8, req.name, '/')) |last_slash| blk: {
        do_close = true;
        asset_filename = req.name[last_slash + 1 ..];
        break :blk try out_dir.createDirPathOpen(cl.io, req.name[0..last_slash], .{});
    } else out_dir;
    defer if (do_close) file_dir.close(cl.io);

    const file = try file_dir.createFile(cl.io, asset_filename, .{
        .lock = .exclusive,
        .truncate = true,
    });
    errdefer file_dir.deleteFile(cl.io, asset_filename) catch {};
    defer file.close(cl.io);

    var write_buffer: [4096]u8 = undefined;
    var read_buffer: [4096]u8 = undefined;
    var name_buffer: [1024]u8 = undefined;
    var fw = file.writer(cl.io, &write_buffer);

    const uri_buffer = try gpa.alloc(u8, ressource_base_url.len + 3 + req.hash.len);
    defer gpa.free(uri_buffer);

    const uri = blk: {
        var uri_writer = Io.Writer.fixed(uri_buffer);
        uri_writer.print("{s}{s}/{s}", .{ ressource_base_url, req.hash[0..2], req.hash }) catch unreachable;
        break :blk Uri.parse(uri_writer.buffered()) catch unreachable;
    };

    const child_prog = progress_node.startFmt(0, "Downloading {s}: {s}", .{
        req.name, req.hash,
    });
    defer child_prog.end();

    _ = streamFromUri(
        child_prog,
        cl,
        uri,
        redibuf,
        &read_buffer,
        decomp_buffer,
        &name_buffer,
        &fw.interface,
        false,
    ) catch |e| return switch (e) {
        error.WriteFailed => fw.err.?,
        else => |err| err,
    };
}
