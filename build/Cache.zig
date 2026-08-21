const Cache = @This();
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const http = std.http;
const json = std.json;

const assert = std.debug.assert;

const manifest_uris = &[_]Uri{
    Uri.parse("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") catch unreachable,
    Uri.parse("https://piston-meta.mojang.com/mc/game/version_manifest.json") catch unreachable,
};

const package_v1_base_url = "https://piston-meta.mojang.com/v1/packages/";
const objects_v1_base_url = "https://piston-data.mojang.com/v1/objects/";
const ressource_base_url = "https://resources.download.minecraft.net/";

const CachedFile = struct { hash: [Sha1.digest_length]u8, path: []const u8 };

const FileRegistry = struct {
    rw_lock: Io.RwLock,
    files: std.MultiArrayList(CachedFile),

    fn deinit(self: *FileRegistry, allocator: Allocator) void {
        self.reset(allocator);
        self.files.deinit(allocator);
    }
    fn reset(self: *FileRegistry, allocator: Allocator) void {
        const paths = self.files.slice().items(.path);
        for (paths) |s| allocator.free(s);
        self.files.clearRetainingCapacity();
    }
};

fn fillHashes(self: *Cache, reader: *Io.Reader) !void {
    var filled: std.EnumSet(CachedFileType) = .empty;
    while (true) {
        const block_type = try reader.takeByte();
        const cft: CachedFileType = switch (block_type) {
            else => break, // conventionally should be zero
            @intFromEnum(CachedFileType.meta)...@intFromEnum(CachedFileType.jar) => @enumFromInt(block_type),
        };
        if (filled.contains(cft)) return error.DuplicateHashDirectory;
        filled.setPresent(cft, true);
        const files_count = try reader.takeInt(u32, .native);

        const reg = self.registries.getPtr(cft);
        reg.rw_lock.lockUncancelable(self.io);
        defer reg.rw_lock.unlock(self.io);
        reg.reset(self.allocator);

        const arr = &reg.files;
        try arr.ensureTotalCapacity(self.allocator, files_count);
        errdefer reg.reset(self.allocator);

        for (0..files_count) |_| {
            const new_elem_idx = arr.addOneAssumeCapacity();
            errdefer arr.len -= 1;

            const slice = arr.slice();

            try reader.readSliceAll(&slice.items(.hash)[new_elem_idx]);

            const path_slice_len = try reader.takeInt(u16, .native);
            const path_slice = try self.allocator.alloc(u8, path_slice_len);
            errdefer self.allocator.free(path_slice);
            slice.items(.path)[new_elem_idx] = path_slice;

            try reader.readSliceAll(path_slice);
        }
    }
    var f_it = filled.complement().iterator();
    while (f_it.next()) |cft| {
        const reg = self.registries.getPtr(cft);

        reg.rw_lock.lockUncancelable(self.io);
        defer reg.rw_lock.unlock(self.io);

        reg.reset(self.allocator);
    }
}

fn writeHashes(self: *Cache, writer: *Io.Writer) !void {
    var ft_it = self.registries.iterator();
    while (ft_it.next()) |en| {
        const reg = en.value;
        reg.rw_lock.lockSharedUncancelable(self.io);
        defer reg.rw_lock.unlockShared(self.io);

        const arr = &reg.files;
        if (arr.len == 0) continue;

        try writer.writeByte(@intFromEnum(en.key));
        try writer.writeInt(u32, @intCast(arr.len), .native);

        const slice = arr.slice();

        for (0..slice.len) |index| {
            const elem = slice.get(index);

            try writer.writeAll(&elem.hash);
            try writer.writeInt(u16, @intCast(elem.path.len), .native);
            try writer.writeAll(elem.path);
        }
    }
    try writer.writeByte(0);
}

fn streamFromUriBufless(self: *Cache, progress: std.Progress.Node, uri: Uri, writer: *std.Io.Writer, extra_info: bool) !usize {
    return self.streamFromUri(progress, uri, &self.redibuf, &self.read_buffer, &self.decomp_buffer, &self.name_buffer, writer, extra_info);
}

