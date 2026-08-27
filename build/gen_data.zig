//! Data generators but inversed (i know, clever)
const std = @import("std");
const utils = @import("utils");
const net = @import("net");

const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;

fn IdentifierList(comptime T: type) type {
    return struct {
        const Self = @This();

        const SliceType = if (@sizeOf(T) == 0) void else [*]T;
        const entries_default = if (SliceType == void) {} else &[_]T{};

        map: std.HashMapUnmanaged(utils.Identifier, u32, utils.Identifier.HashCtx, std.hash_map.default_max_load_percentage) = .empty,
        entries: SliceType = entries_default,
        mask: std.DynamicBitSetUnmanaged = .{},
        capacity: u32 = 0,

        pub const Iterator = struct {
            list: *const Self,
            mask_it: std.DynamicBitSetUnmanaged.Iterator(.{}),

            pub fn next(self: *Iterator) ?struct { utils.Identifier, u32, T } {
                const idx: u32 = @intCast(self.mask_it.next() orelse return null);
                var map_it = self.list.map.iterator();
                while (map_it.next()) |en| {
                    if (en.value_ptr.* != idx) continue;
                    return .{ en.key_ptr.*, idx, if (SliceType == void) {} else self.list.entries[idx] };
                }
                unreachable; // should not happen
            }
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.map.deinit(allocator);
            allocator.free(self.entries);
            self.mask.deinit(allocator);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, capacity: u32) Allocator.Error!void {
            try self.map.ensureTotalCapacity(allocator, capacity);
            if (self.capacity < capacity) {
                try self.mask.resize(allocator, capacity, false);
                if (SliceType != void) {
                    const better_capacity = std.ArrayList(u32).growCapacity(capacity);
                    self.entries = (try allocator.realloc(self.entries[0..self.capacity], better_capacity)).ptr;
                }
                self.capacity = capacity;
            }
        }

        pub fn set(self: *Self, allocator: Allocator, id: utils.Identifier, idn: u32, v: T) !void {
            try self.ensureTotalCapacity(allocator, idn + 1);

            if (self.mask.isSet(idn)) return error.DuplicateField;

            const gop = try self.map.getOrPut(allocator, id);
            if (gop.found_existing) return error.DuplicateField;
            errdefer self.map.removeByPtr(gop.key_ptr);

            gop.value_ptr.* = idn;
            self.mask.set(idn);
            if (SliceType != void) self.entries[idn] = v;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.map.clearRetainingCapacity();
            self.mask.unsetAll();
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .list = self, .mask_it = self.mask.iterator(.{}) };
        }
    };
}

const RegistriesFile = struct {
    entries: IdentifierList(Registry),

    pub const Registry = struct { default: ?u32, entries: IdentifierList(void) };

    pub fn jsonParse(allocator: Allocator, source: *json.Reader, options: json.ParseOptions) !RegistriesFile {
        if ((try source.next()) != .object_begin) return error.UnexpectedToken;

        var self: RegistriesFile = .{ .entries = .{} };
        try self.entries.ensureTotalCapacity(allocator, 128);

        while (true) {
            var tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
            const registry_id = switch (tok) {
                .string, .allocated_string => |s| utils.Identifier.validate(s) catch return error.InvalidCharacter,
                .object_end => break,
                else => return error.UnexpectedToken,
            };
            var entry = Registry{
                .default = null,
                .entries = .{},
            };
            var prot_id: u32 = undefined;
            var default_id: utils.Identifier = undefined;

            const Fields = enum { default, entries, protocol_id };
            var field_mask = std.EnumSet(Fields).empty;
            if ((try source.next()) != .object_begin) return error.UnexpectedToken;
            while (true) {
                tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                var field_name = switch (tok) {
                    .string, .allocated_string => |s| s,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };
                const field_tag = std.meta.stringToEnum(Fields, field_name) orelse {
                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                        continue;
                    }
                    return error.UnknownField;
                };
                if (field_mask.contains(field_tag)) switch (options.duplicate_field_behavior) {
                    .use_first => {
                        try source.skipValue();
                        continue;
                    },
                    .@"error" => return error.DuplicateField,
                    .use_last => {},
                };
                switch (field_tag) {
                    .default => {
                        tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                        const s = switch (tok) {
                            .string, .allocated_string => |s| s,
                            else => return error.UnexpectedToken,
                        };
                        const id = utils.Identifier.validate(s) catch return error.InvalidCharacter;
                        default_id = id;
                    },
                    .entries => {
                        entry.entries.clearRetainingCapacity();
                        if ((try source.next()) != .object_begin) return error.UnexpectedToken;
                        while (true) {
                            tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                            const entry_id = switch (tok) {
                                .string, .allocated_string => |s| utils.Identifier.validate(s) catch return error.InvalidCharacter,
                                .object_end => break,
                                else => return error.UnexpectedToken,
                            };

                            if ((try source.next()) != .object_begin) return error.UnexpectedToken;
                            var prot_id2: ?u32 = null;
                            while (true) {
                                tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                                field_name = switch (tok) {
                                    .string, .allocated_string => |s| s,
                                    .object_end => break,
                                    else => return error.UnexpectedToken,
                                };
                                if (std.mem.eql(u8, field_name, "protocol_id")) blk: {
                                    if (prot_id2 != null) switch (options.duplicate_field_behavior) {
                                        .use_first => break :blk,
                                        .@"error" => return error.DuplicateField,
                                        .use_last => {},
                                    };
                                    tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                                    const s = switch (tok) {
                                        .number, .allocated_number => |s| s,
                                        else => return error.UnexpectedToken,
                                    };
                                    prot_id2 = try std.fmt.parseInt(u31, s, 0);

                                    continue;
                                }
                                if (options.ignore_unknown_fields) {
                                    try source.skipValue();
                                } else return error.UnknownField;
                            }
                            try entry.entries.set(allocator, entry_id, prot_id2 orelse return error.MissingField, {});
                        }
                    },
                    .protocol_id => {
                        tok = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                        const s = switch (tok) {
                            .number, .allocated_number => |s| s,
                            else => return error.UnexpectedToken,
                        };
                        prot_id = try std.fmt.parseInt(u31, s, 0);
                    },
                }
                field_mask.setPresent(field_tag, true);
            }
            if (!field_mask.contains(.protocol_id)) return error.MissingField;
            if (field_mask.contains(.default)) {
                entry.default = entry.entries.map.get(default_id) orelse return error.MissingField;
            }
            try self.entries.set(allocator, registry_id, prot_id, entry);
        }

        return self;
    }
};

