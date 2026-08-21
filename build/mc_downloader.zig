const std = @import("std");
const Cache = @import("Cache.zig");

const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;

const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const DownloadMode = enum { jar, assets };
const JarMode = enum { client, server };

var draw_buffer: [10240]u8 = undefined;

/// Command line:\
/// `<exe> <cache_path> jar [client/server] <out_file> (<version>)`\
/// `<exe> <cache_path> assets <out_dir> (<version>)`\
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const cache = try init.gpa.create(Cache);
    defer init.gpa.destroy(cache);

    // const progress_draw_buffer = try init.gpa.alloc(u8, 10240);
    // defer init.gpa.free(progress_draw_buffer);

    var args_it = try init.minimal.args.iterateAllocator(arena);
    defer args_it.deinit();
    _ = args_it.skip();

    try cache.init(init.io, init.gpa, args_it.next() orelse return error.MissingArgument);
    defer cache.deinit();
    try cache.http_client.initDefaultProxies(arena, init.environ_map);

    const mode = std.meta.stringToEnum(DownloadMode, args_it.next() orelse return error.BadArgument) orelse
        return error.BadArgument;

    const root_prog = std.Progress.start(init.io, .{
        .draw_buffer = &draw_buffer,
    });
    defer root_prog.end();

    const manifest = blk: {
        const manifest_prog = root_prog.start("Download latest manifest", 0);
        defer manifest_prog.end();
        break :blk try cache.getManifest(arena, manifest_prog, true);
    };

    switch (mode) {
        .jar => {
            const jar_mode = std.meta.stringToEnum(JarMode, args_it.next() orelse return error.BadArgument) orelse
                return error.BadArgument;
            const filename = args_it.next() orelse return error.BadArgument;
            const version = vblk: {
                const id = args_it.next() orelse "latest";
                const vid = if (eql(u8, id, "latest") or eql(u8, id, "latest-release"))
                    manifest.latest.release
                else if (eql(u8, id, "latest-snapshot"))
                    manifest.latest.snapshot
                else
                    id;

                for (manifest.versions) |ver| {
                    if (eql(u8, ver.id, vid)) {
                        break :vblk ver;
                    }
                }

                return error.VersionNotFound;
            };

            var sha1: [Sha1.digest_length]u8 = undefined;
            const meta = meta_blk: {
                const meta_prog = root_prog.startFmt(0, "Downloading meta for version {s}", .{version.id});
                defer meta_prog.end();

                if (version.sha1) |sha1_str| {
                    try Cache.decodeSha1(&sha1, sha1_str);

                    break :meta_blk try cache.getMetaSha1(arena, &sha1, version.id, meta_prog, true);
                }
                break :meta_blk try cache.getMetaUrl(arena, version.url, meta_prog, true);
            };

            const jar_path = jar: {
                const jar_prog = root_prog.startFmt(0, "Downloading jar for version {s}", .{version.id});
                defer jar_prog.end();

                const dl: Cache.Meta.Download = switch (jar_mode) {
                    inline else => |tag| @field(meta.downloads, @tagName(tag)),
                };
                try Cache.decodeSha1(&sha1, &dl.sha1);

                break :jar try cache.getJarSha1(init.gpa, &sha1, @tagName(jar_mode), jar_prog, true);
            };
            defer init.gpa.free(jar_path);

            const out_file = try Io.Dir.cwd().createFile(init.io, filename, .{});
            defer out_file.close(init.io);

            const jar_file = try Io.Dir.cwd().openFile(init.io, jar_path, .{ .lock = .shared });
            defer jar_file.close(init.io);

            var fw = out_file.writer(init.io, &cache.write_buffer);
            var fr = jar_file.reader(init.io, &cache.read_buffer);

            _ = fw.interface.sendFileAll(&fr, .unlimited) catch |e| return switch (e) {
                error.ReadFailed => fr.err.?,
                error.WriteFailed => fw.err.?,
            };

            try fw.flush();
        },
        .assets => {
            const out_dir_path = args_it.next() orelse return error.BadArgument;

            const out_dir = try Io.Dir.cwd().createDirPathOpen(init.io, out_dir_path, .{});
            defer out_dir.close(init.io);

            const version = vblk: {
                const id = args_it.next() orelse "latest";
                const vid = if (eql(u8, id, "latest") or eql(u8, id, "latest-release"))
                    manifest.latest.release
                else if (eql(u8, id, "latest-snapshot"))
                    manifest.latest.snapshot
                else
                    id;

                for (manifest.versions) |ver| {
                    if (eql(u8, ver.id, vid)) {
                        break :vblk ver;
                    }
                }

                return error.VersionNotFound;
            };

            var sha1: [Sha1.digest_length]u8 = undefined;
            const meta = meta_blk: {
                const meta_prog = root_prog.startFmt(0, "Downloading meta for version {s}", .{version.id});
                defer meta_prog.end();

                if (version.sha1) |sha1_str| {
                    try Cache.decodeSha1(&sha1, sha1_str);

                    break :meta_blk try cache.getMetaSha1(arena, &sha1, version.id, meta_prog, true);
                }
                break :meta_blk try cache.getMetaUrl(arena, version.url, meta_prog, true);
            };

            const asset_index = asset_blk: {
                const assidx_prog = root_prog.startFmt(0, "Downloading asset index for version {s}", .{version.id});
                defer assidx_prog.end();

                try Cache.decodeSha1(&sha1, &meta.assetIndex.sha1);

                break :asset_blk try cache.getAssetDirSha1(arena, &sha1, meta.assets, assidx_prog, true);
            };

            const assets_prog = root_prog.startFmt(0, "Downloading assets for version {s}", .{version.id});
            defer assets_prog.end();

            try cache.copyAssets(out_dir, asset_index, 5, assets_prog);
        },
    }

    try cache.saveHashes();
}