fn streamFromUri(
    self: *Cache,
    progress: std.Progress.Node,
    uri: Uri,
    redibuf: []u8,
    readbuf: []u8,
    decomp_buffer: []u8,
    name_buffer: []u8,
    writer: *std.Io.Writer,
    extra_info: bool,
) !usize {
    var req = try self.http_client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    var resp = req.receiveHead(redibuf) catch |e| return switch (e) {
        error.ReadFailed => req.connection.?.getReadError().?,
        else => |err| err,
    };
    var decomp: http.Decompress = undefined;
    const reader = resp.readerDecompressing(
        readbuf,
        &decomp,
        decomp_buffer,
    );

    const Node = std.Progress.Node;

    const uri_info: Node, const total_info: Node, const recv_info: Node, const avg_info: Node = if (extra_info) blk: {
        const a = progress.startFmt(0, "[url] {f}", .{uri});
        const b = progress.start("[total] 0s | 0B/0B (0%)", 0);
        const c = progress.start("[receiving] 0B/s", 0);
        const d = progress.start("[average] 0B/s", 0);
        break :blk .{ a, b, c, d };
    } else .{ undefined, undefined, undefined, undefined };

    defer if (extra_info) {
        uri_info.end();
        total_info.end();
        recv_info.end();
        avg_info.end();
    };

    progress.setCompletedItems(0);
    // This is a workaround until https://codeberg.org/ziglang/zig/issues/36598 is fixed
    const estimated = resp.head.content_length orelse 0;
    progress.setEstimatedTotalItems(if (estimated > (std.math.maxInt(u32) / 100)) 0 else estimated);

    var name_writer = Io.Writer.fixed(name_buffer);

    var now = Io.Timestamp.now(self.io, .boot);
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
        progress.setCompletedItems(offset); // crashes if over 42.9 millions

        now = Io.Timestamp.now(self.io, .boot);
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

fn assetWorker(
    self: *Cache,
    progress_node: std.Progress.Node,
    out_dir: Io.Dir,
    max_retries: u32,
) Io.Cancelable!void {
    const in_queue = &self.download_queue;
    const out_queue = &self.download_result_queue;
    const redibuf = self.allocator.alloc(u8, 8 * 1024) catch |e| {
        out_queue.putOneUncancelable(self.io, .{ .name = null, .err = e }) catch {};
        return;
    };
    defer self.allocator.free(redibuf);
    const decomp_buffer = self.allocator.alloc(u8, @max(
        std.compress.flate.max_window_len,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    )) catch |e| {
        out_queue.putOneUncancelable(self.io, .{ .name = null, .err = e }) catch {};
        return;
    };
    defer self.allocator.free(decomp_buffer);

    while (in_queue.getOne(self.io)) |req| {
        const res = self.assetWorkerDownload(progress_node, out_dir, max_retries, req, redibuf, decomp_buffer);
        out_queue.putOneUncancelable(self.io, .{
            .name = req.name,
            .err = if (res) |_| null else |e| e,
        }) catch return;
    } else |e| return switch (e) {
        error.Closed => {},
        error.Canceled => error.Canceled,
    };
}

fn assetWorkerDownload(
    self: *Cache,
    progress_node: std.Progress.Node,
    out_dir: Io.Dir,
    max_retries: u32,
    req: AssetRequest,
    redibuf: []u8,
    decomp_buffer: []u8,
) !void {
    var do_close = false;
    var asset_filename = req.name;
    const file_dir = if (std.mem.findScalarLast(u8, req.name, '/')) |last_slash| blk: {
        do_close = true;
        asset_filename = req.name[last_slash + 1 ..];
        break :blk try out_dir.createDirPathOpen(self.io, req.name[0..last_slash], .{});
    } else out_dir;
    defer if (do_close) file_dir.close(self.io);

    const file = try file_dir.createFile(self.io, asset_filename, .{
        .lock = .exclusive,
        .truncate = true,
    });
    errdefer file_dir.deleteFile(self.io, asset_filename) catch {};
    defer file.close(self.io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var fw = file.writer(self.io, &write_buffer);
    if (try self.searchCache(.asset, req.hash)) |file_path| search: {
        const cached_file = self.root.openFile(self.io, file_path, .{ .lock = .shared }) catch |e| switch (e) {
            error.FileNotFound => break :search,
            else => |err| return err,
        };
        defer cached_file.close(self.io);

        var fr = cached_file.reader(self.io, &read_buffer);

        _ = fw.interface.sendFileAll(&fr, .unlimited) catch |e| return switch (e) {
            error.WriteFailed => fw.err.?,
            error.ReadFailed => fr.err.?,
        };
        try fw.flush();
    }

    var name_buffer: [1024]u8 = undefined;

    const uri_buffer = try self.allocator.alloc(u8, ressource_base_url.len + 3 + (Sha1.digest_length * 2));
    defer self.allocator.free(uri_buffer);

    const uri = blk: {
        var uri_writer = Io.Writer.fixed(uri_buffer);
        uri_writer.print("{s}{x:0>2}/{x}", .{ ressource_base_url, req.hash[0], req.hash }) catch unreachable;
        break :blk Uri.parse(uri_writer.buffered()) catch unreachable;
    };

    const child_prog = progress_node.startFmt(0, "Downloading {s}: {x}", .{
        req.name, req.hash,
    });
    defer child_prog.end();

    var aw = Io.Writer.Allocating.init(self.allocator);
    defer aw.deinit();

    for (0..max_retries) |i| {
        aw.clearRetainingCapacity();
        child_prog.setCompletedItems(0);

        _ = streamFromUri(
            self,
            child_prog,
            uri,
            redibuf,
            &read_buffer,
            decomp_buffer,
            &name_buffer,
            &aw.writer,
            false,
        ) catch |e| {
            if (i == max_retries - 1) {
                return switch (e) {
                    error.WriteFailed => fw.err.?,
                    else => |err| err,
                };
            }
            std.log.debug("Attempt {d} to download {f} failed: {t}", .{ i, uri, e });
            continue;
        };
        var cmp_hash: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(aw.written(), &cmp_hash, .{});
        if (!std.mem.eql(u8, req.hash, &cmp_hash)) {
            std.log.debug("Attempt {d} to download {f} failed: Mismatch hash values: {x}, {x}", .{
                i,        uri,
                req.hash, &cmp_hash,
            });
            continue;
        }
        break;
    }

    try self.writeCache(.asset, req.hash, aw.written());

    try fw.interface.writeAll(aw.written());
    try fw.flush();
}

fn assetAppender(self: *Cache, idx: AssetsIndex) Io.Cancelable!void {
    var it = idx.objects.iterator();
    while (it.next()) |en| {
        self.download_queue.putOne(self.io, .{
            .name = en.key_ptr.*,
            .hash = &en.value_ptr.hash,
        }) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable,
        };
    }
}

fn searchCache(self: *Cache, cft: CachedFileType, sha1: *const [Sha1.digest_length]u8) Io.Cancelable!?[]const u8 {
    const arr = self.registries.getPtr(cft);
    try arr.rw_lock.lockShared(self.io);
    defer arr.rw_lock.unlockShared(self.io);

    const old_prot = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(old_prot);

    const slice = arr.files.slice();

    for (0..slice.len) |i| {
        if (std.mem.eql(u8, &slice.items(.hash)[i], sha1)) {
            return slice.items(.path)[i];
        }
    }

    return null;
}

fn writeCache(self: *Cache, cft: CachedFileType, sha1: *const [Sha1.digest_length]u8, content: []const u8) !void {
    const arr = self.registries.getPtr(cft);
    try arr.rw_lock.lock(self.io);
    defer arr.rw_lock.unlock(self.io);

    const old_prot = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(old_prot);

    const new_reg_index = try arr.files.addOne(self.allocator);
    errdefer arr.files.len -= 1;
    @memcpy(&arr.files.items(.hash)[new_reg_index], sha1);

    const path_str = try self.allocator.alloc(u8, (switch (cft) {
        inline .meta, .asset_dir, .jar => |tag| @tagName(tag).len,
        .asset => 8,
    }) + 1 + (Sha1.digest_length * 2));
    errdefer self.allocator.free(path_str);

    const path_hash_start = path_str.len - (Sha1.digest_length * 2);
    path_str[path_hash_start - 1] = std.fs.path.sep;

    arr.files.items(.path)[new_reg_index] = path_str;
    switch (cft) {
        .meta, .asset_dir, .jar => @memcpy(path_str.ptr, @tagName(cft)),
        .asset => {
            @memcpy(path_str[0..5], "asset");
            path_str[5] = std.fs.path.sep;
            @memcpy(path_str[6..8], &std.fmt.hex(sha1[0]));
        },
    }

    const dir = try self.root.createDirPathOpen(self.io, path_str[0 .. path_hash_start - 1], .{});
    defer dir.close(self.io);

    var sp_w = Io.Writer.fixed(path_str[path_hash_start..]);
    sp_w.printHex(sha1, .lower) catch unreachable;
    assert(sp_w.end == sp_w.buffer.len);

    const file = try dir.createFile(self.io, sp_w.buffer, .{ .lock = .exclusive });
    defer file.close(self.io);

    var write_buffer: [1024]u8 = undefined;
    var fw = file.writer(self.io, &write_buffer);

    try fw.interface.writeAll(content);
    try fw.flush();
}

fn streamCacheFile(
    self: *Cache,
    cft: CachedFileType,
    sha1: *const [Sha1.digest_length]u8,
    gpa: Allocator,
    uri: Uri,
    progress: std.Progress.Node,
    extra_info: bool,
) ![:0]const u8 {
    const arr = self.registries.getPtr(cft);
    try arr.rw_lock.lock(self.io);
    defer arr.rw_lock.unlock(self.io);

    const new_reg_index = try arr.files.addOne(self.allocator);
    errdefer arr.files.len -= 1;
    @memcpy(&arr.files.items(.hash)[new_reg_index], sha1);

    const path_str = try self.allocator.alloc(u8, (switch (cft) {
        inline .meta, .asset_dir, .jar => |tag| @tagName(tag).len,
        .asset => 8,
    }) + 1 + (Sha1.digest_length * 2));
    errdefer self.allocator.free(path_str);

    const path_hash_start = path_str.len - (Sha1.digest_length * 2);
    path_str[path_hash_start - 1] = std.fs.path.sep;

    arr.files.items(.path)[new_reg_index] = path_str;
    switch (cft) {
        .meta, .asset_dir, .jar => @memcpy(path_str.ptr, @tagName(cft)),
        .asset => {
            @memcpy(path_str[0..5], "asset");
            path_str[5] = std.fs.path.sep;
            @memcpy(path_str[6..8], &std.fmt.hex(sha1[0]));
        },
    }

    const dir = try self.root.createDirPathOpen(self.io, path_str[0 .. path_hash_start - 1], .{});
    defer dir.close(self.io);

    var sp_w = Io.Writer.fixed(path_str[path_hash_start..]);
    sp_w.printHex(sha1, .lower) catch unreachable;
    assert(sp_w.end == sp_w.buffer.len);

    const file = try dir.createFile(self.io, sp_w.buffer, .{ .lock = .exclusive });
    defer file.close(self.io);

    const ret = try dir.realPathFileAlloc(self.io, sp_w.buffer, gpa);
    errdefer gpa.free(ret);

    var fw = file.writer(self.io, &.{});

    for (0..self.max_retries) |i| {
        try fw.seekToUnbuffered(0);
        progress.setCompletedItems(0);
        progress.setEstimatedTotalItems(0);

        var hw = fw.interface.hashed(Sha1.init(.{}), &self.write_buffer);

        _ = self.streamFromUriBufless(
            progress,
            uri,
            &hw.writer,
            extra_info,
        ) catch |e| return switch (e) {
            error.WriteFailed => fw.err.?,
            else => |err| {
                if (i == self.max_retries - 1) return err;
                std.log.err("Attempt {d} to download {f} failed: {t}", .{ i, uri, err });
                continue;
            },
        };

        var cmp_hash: [Sha1.digest_length]u8 = undefined;
        hw.hasher.final(&cmp_hash);
        if (!std.mem.eql(u8, sha1, &cmp_hash)) {
            std.log.err("Attempt {d} to download {f} failed: Mismatch hash values: {x}, {x}", .{
                i, uri, sha1, &cmp_hash,
            });
            continue;
        }

        break;
    }

    return ret;
}

fn hexToNibble(c: u8) error{InvalidCharacter}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F', 'a'...'f' => 0xa + ((c & (~@as(u8, 0b00100000))) - 'A'),
        else => error.InvalidCharacter,
    };
}