const PacketsFile = struct {
    ids: std.EnumArray(net.NetworkingSide, std.EnumArray(net.NetworkingPhase, IdentifierList(void))),
    
};

const GeneratedData = struct {
    reports: Reports,

    pub const Reports = struct {
        packets: PacketsFile,
        registries: RegistriesFile,
    };
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var args_it = try init.minimal.args.iterateAllocator(arena);
    defer args_it.deinit();
    _ = args_it.skip();

    const dirpath = args_it.next() orelse return error.BadArgument;
    const out_filepath = args_it.next() orelse return error.BadArgument;

    const dir = try Io.Dir.cwd().openDir(init.io, dirpath, .{});
    defer dir.close(init.io);

    var buf: [256]u8 = undefined;

    const reg_file = blk: {
        const registries_file = try dir.openFile(init.io, "reports/registries.json", .{ .lock = .shared });
        defer registries_file.close(init.io);

        var fr = registries_file.reader(init.io, &buf);

        var json_r = json.Reader.init(init.gpa, &fr.interface);
        defer json_r.deinit();

        break :blk try json.parseFromTokenSourceLeaky(
            RegistriesFile,
            init.arena.allocator(),
            &json_r,
            .{},
        );
    };

    var out_file = try Io.Dir.cwd().createFile(init.io, out_filepath, .{ .lock = .exclusive });
    defer out_file.close(init.io);

    var fw = out_file.writer(init.io, &buf);
    try fw.flush();

    printRegFile(&reg_file, init.gpa, &fw.interface) catch |e| return switch (e) {
        error.WriteFailed => fw.err.?,
        else => |err| err,
    };
    try fw.flush();
}

fn printRegFile(reg_file: *const RegistriesFile, gpa: Allocator, out: *Io.Writer) !void {
    try out.writeAll("pub const RegistryType=enum(u32){");
    var regs_it = reg_file.entries.iterator();
    while (regs_it.next()) |entry| {
        const id, const idn, _ = entry;

        try out.writeAll("@\"");
        if (std.mem.eql(u8, id.namespace(), "minecraft")) {
            try out.writeAll(id.path());
        } else {
            try out.print("{s}:{s}", .{ id.namespace(), id.path() });
        }
        try out.writeAll("\"=");
        try out.printInt(idn, 10, .lower, .{});
        try out.writeAll(",");
    }

    try out.writeAll("};\n");

    regs_it = reg_file.entries.iterator();
    while (regs_it.next()) |entry| {
        const id, _, const reg = entry;

        const pascal_name = try pascalize(id.path(), gpa);
        defer gpa.free(pascal_name);

        try out.print("pub const @\"{s}Registry\"=enum(u32){{", .{pascal_name});

        var reg_it = reg.entries.iterator();
        while (reg_it.next()) |entry2| {
            const rid, const idn, _ = entry2;

            try out.writeAll("@\"");
            if (std.mem.eql(u8, rid.namespace(), "minecraft")) {
                try out.writeAll(rid.path());
            } else {
                try out.print("{s}:{s}", .{ rid.namespace(), rid.path() });
            }
            try out.writeAll("\"=");
            try out.printInt(idn, 10, .lower, .{});
            try out.writeAll(",");
        }
        if (reg.default) |default| {
            try out.print("pub const default:@\"{s}Registry\"=@intFromEnum({d});", .{ pascal_name, default });
        }
        try out.writeAll("};\n");
    }
}

fn pascalize(str: []const u8, alloc: Allocator) Allocator.Error![]u8 {
    const res = try alloc.alloc(u8, str.len);
    errdefer alloc.free(res);

    var w = Io.Writer.fixed(res);
    var next_upper: bool = true;
    for (str) |c| {
        blk: {
            w.writeByte(switch (c) {
                '0'...'9', 'a'...'z', 'A'...'Z' => if (next_upper) c & (~@as(u8, 32)) else c,
                else => break :blk,
            }) catch unreachable;
        }
        next_upper = switch (c) {
            'a'...'z', 'A'...'Z' => false,
            else => true,
        };
    }

    return alloc.realloc(res, w.end);
}
