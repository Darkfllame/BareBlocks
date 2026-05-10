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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var cl: http.Client = .{ .allocator = init.gpa, .io = init.io };
    try cl.initDefaultProxies(arena, init.environ_map);
    defer cl.deinit();

    var manifest_urls = try std.ArrayList(Uri).initCapacity(init.gpa, default_uris.len);
    defer manifest_urls.deinit(init.gpa);

    var out_file_path: ?[]u8 = null;
    var required_version: ?[]u8 = null;

    var args_it = try init.minimal.args.iterateAllocator(arena);
    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (arg.len <= 1 or arg[0] != '-') return error.BadArgument;

        switch (arg[1]) {
            'v' => {
                const str = if (arg.len > 2)
                    arg[2..]
                else
                    args_it.next() orelse return error.BadArgument;
                if (required_version != null) return error.ArgumentAlreadySpecified;
                required_version = try arena.dupe(u8, str);
            },
            'm' => {
                const str = if (arg.len > 2)
                    arg[2..]
                else
                    args_it.next() orelse return error.BadArgument;
                try manifest_urls.append(init.gpa, try Uri.parse(try arena.dupe(u8, str)));
            },
            'o' => {
                const str = if (arg.len > 2)
                    arg[2..]
                else
                    args_it.next() orelse return error.BadArgument;
                if (out_file_path != null) return error.ArgumentAlreadySpecified;
                out_file_path = try arena.dupe(u8, str);
            },
            else => return error.UnknownArgument,
        }
    }

    if (manifest_urls.items.len == 0) {
        manifest_urls.appendSliceAssumeCapacity(default_uris);
    }

    const jar_prog = std.Progress.start(init.io, .{ .estimated_total_items = manifest_urls.items.len });
    defer jar_prog.end();

    const filename = out_file_path orelse if (required_version) |rv|
        try std.fmt.allocPrint(arena, "minecraft_{s}.jar", .{rv})
    else
        "minecraft_latest";

    const file = try Io.Dir.cwd().createFile(
        init.io,
        filename,
        .{ .lock = .exclusive },
    );
    errdefer Io.Dir.cwd().deleteFile(init.io, filename) catch {};
    defer file.close(init.io);

    var filew_buffer: [1024]u8 = undefined;
    var filew = file.writer(init.io, &filew_buffer);

    var buffer: [1024]u8 = undefined;
    var bufw = Io.Writer.fixed(&buffer);

    for (manifest_urls.items) |uri| {
        jar_prog.completeOne();
        uri.format(&bufw) catch {};
        const uri_prog = jar_prog.start(bufw.buffered(), 0);

        bufw.end = 0;
        getJarFromUri(uri_prog, &cl, arena, uri, required_version, &buffer, &filew.interface) catch |e| {
            bufw.print("{f} | {t}", .{
                uri,
                if (e == error.WriteFailed) filew.err orelse filew.write_file_err.? else e,
            }) catch unreachable;
            uri_prog.setName(bufw.buffered());
            uri_prog.setEstimatedTotalItems(0);
            bufw.end = 0;
            try filew.seekTo(0);
            continue;
        };
        uri_prog.end();
        return;
    }
    return error.DownloadFailed;
}

fn getJarFromUri(
    progress: std.Progress.Node,
    client: *http.Client,
    arena: std.mem.Allocator,
    uri: Uri,
    required_version: ?[]const u8,
    buffer: []u8,
    out: *std.Io.Writer,
) !void {
    const meta_url = blk: {
        const curr_node = progress.start("Fetching version", 0);
        defer curr_node.end();
        break :blk try getMetaFromUri(client, arena, uri, required_version, buffer);
    };
    const js_val = blk: {
        const curr_node = progress.start("Fetching meta", 0);
        defer curr_node.end();
        break :blk try getJsonFromUri(client, arena, try Uri.parse(meta_url), buffer);
    };

    const server_download = js_val.object
        .get("downloads").?.object
        .get("server").?.object;
    // const sha1 = server_download.get("sha1").?.string;
    const size = server_download.get("size").?.integer;
    const url = server_download.get("url").?.string;

    var req: http.Client.Request = undefined;
    {
        const curr_node = progress.start("Fetching jar", 0);
        defer curr_node.end();

        req = try client.request(.GET, try Uri.parse(url), .{});
        errdefer req.deinit();
        try req.sendBodiless();
    }
    defer req.deinit();

    var response = try req.receiveHead(buffer);
    const reader = response.reader(buffer);

    var offset: usize = 0;
    const expected: usize = @bitCast(size);
    progress.setEstimatedTotalItems(expected);
    const child = progress.start("downloading jar", 100);
    defer child.end();

    while (true) {
        offset += reader.stream(out, .unlimited) catch |err| switch (err) {
            error.EndOfStream => {
                if (offset != expected) return error.EndOfStream;
                break;
            },
            error.ReadFailed => return response.bodyErr() orelse req.connection.?.getReadError().?,
            error.WriteFailed => |e| return e,
        };
        progress.setCompletedItems(offset);
        child.setCompletedItems((offset * 100) / expected);
    }
}

fn getMetaFromUri(
    client: *http.Client,
    arena: std.mem.Allocator,
    uri: Uri,
    required_version: ?[]const u8,
    buffer: []u8,
) ![]const u8 {
    const js_val = try getJsonFromUri(client, arena, uri, buffer);

    const release = required_version orelse
        js_val.object.get("latest").?.object.get("release").?.string;
    const versions = js_val.object.get("versions").?.array.items;
    for (versions) |v| {
        if (eql(u8, v.object.get("id").?.string, release)) {
            return v.object.get("url").?.string;
        }
    }
    return error.JarUrlNotFound;
}

fn getJsonFromUri(
    client: *http.Client,
    arena: std.mem.Allocator,
    uri: Uri,
    buffer: []u8,
) !json.Value {
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    var response = try req.receiveHead(buffer);
    var decomp: http.Decompress = undefined;
    const decomp_buffer = try arena.alloc(u8, @max(
        std.compress.flate.max_window_len,
        std.compress.zstd.block_size_max,
    ));
    const reader = response.readerDecompressing(
        buffer,
        &decomp,
        decomp_buffer,
    );

    var json_reader = json.Reader.init(arena, reader);
    defer json_reader.deinit();
    var diag: json.Diagnostics = .{};
    json_reader.enableDiagnostics(&diag);
    errdefer std.debug.dumpHex(reader.buffer);

    return json.Value.jsonParse(
        arena,
        &json_reader,
        .{
            .max_value_len = ~@as(usize, 0),
        },
    ) catch |e| switch (e) {
        error.ReadFailed => response.bodyErr().?,
        else => |e2| err: {
            // std.debug.dumpStackTrace(@errorReturnTrace().?);
            std.log.err("{t} at {d}:{d} (offset: {d})", .{
                e2,                   diag.getLine(), diag.getColumn(),
                diag.getByteOffset(),
            });
            break :err e2;
        },
    };
}