fn getFromPackageV1Url(
    self: *Cache,
    comptime T: type,
    comptime CFT: CachedFileType,
    arena: Allocator,
    url: []const u8,
    progress: std.Progress.Node,
    extra_info: bool,
) !T {
    if (!std.mem.startsWith(u8, url, package_v1_base_url))
        return error.UnknownPackageDir;
    // 46 because: 40 bytes of hash + /<name>.json
    if (url.len - package_v1_base_url.len < 46) return error.UrlTooShort;
    const hash = url[package_v1_base_url.len..][0 .. Sha1.digest_length * 2];
    const filename = url[package_v1_base_url.len + Sha1.digest_length * 2 + 1 ..];
    const id = filename[0 .. filename.len - ".json".len];

    var sha1: [Sha1.digest_length]u8 = undefined;
    try decodeSha1(&sha1, hash);

    if (try self.searchCache(CFT, &sha1)) |path| search: {
        const file = self.root.openFile(self.io, path, .{ .lock = .shared }) catch |e| switch (e) {
            error.FileNotFound => break :search,
            else => |err| return err,
        };
        defer file.close(self.io);

        var fr = file.reader(self.io, &self.read_buffer);

        var json_r = json.Reader.init(self.allocator, &fr.interface);
        defer json_r.deinit();

        return json.parseFromTokenSourceLeaky(T, arena, &json_r, .{ .allocate = .alloc_always });
    }

    return self.getFromPackageV1Sha1(T, CFT, arena, &sha1, id, progress, extra_info);
}

fn getFromPackageV1Sha1(
    self: *Cache,
    comptime T: type,
    comptime CFT: CachedFileType,
    arena: Allocator,
    sha1: *const [Sha1.digest_length]u8,
    id: []const u8,
    progress: std.Progress.Node,
    extra_info: bool,
) !T {
    if (try self.searchCache(CFT, sha1)) |path| search: {
        const file = self.root.openFile(self.io, path, .{ .lock = .shared }) catch |e| switch (e) {
            error.FileNotFound => break :search,
            else => |err| return err,
        };
        defer file.close(self.io);

        var fr = file.reader(self.io, &self.read_buffer);

        var json_r = json.Reader.init(self.allocator, &fr.interface);
        defer json_r.deinit();

        var diag: json.Diagnostics = .{};

        json_r.enableDiagnostics(&diag);

        return json.parseFromTokenSourceLeaky(T, arena, &json_r, .{
            .allocate = .alloc_always,
        }) catch |e| {
            std.log.err("error {t} at {d}:{d} ({d})", .{
                e, diag.line_number, diag.getColumn(), diag.getByteOffset(),
            });
            return e;
        };
    }

    const url_buffer, const uri = blk: {
        const url_buffer = try self.allocator.alloc(u8, package_v1_base_url.len +
            Sha1.digest_length * 2 + 1 + id.len + ".json".len);
        errdefer self.allocator.free(url_buffer);
        var url_w = Io.Writer.fixed(url_buffer);
        url_w.print("{s}{x}/{s}.json", .{ package_v1_base_url, sha1, id }) catch unreachable;
        break :blk .{
            url_buffer,
            Uri.parse(url_buffer) catch unreachable,
        };
    };
    defer self.allocator.free(url_buffer);

    var aw = Io.Writer.Allocating.init(self.allocator);
    defer aw.deinit();

    for (0..self.max_retries) |i| {
        aw.clearRetainingCapacity();
        progress.setCompletedItems(0);
        _ = self.streamFromUriBufless(progress, uri, &aw.writer, extra_info) catch |e| return switch (e) {
            error.WriteFailed => error.OutOfMemory,
            else => |err| {
                if (i == self.max_retries - 1) return err;
                std.log.err("Attempt {d} to download {f} failed: {t}", .{ i, uri, err });
                continue;
            },
        };
        var cmp_hash: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(aw.written(), &cmp_hash, .{});
        if (!std.mem.eql(u8, sha1, &cmp_hash)) {
            std.log.err("Attempt {d} to download {f} failed: Mismatch hash values: {x}, {x}", .{
                i,    uri,
                sha1, &cmp_hash,
            });
            continue;
        }
        break;
    }

    try self.writeCache(CFT, sha1, aw.written());
    try self.saveHashes();

    var scanner = json.Scanner.initCompleteInput(self.allocator, aw.written());
    defer scanner.deinit();

    return json.parseFromTokenSourceLeaky(T, arena, &scanner, .{
        .allocate = .alloc_always,
    });
}

io: Io,
allocator: Allocator,
root: Io.Dir,
lock_hash: Io.File,
registries: std.EnumArray(CachedFileType, FileRegistry),
max_retries: u32,

http_client: http.Client,
exec_group: Io.Group,
download_queue: Io.Queue(AssetRequest),
download_result_queue: Io.Queue(AssetResult),

download_buffer: [32]AssetRequest,
download_result_buffer: [32]AssetResult,

decomp_buffer: [@max(std.compress.flate.max_window_len, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max)]u8,
read_buffer: [4 * 1024]u8,
write_buffer: [4 * 1024]u8,
redibuf: [8 * 1024]u8,
name_buffer: [std.Progress.Node.max_name_len]u8,

pub const CachedFileType = enum(u8) { meta = 1, asset_dir = 2, asset = 3, jar = 4 };

pub const VersionType = enum { snapshot, release, old_beta, old_alpha };

pub const Asset = struct { hash: [Sha1.digest_length]u8, size: u64 };

pub const Manifest = struct {
    latest: struct { release: []const u8, snapshot: []const u8 },
    versions: []const struct {
        id: []const u8,
        type: VersionType,
        url: []const u8,
        time: []const u8,
        releaseTime: []const u8,
        sha1: ?*const [Sha1.digest_length * 2]u8 = null,
        complianceLevel: ?u32 = null,
    },
};

pub const Meta = struct {
    arguments: json.Value,
    assetIndex: struct {
        id: []const u8,
        sha1: [Sha1.digest_length * 2]u8,
        size: u64,
        totalSize: u64,
        url: []const u8,
    },
    assets: []const u8,
    complianceLevel: u32,
    downloads: struct {
        client: Download,
        client_mappings: ?Download = null,
        server: Download,
        server_mappings: ?Download = null,
    },
    id: []const u8,
    javaVersion: struct {
        component: []const u8,
        majorVersion: u32,
    },
    libraries: json.Value,
    logging: struct {
        client: struct {
            argument: []const u8,
            file: struct {
                id: []const u8,
                sha1: [Sha1.digest_length * 2]u8,
                size: u64,
                url: []const u8,
            },
            type: []const u8,
        },
    },
    mainClass: []const u8,
    minimumLauncherVersion: u32,
    releaseTime: []const u8,
    time: []const u8,
    type: VersionType,

    pub const Download = struct {
        sha1: [Sha1.digest_length * 2]u8,
        size: u64,
        url: []const u8,
    };
};

pub const AssetsIndex = struct {
    objects: std.StringHashMapUnmanaged(Asset),

    pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !AssetsIndex {
        if ((try source.next()) != .object_begin) return error.UnexpectedToken;
        var index = AssetsIndex{ .objects = .empty };

        var name = switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (!std.mem.eql(u8, name, "objects")) return error.UnknownField;
        if ((try source.next()) != .object_begin) return error.UnexpectedToken;
        while (true) {
            var tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
            name = switch (tok) {
                .string, .allocated_string => |s| s,
                .object_end => break,
                else => {
                    std.log.debug("tok: {t}", .{tok});
                    return error.UnexpectedToken;
                },
            };
            if ((try source.next()) != .object_begin) return error.UnexpectedToken;
            const gop = try index.objects.getOrPut(allocator, try allocator.dupe(u8, name));
            if (gop.found_existing) return error.DuplicateField;

            var fields_set: std.StaticBitSet(2) = .empty;
            while (true) {
                tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                name = switch (tok) {
                    .string, .allocated_string => |s| s,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };
                if (std.mem.eql(u8, name, "hash")) {
                    if (fields_set.isSet(0)) return error.DuplicateField;
                    fields_set.set(0);

                    tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                    name = switch (tok) {
                        .string, .allocated_string => |s| s,
                        else => return error.UnexpectedToken,
                    };
                    if (name.len != (Sha1.digest_length * 2)) return error.LengthMismatch;
                    try decodeSha1(&gop.value_ptr.hash, @ptrCast(name));
                } else if (std.mem.eql(u8, name, "size")) {
                    if (fields_set.isSet(1)) return error.DuplicateField;
                    fields_set.set(1);

                    tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                    name = switch (tok) {
                        .number, .allocated_number => |s| s,
                        else => return error.UnexpectedToken,
                    };
                    gop.value_ptr.size = try std.fmt.parseInt(@TypeOf(gop.value_ptr.size), name, 0);
                } else return error.UnknownField;
            }
        }

        if ((try source.next()) != .object_end) return error.UnexpectedToken;
        return index;
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !AssetsIndex {
        _ = options;
        const objects = blk: {
            if (source != .object) return error.UnexpectedToken;
            const source_objects = source.object;
            if (source_objects.count() != 1) return error.LengthMismatch;
            const res = source_objects.get("objects") orelse return error.MissingField;
            if (res != .object) return error.UnexpectedToken;
            break :blk res.object;
        };

        var assets = AssetsIndex{ .objects = .empty };
        try assets.objects.ensureTotalCapacity(allocator, objects.count());

        var it = objects.iterator();
        while (it.next()) |en| {
            const gop = assets.objects.getOrPutAssumeCapacity(en.key_ptr.*);
            assert(!gop.found_existing);

            if (en.value_ptr.* != .object) return error.UnexpectedToken;
            const asset_obj = en.value_ptr.object;
            if (asset_obj.count() != 2) return error.LengthMismatch;
            const hash_val = switch (asset_obj.get("hash") orelse return error.MissingField) {
                .string => |v| v,
                else => return error.UnexpectedToken,
            };
            const size_val = switch (asset_obj.get("size") orelse return error.MissingField) {
                .integer => |v| v,
                else => return error.UnexpectedToken,
            };

            if (hash_val.len != (Sha1.digest_length * 2)) return error.LengthMismatch;
            decodeSha1(&gop.value_ptr.hash, @ptrCast(hash_val));
            gop.value_ptr.size = @bitCast(size_val);
        }
    }
};

pub const AssetResult = struct {
    name: ?[]const u8,
    err: ?anyerror,
};

pub const AssetRequest = struct {
    name: []const u8,
    hash: *const [Sha1.digest_length]u8,
};

// Probably a bit overkill to directly make a minecraft asset downloader
// but I think it could be beneficial to me in the future as this part would have
// already been done (more or less).

pub fn decodeSha1(out: *[Sha1.digest_length]u8, in: *const [Sha1.digest_length * 2]u8) error{InvalidCharacter}!void {
    for (out, 0..) |*o, i| {
        const offset = i * 2;
        const hi = try hexToNibble(in[offset]);
        const lo = try hexToNibble(in[offset + 1]);
        o.* = (hi << 4) | lo;
    }
}

pub fn init(self: *Cache, io: Io, allocator: Allocator, cache_path: []const u8) !void {
    self.io = io;
    self.allocator = allocator;
    self.root = try Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
    errdefer self.root.close(io);
    self.registries = .initFill(.{
        .rw_lock = .init,
        .files = .empty,
    });
    self.max_retries = 5;

    self.http_client = .{ .io = io, .allocator = allocator };
    errdefer self.http_client.deinit();
    self.exec_group = .init;
    self.download_queue = .init(&self.download_buffer);
    self.download_result_queue = .init(&self.download_result_buffer);

    self.lock_hash = try self.root.createFile(io, "hashes", .{
        .lock = .exclusive,
        .read = true,
        .truncate = false,
    });
    errdefer self.lock_hash.close(io);

    if ((try self.lock_hash.length(io)) != 0) {
        var fr = self.lock_hash.reader(io, &self.read_buffer);

        self.fillHashes(&fr.interface) catch |e| return switch (e) {
            error.ReadFailed => fr.err.?,
            else => |err| err,
        };
    }

    try self.lock_hash.setLength(io, 0);
}

pub fn deinit(self: *Cache) void {
    self.download_result_queue.close(self.io);
    self.download_queue.close(self.io);
    self.exec_group.cancel(self.io);
    self.http_client.deinit();
    self.root.close(self.io);
    self.lock_hash.close(self.io);
    var ft_it = self.registries.iterator();
    while (ft_it.next()) |en| {
        en.value.deinit(self.allocator);
    }
    self.* = undefined;
}

pub fn saveHashes(self: *Cache) !void {
    var fw = self.lock_hash.writer(self.io, &self.write_buffer);
    try fw.seekToUnbuffered(0);

    self.writeHashes(&fw.interface) catch |e| switch (e) {
        error.WriteFailed => return fw.err.?,
    };

    try fw.flush();
}

pub fn getManifest(self: *Cache, arena: Allocator, progress: std.Progress.Node, extra_info: bool) !Manifest {
    var aw = Io.Writer.Allocating.init(self.allocator);
    defer aw.deinit();

    manloop: for (manifest_uris, 0..) |man_uri, i| {
        var name_w = Io.Writer.fixed(&self.name_buffer);
        setNameFmt(progress, &name_w, "Downloading manifest: {f}", .{man_uri});
        for (0..self.max_retries) |j| {
            aw.clearRetainingCapacity();
            progress.setCompletedItems(0);
            _ = self.streamFromUriBufless(progress, man_uri, &aw.writer, extra_info) catch |e| return esw: switch (e) {
                error.WriteFailed => error.OutOMemory,
                else => |err| {
                    std.log.err("Failed to use manifest at {f}: {t}", .{ man_uri, err });
                    if (j == self.max_retries - 1) {
                        if (i == manifest_uris.len - 1) break :esw err;
                        continue :manloop;
                    }
                    continue;
                },
            };
            break;
        }
    }

    var scanner = json.Scanner.initCompleteInput(self.allocator, aw.written());
    defer scanner.deinit();

    return json.parseFromTokenSourceLeaky(Manifest, arena, &scanner, .{
        .allocate = .alloc_always,
    });
}

pub fn getMetaUrl(self: *Cache, arena: Allocator, url: []const u8, progress: std.Progress.Node, extra_info: bool) !Meta {
    return self.getFromPackageV1Url(Meta, .meta, arena, url, progress, extra_info);
}

pub fn getMetaSha1(
    self: *Cache,
    arena: Allocator,
    sha1: *const [Sha1.digest_length]u8,
    id: []const u8,
    progress: std.Progress.Node,
    extra_info: bool,
) !Meta {
    return self.getFromPackageV1Sha1(Meta, .meta, arena, sha1, id, progress, extra_info);
}

pub fn getAssetDirUrl(self: *Cache, arena: Allocator, url: []const u8, progress: std.Progress.Node, extra_info: bool) !AssetsIndex {
    return self.getFromPackageV1Url(AssetsIndex, .asset_dir, arena, url, progress, extra_info);
}

pub fn getAssetDirSha1(
    self: *Cache,
    arena: Allocator,
    sha1: *const [Sha1.digest_length]u8,
    id: []const u8,
    progress: std.Progress.Node,
    extra_info: bool,
) !AssetsIndex {
    return self.getFromPackageV1Sha1(AssetsIndex, .asset_dir, arena, sha1, id, progress, extra_info);
}

pub fn getJarUrl(self: *Cache, gpa: Allocator, url: []const u8, progress: std.Progress.Node, extra_info: bool) ![:0]const u8 {
    if (!std.mem.startsWith(u8, url, objects_v1_base_url))
        return error.UnknownPackageDir;
    // 45 because: 40 bytes of hash + /<name>.jar
    if (url.len - objects_v1_base_url.len < 45) return error.UrlTooShort;
    const hash = url[objects_v1_base_url.len..][0 .. Sha1.digest_length * 2];
    const filename = url[objects_v1_base_url.len + Sha1.digest_length * 2 + 1 ..];
    const id = filename[0 .. filename.len - ".jar".len];

    var sha1: [Sha1.digest_length]u8 = undefined;
    try decodeSha1(&sha1, hash);

    if (try self.searchCache(.jar, &sha1)) |path| {
        return self.root.realPathFileAlloc(self.io, path, gpa);
    }

    return self.getJarSha1(gpa, &sha1, id, progress, extra_info);
}

pub fn getJarSha1(
    self: *Cache,
    gpa: Allocator,
    sha1: *const [Sha1.digest_length]u8,
    id: []const u8,
    progress: std.Progress.Node,
    extra_info: bool,
) ![:0]const u8 {
    if (try self.searchCache(.jar, sha1)) |path| {
        return self.root.realPathFileAlloc(self.io, path, gpa);
    }

    const url_buffer, const uri = blk: {
        const url_buffer = try self.allocator.alloc(u8, objects_v1_base_url.len +
            Sha1.digest_length * 2 + 1 + id.len + ".jar".len);
        errdefer self.allocator.free(url_buffer);
        var url_w = Io.Writer.fixed(url_buffer);
        url_w.print("{s}{x}/{s}.jar", .{ objects_v1_base_url, sha1, id }) catch unreachable;
        break :blk .{
            url_buffer,
            Uri.parse(url_buffer) catch unreachable,
        };
    };
    defer self.allocator.free(url_buffer);

    const ret = try self.streamCacheFile(.jar, sha1, gpa, uri, progress, extra_info);
    self.saveHashes() catch {};
    return ret;
}

pub fn copyAssets(self: *Cache, out_dir: Io.Dir, idx: AssetsIndex, max_retries: u32, progress: std.Progress.Node) !void {
    progress.setEstimatedTotalItems(idx.objects.count());
    for (0..try std.Thread.getCpuCount()) |_| {
        try self.exec_group.concurrent(self.io, assetWorker, .{ self, progress, out_dir, max_retries });
    }

    try self.exec_group.concurrent(self.io, assetAppender, .{ self, idx });

    var had_error = false;
    var count: usize = 0;
    while (self.download_result_queue.getOneUncancelable(self.io)) |res| {
        self.saveHashes() catch {};
        count += 1;
        progress.setCompletedItems(count);
        if (res.err) |e| {
            if (res.name) |nm| {
                std.log.err("Error downloading asset \"{s}\": {t}", .{ nm, e });
            } else {
                std.log.err("Error downloading asset, couldn't start thread: {t}", .{e});
            }
            had_error = true;
        }
        if (count >= idx.objects.count()) break;
    } else |_| {}

    if (had_error) {
        return error.DownloadFailed;
    }
}
