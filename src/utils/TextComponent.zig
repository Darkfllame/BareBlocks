const TextComponent = @This();
const std = @import("std");
const translation = @import("translation");
const Color = @import("color.zig").Color;
const Keybind = @import("keybinds.zig").Keybind;
const Selector = @import("Selector.zig");
const Identifier = @import("Identifier.zig");
const NBT = @import("NBT.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = std.Io.Writer;
const json = std.json;
const assert = std.debug.assert;
const eql = std.mem.eql;

const ClickEvent = union(enum) {
    none,
    open_url: []const u8,
    /// Opens the specified file on the user's computer.
    /// This is used in messages automatically generated
    /// by the game (e.g., on taking a screenshot) and
    /// cannot be sent by servers for security reasons.
    open_file: []const u8,
    run_command: []const u8,
    suggest_command: []const u8,
    /// Can only be used in written books. Changes
    /// to the specified page if that page exists.
    change_page: u31,
    copy_to_clipboard: []const u8,
    show_dialog: struct {},
    custom: struct {
        id: Identifier,
        payload: []const u8,
    },
};
const HoverEvent = union(enum) {
    none,
    show_text: *const TextComponent,
    show_item: struct {},
    show_entity: struct {},
};

const Formatting = struct {
    const MaskPacked = blk: {
        const info = @typeInfo(Formatting).@"struct";
        var types = [_]type{bool} ** info.fields.len;
        var names: [info.fields.len][]const u8 = undefined;
        for (info.fields, &names) |f, *out| {
            out.* = f.name;
        }

        break :blk @Struct(
            .@"packed",
            @Int(.unsigned, info.fields.len),
            &names,
            &types,
            &([_]std.builtin.Type.StructField.Attributes{
                .{ .default_value_ptr = &@as(bool, false) },
            } ** info.fields.len),
        );
    };
    const Mask = struct {
        sub: MaskPacked = .{},

        pub fn new(sub: MaskPacked) Mask {
            return .{ .sub = sub };
        }

        pub fn get(self: Mask, fmt: Formatting, comptime field: std.meta.FieldEnum(Formatting)) ?@FieldType(Formatting, @tagName(field)) {
            return if (@field(self.sub, @tagName(field)))
                @field(fmt, @tagName(field))
            else
                null;
        }

        pub fn set(self: *Mask, fmt: *Formatting, comptime field: std.meta.FieldEnum(Formatting), v: ?@FieldType(Formatting, @tagName(field))) void {
            @field(self.sub, @tagName(field)) = v != null;
            @field(fmt, @tagName(field)) = v orelse undefined;
        }

        pub fn has(self: Mask, comptime field: std.meta.FieldEnum(Formatting)) bool {
            return @field(self.dub, @tagName(field));
        }
    };

    color: Color = undefined,
    font: Identifier = undefined,
    bold: bool = undefined,
    italic: bool = undefined,
    underlined: bool = undefined,
    strikethrough: bool = undefined,
    obfuscated: bool = undefined,
    shadow_color: Color.ARGB = undefined,
};

const FormatContext = struct {
    self: *const TextComponent,
    old_style: ?[]const u8 = null,

    pub fn format(fc: FormatContext, writer: *Writer) Writer.Error!void {
        const self = fc.self;

        var style_buffer: [64]u8 = undefined;
        const style_string = blk: { // Color and styling
            var fba = Writer.fixed(&style_buffer);
            fba.writeAll("\x1b[") catch unreachable;

            var is_first = true;
            if (self.formatting_mask.get(self.formatting, .color)) |color| {
                const hex: u24 = @intFromEnum(color);
                fba.print("38;2;{d};{d};{d}", .{
                    (hex >> 16) & 0xFF,
                    (hex >> 8) & 0xFF,
                    hex & 0xFF,
                }) catch unreachable;
                is_first = false;
            }
            if (self.formatting_mask.get(self.formatting, .bold)) |enabled| {
                if (!is_first) {
                    fba.writeByte(';') catch unreachable;
                } else is_first = false;
                fba.writeAll(if (enabled) "1" else "22") catch unreachable;
            }
            if (self.formatting_mask.get(self.formatting, .italic)) |enabled| {
                if (!is_first) {
                    fba.writeByte(';') catch unreachable;
                } else is_first = false;
                fba.writeAll(if (enabled) "3" else "23") catch unreachable;
            }
            if (self.formatting_mask.get(self.formatting, .underlined)) |enabled| {
                if (!is_first) {
                    fba.writeByte(';') catch unreachable;
                } else is_first = false;
                fba.writeAll(if (enabled) "4" else "24") catch unreachable;
            }
            if (self.formatting_mask.get(self.formatting, .strikethrough)) |enabled| {
                if (!is_first) {
                    fba.writeByte(';') catch unreachable;
                } else is_first = false;
                fba.writeAll(if (enabled) "9" else "29") catch unreachable;
            }
            if (!is_first) {
                fba.writeByte('m') catch unreachable;
                break :blk fba.buffered();
            }
            break :blk "";
        };
        try writer.writeAll(style_string);

        const old_style = if (style_string.len > 0) style_string else (fc.old_style orelse "\x1b[0m");

        switch (self.content) {
            .text => |s| try writer.writeAll(s),
            .int => |i| try writer.printIntAny(i, 10, .lower, .{}),
            .float => |f| try writer.printFloat(f, .{}),
            .translatable => |t| prg: {
                const components = translation.get(t.id);
                if (components.len == 0) {
                    try writer.writeAll(t.fallback);
                    break :prg;
                }

                for (components) |comp| {
                    switch (comp) {
                        .text => |s| try writer.writeAll(s),
                        .argument => |idx| {
                            if (idx >= t.with.len) {
                                try writer.writeAll("<unspecified>");
                            } else {
                                try FormatContext.format(.{
                                    .self = &t.with[idx],
                                    .old_style = old_style,
                                }, writer);
                            }
                        },
                    }
                }
            },
            .keybind => |kb| try if (kb.key == .unknown)
                writer.writeAll(kb.translation)
            else
                writer.writeAll(translation.getKeybind(kb.key)),
            .score,
            .selector,
            => @panic("Not Yet Implemented²"),
            .nbt => |nbt| try nbt.format(writer),
        }

        for (self.children) |*tc| {
            try FormatContext.format(.{
                .self = tc,
                .old_style = old_style,
            }, writer);
        }
        try writer.writeAll("\x1b[0m");
        if (fc.old_style) |os| try writer.writeAll(os);
    }
};

const Content = union(enum) {
    text: []const u8,
    // 128 bits will represent most integer commonly used
    // and fits within the minimum size of this struct.
    /// This will never be returned by the client, and will be
    /// formatted to a simple 'text' component when serialized.
    int: i128,
    // 128 bits will represent most floats commonly used
    // and fits within the minimum size of this struct.
    /// This will never be returned by the client, and will be
    /// formatted to a simple 'text' component when serialized.
    float: f128,
    translatable: struct {
        id: []const u8,
        fallback: []const u8 = "",
        with: []const TextComponent = &.{},
    },
    score: struct {
        name: union(enum) {
            reader,
            selector: Selector,
        } = .reader,
        objective: []const u8,
    },
    selector: struct {
        value: Selector,
        separator: *const TextComponent,
    },
    keybind: struct {
        key: Keybind,
        /// This is only filled if .keybind == .unknown
        translation: []const u8 = "",
    },
    nbt: struct {
        source: union(enum) {
            block: packed struct(u64) { x: u26, z: u26, y: u12 },
            entity: Selector,
            storage: Identifier,
        },
        path: []const u8,
        interpret: bool = false,
        separator: *const TextComponent = &empty,
    },
};

fn arena(self: TextComponent, gpa: Allocator) ArenaAllocator {
    return self.arena_state.promote(gpa);
}

fn fromContent(content: Content, options: CreateCommonOptions) TextComponent {
    return .{
        .arena_state = options.arena_state,
        .content = content,
        .children = options.children,
        .formatting_mask = .new(.{
            .color = options.color != null,
            .font = options.font != null,
            .bold = options.bold != null,
            .italic = options.italic != null,
            .underlined = options.underlined != null,
            .strikethrough = options.strikethrough != null,
            .obfuscated = options.obfuscated != null,
            .shadow_color = options.shadow_color != null,
        }),
        .formatting = .{
            .color = options.color orelse undefined,
            .font = options.font orelse undefined,
            .bold = options.bold orelse undefined,
            .italic = options.italic orelse undefined,
            .underlined = options.underlined orelse undefined,
            .strikethrough = options.strikethrough orelse undefined,
            .obfuscated = options.obfuscated orelse undefined,
            .shadow_color = options.shadow_color orelse undefined,
        },
        .insertion = options.insertion,
        .click_event = options.click_event,
        .hover_event = options.hover_event,
    };
}

fn nbtWriteContent(self: TextComponent, writer: *Writer) NBT.WriteError!void {
    switch (self.content) {
        .text => |_text| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "text");
            try NBT.writeJavaString(writer, _text);
        },
        inline .int, .float => |num| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "text");
            const len = std.fmt.count("{d}", .{num});
            if (len > std.math.maxInt(u15)) return error.InvalidLength;
            try writer.writeInt(i16, @intCast(len), .big);
            try writer.print("{d}", .{num});
        },
        .translatable => |trans| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "translate");
            try NBT.writeJavaString(writer, trans.id);
            if (trans.fallback.len != 0) {
                try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
                try NBT.writeJavaString(writer, "fallback");
                try NBT.writeJavaString(writer, trans.fallback);
            }
            if (trans.with.len != 0) {
                if (trans.with.len > std.math.maxInt(u31)) return error.InvalidLength;
                try writer.writeByte(@intFromEnum(NBT.ValueTag.list));
                try NBT.writeJavaString(writer, "with");
                try writer.writeByte(@intFromEnum(NBT.ValueTag.compound));
                try writer.writeInt(i32, @intCast(trans.with.len), .big);
                for (trans.with) |tc| {
                    try tc.nbtWriteContent(writer);
                }
            }
        },
        .score => |score| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.compound));
            try NBT.writeJavaString(writer, "score");
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "name");
            switch (score.name) {
                .reader => try writer.writeAll("\x00\x01*"),
                .selector => |sel| {
                    const count = std.fmt.count("{f}", .{sel});
                    if (count > std.math.maxInt(u15)) return error.InvalidLength;
                    try writer.print("{f}", .{sel});
                },
            }
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "objective");
            try NBT.writeJavaString(writer, score.objective);
            try writer.writeByte(@intFromEnum(NBT.ValueTag.void));
        },
        .selector => |selector| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "selector");
            const count = std.fmt.count("{f}", .{selector.value});
            if (count > std.math.maxInt(u15)) return error.InvalidLength;
            try writer.writeInt(i16, @intCast(count), .big);
            try writer.print("{f}", .{selector.value});
            try selector.separator.nbtWriteInner(writer, "separator", true);
        },
        .keybind => |kb| {
            try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
            try NBT.writeJavaString(writer, "keybind");
            if (kb.key != .unknown) {
                const max_kb_len = comptime blk: {
                    var max: usize = 0;
                    for (@typeInfo(Keybind).@"enum".fields) |f| {
                        max = @max(max, f.name.len);
                    }
                    break :blk max;
                };

                var buf: [4 + max_kb_len]u8 = undefined;
                var buf_writer = Writer.fixed(&buf);
                buf_writer.print("key.{t}", .{kb.key}) catch unreachable;
                try NBT.writeJavaString(writer, buf_writer.buffered());
            } else {
                try NBT.writeJavaString(writer, kb.translation);
            }
        },
        .nbt => @panic("TODO: Implement"),
    }

    inline for (@typeInfo(Formatting).@"struct".fields) |f| {
        if (@field(self.formatting_mask.sub, f.name)) {
            const value = @field(self.formatting, f.name);
            switch (f.type) {
                Color => {
                    try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
                    try NBT.writeJavaString(writer, f.name);
                    switch (value) {
                        else => |tag| {
                            try NBT.writeJavaString(writer, @tagName(tag));
                        },
                        _ => |tag| {
                            try writer.writeInt(i16, 7, .big);
                            try writer.print("\"#{x:0>6}\"", .{@intFromEnum(tag)});
                        },
                    }
                },
                Color.ARGB => {
                    try writer.writeByte(@intFromEnum(NBT.ValueTag.int));
                    try NBT.writeJavaString(writer, f.name);
                    try writer.writeInt(u32, @byteSwap(@as(u32, @bitCast(value))), .big);
                },
                Identifier => {
                    try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
                    try NBT.writeJavaString(writer, f.name);
                    try NBT.writeJavaString(writer, value.id);
                },
                bool => {
                    try writer.writeByte(@intFromEnum(NBT.ValueTag.byte));
                    try NBT.writeJavaString(writer, f.name);
                    try writer.writeByte(@intFromBool(value));
                },
                else => unreachable,
            }
        }
    }

    if (self.children.len != 0) {
        if (self.children.len > std.math.maxInt(u31)) return error.InvalidLength;
        try writer.writeByte(@intFromEnum(NBT.ValueTag.list));
        try NBT.writeJavaString(writer, "extra");
        try writer.writeByte(@intFromEnum(NBT.ValueTag.compound));
        try writer.writeInt(i32, @intCast(self.children.len), .big);
        for (self.children) |tc| {
            try tc.nbtWriteContent(writer);
        }
    }

    try writer.writeByte(@intFromEnum(NBT.ValueTag.void));
}

fn nbtWriteInner(self: TextComponent, writer: *Writer, name: ?[]const u8, force_compound: bool) NBT.WriteError!void {
    if (self.isSimpleText() and !force_compound) {
        try writer.writeByte(@intFromEnum(NBT.ValueTag.string));
        return switch (self.content) {
            .text => |_text| NBT.writeJavaString(writer, _text),
            inline .int, .float => |num| {
                const len = std.fmt.count("{d}", .{num});
                if (len > std.math.maxInt(u15)) return error.InvalidLength;
                try writer.writeInt(i16, @intCast(len), .big);
                try writer.print("{d}", .{num});
            },
            else => unreachable,
        };
    }

    try writer.writeByte(@intFromEnum(NBT.ValueTag.compound));
    if (name) |nm| {
        try NBT.writeJavaString(writer, nm);
    }

    try nbtWriteContent(self, writer);
}

// This is actually really useful for comptime computing :D
arena_state: ArenaAllocator.State = .{},
content: Content,
children: []const TextComponent = &.{},
formatting_mask: Formatting.Mask = .{},
formatting: Formatting = undefined,

/// `.len == 0` means it won't be serialized.
insertion: []const u8 = "",
click_event: ClickEvent = .none,
hover_event: HoverEvent = .none,

pub const empty = text("", .{});
pub const disconnect_generic = translate("multiplayer.disconnect.generic", null, &.{}, .{});
pub const server_shutdown = translate("multiplayer.disconnect.server_shutdown", null, &.{}, .{});
pub const transfers_disabled = translate("multiplayer.disconnect.transfers_disabled", null, &.{}, .{});
pub const duplicate_login = translate("multiplayer.disconnect.duplicate_login", null, &.{}, .{});
pub const server_full = translate("multiplayer.disconnect.server_full", null, &.{}, .{});
pub const not_whitelisted = translate("multiplayer.disconnect.not_whitelisted", null, &.{}, .{});
pub const banned = translate("multiplayer.disconnect.banned", null, &.{}, .{});
pub const banned_ip_exp = translate("multiplayer.disconnect.banned_ip.expiration", null, &.{}, .{});
pub const banned_ip_reason = translate("multiplayer.disconnect.banned_ip.reason", null, &.{}, .{});
pub const banned_exp = translate("multiplayer.disconnect.banned.expiration", null, &.{}, .{});
pub const banned_reason = translate("multiplayer.disconnect.banned.reason", null, &.{}, .{});
pub const banned_reason_default = translate("multiplayer.disconnect.banned.reason.default", null, &.{}, .{});

pub const CreateCommonOptions = struct {
    arena_state: ArenaAllocator.State = .{},
    children: []const TextComponent = &.{},

    color: ?Color = null,
    font: ?Identifier = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underlined: ?bool = null,
    strikethrough: ?bool = null,
    obfuscated: ?bool = null,
    shadow_color: ?Color.ARGB = null,

    insertion: []const u8 = "",
    click_event: ClickEvent = .none,
    hover_event: HoverEvent = .none,
};
pub const FormattingOptions = struct {
    color: ?Color = null,
    font: ?Identifier = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underlined: ?bool = null,
    strikethrough: ?bool = null,
    obfuscated: ?bool = null,
    shadow_color: ?Color.ARGB = null,
};

pub inline fn text(content: []const u8, options: CreateCommonOptions) TextComponent {
    return fromContent(.{ .text = content }, options);
}

pub inline fn number(n: anytype, options: CreateCommonOptions) TextComponent {
    const content: Content = switch (@typeInfo(@TypeOf(n))) {
        .int, .comptime_int => .{ .int = @intCast(n) },
        .float, .comptime_float => .{ .float = n },
        else => |tag| @compileError("Unsupported type: '" ++ @tagName(tag) ++ "'"),
    };

    return fromContent(content, options);
}

pub fn textFmt(allocator: Allocator, comptime fmt: []const u8, args: anytype, options: CreateCommonOptions) Allocator.Error!TextComponent {
    return text(try std.fmt.allocPrint(allocator, fmt, args), options);
}

pub inline fn translate(id: []const u8, fallback: ?[]const u8, args: []const TextComponent, options: CreateCommonOptions) TextComponent {
    return fromContent(.{ .translatable = .{
        .id = id,
        .fallback = fallback orelse "",
        .with = args,
    } }, options);
}

pub inline fn keybind(bind: Keybind, options: CreateCommonOptions) TextComponent {
    return fromContent(.{ .keybind = bind }, options);
}

pub fn deinit(self: TextComponent, gpa: Allocator) void {
    self.arena(gpa).deinit();
}

/// Will create a new ArenaAllocator and clone `self` with it along by storing
/// its final state inside `.arena_state`.
pub fn clone(self: TextComponent, gpa: Allocator) Allocator.Error!TextComponent {
    var aa = ArenaAllocator.init(gpa);
    errdefer aa.deinit();
    const _arena = aa.allocator();

    var tc = try cloneLeaky(self, _arena);
    tc.arena_state = aa.state;
    return tc;
}

/// Clone `self` without registering an `.arena_state`. Shouldn't be called except by
/// itself or `.clone()`, unless you know what you're doing.
pub fn cloneLeaky(self: TextComponent, allocator: Allocator) Allocator.Error!TextComponent {
    const content: Content = switch (self.content) {
        .text => |str| .{ .text = try allocator.dupe(u8, str) },
        inline .int, .float => |v, tag| @unionInit(Content, @tagName(tag), v),
        .translatable => |tr| .{ .translatable = .{
            .id = try allocator.dupe(u8, tr.id),
            .fallback = try allocator.dupe(u8, tr.fallback),
            .with = tcs: {
                const cpy = try allocator.alloc(TextComponent, tr.with.len);
                for (cpy, tr.with) |*out, in| {
                    out.* = try in.cloneLeaky(allocator);
                }
                break :tcs cpy;
            },
        } },
        .score => |sc| .{ .score = .{
            .name = switch (sc.name) {
                .reader => .reader,
                .selector => |sel| .{ .selector = try sel.dupeLeaky(allocator) },
            },
            .objective = try allocator.dupe(u8, sc.objective),
        } },
        .selector => |sel| .{ .selector = .{
            .value = try sel.value.dupeLeaky(allocator),
            .separator = sep: {
                const tc = try allocator.create(TextComponent);
                tc.* = try sel.separator.cloneLeaky(allocator);
                break :sep tc;
            },
        } },
        .keybind => |kb| .{ .keybind = .{
            .kb = kb.key,
            .translation = try allocator.dupe(u8, kb),
        } },
        .nbt => unreachable,
    };
    const children = try allocator.alloc(TextComponent, self.children.len);
    for (children, self.children) |*out, in| {
        out.* = try in.cloneLeaky(allocator);
    }

    var tc: TextComponent = .{
        .content = content,
        .children = children,
    };
    tc.formatting_mask = self.formatting_mask;
    tc.formatting = self.formatting;
    if (self.formatting_mask.get(&self.formatting, .font)) |font| {
        tc.formatting.font = try font.dupe(allocator);
    }
    tc.insertion = try allocator.dupe(u8, self.insertion);
    tc.click_event = switch (self.click_event) {
        inline .none, .change_page => |val, tag| @unionInit(
            ClickEvent,
            @tagName(tag),
            val,
        ),
        inline .open_url,
        .open_file,
        .run_command,
        .suggest_command,
        .copy_to_clipboard,
        => |str, tag| @unionInit(
            ClickEvent,
            @tagName(tag),
            try allocator.dupe(u8, str),
        ),
        .show_dialog => @panic("Not Yet Implemented"),
        .custom => |custom| .{ .custom = .{
            .id = try custom.id.dupe(allocator),
            .payload = try allocator.dupe(u8, custom.payload),
        } },
    };
    tc.hover_event = switch (tc.hover_event) {
        .none => .none,
        .show_text => |sht| txt: {
            const tc2 = try allocator.create(Allocator);
            tc2.* = try sht.cloneLeaky(allocator);
            break :txt tc2;
        },
        .show_item => @panic("Not Yet Implemented"),
        .show_entity => @panic("Not Yet Implemented"),
    };

    return tc;
}

pub fn applyFormatting(self: TextComponent, options: FormattingOptions) TextComponent {
    var res: TextComponent = self;
    res.formatting_mask.set(&res.formatting, .color, options.color);
    res.formatting_mask.set(&res.formatting, .font, options.font);
    res.formatting_mask.set(&res.formatting, .bold, options.bold);
    res.formatting_mask.set(&res.formatting, .italic, options.italic);
    res.formatting_mask.set(&res.formatting, .underlined, options.underlined);
    res.formatting_mask.set(&res.formatting, .strikethrough, options.strikethrough);
    res.formatting_mask.set(&res.formatting, .obfuscated, options.obfuscated);
    res.formatting_mask.set(&res.formatting, .shadow_color, options.shadow_color);
    return res;
}

pub fn isSimpleText(self: TextComponent) bool {
    return (self.content == .text or self.content == .int or self.content == .float) and self.children.len == 0 and
        self.formatting_mask.sub == Formatting.MaskPacked{} and self.insertion.len == 0 and
        self.click_event == .none and self.hover_event == .none;
}

pub fn format(self: TextComponent, writer: *Writer) Writer.Error!void {
    try FormatContext.format(.{ .self = &self }, writer);
}

pub fn jsonStringify(self: TextComponent, jw: *json.Stringify) json.Stringify.Error!void {
    if (self.isSimpleText()) {
        return switch (self.content) {
            .text => |_text| jw.write(_text),
            inline .int, .float => |num| jw.print("\"{d}\"", .{num}),
            else => unreachable,
        };
    }
    if (self.children.len > 0) {
        try jw.beginArray();
    }

    try jw.beginObject();

    switch (self.content) {
        .text => |_text| {
            try jw.objectField("text");
            try jw.write(_text);
        },
        inline .int, .float => |num| {
            try jw.objectField("text");
            try jw.print("\"{d}\"", .{num});
        },
        .translatable => |tr| {
            try jw.objectField("translate");
            try jw.write(tr.id);
            if (tr.fallback.len > 0) {
                try jw.objectField("fallback");
                try jw.write(tr.fallback);
            }
            if (tr.with.len > 0) {
                try jw.objectField("with");
                try jw.write(tr.with);
            }
        },
        .score => |score| {
            try jw.objectField("score");
            try jw.beginObject();
            try jw.objectField("name");
            switch (score.name) {
                .reader => try jw.write("*"),
                .selector => |sel| {
                    try jw.beginWriteRaw();
                    defer jw.endWriteRaw();
                    var modified = sel;
                    modified.limit = 1;

                    try jw.writer.print("\"{f}\"", .{modified});
                },
            }
            try jw.objectField("objective");
            try jw.write(score.objective);
            try jw.endObject();
        },
        .selector => |sel| {
            try jw.objectField("selector");
            {
                try jw.beginWriteRaw();
                defer jw.endWriteRaw();
                try jw.writer.print("\"{f}\"", .{sel.value});
            }
            try jw.objectField("separator");
            try jw.write(sel.separator);
        },
        .keybind => |kb| {
            try jw.objectField("keybind");
            if (kb.key == .unknown) {
                try jw.write(kb.translation);
            } else {
                try jw.beginWriteRaw();
                defer jw.endWriteRaw();
                try jw.writer.print("\"key.{t}\"", .{kb.key});
            }
        },
        .nbt => @panic("Not Yet Implemented"),
    }

    inline for (@typeInfo(Formatting).@"struct".fields) |f| {
        if (@field(self.formatting_mask.sub, f.name)) {
            const value = @field(self.formatting, f.name);
            try jw.objectField(f.name);
            switch (f.type) {
                Color => switch (value) {
                    else => |tag| try jw.write(@tagName(tag)),
                    _ => |tag| {
                        try jw.beginWriteRaw();
                        defer jw.endWriteRaw();

                        try jw.writer.print("\"#{x:0>6}\"", .{@intFromEnum(tag)});
                    },
                },
                Color.ARGB => try jw.write(@as(i64, @as(u32, @bitCast(value)))),
                else => try jw.write(value),
            }
        }
    }

    try jw.endObject();

    if (self.children.len > 0) {
        for (self.children) |tc| try tc.jsonStringify(jw);
        try jw.endArray();
    }
}

pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !TextComponent {
    var modified_options = options;
    modified_options.duplicate_field_behavior = .use_first;
    const value = try json.innerParse(json.Value, allocator, source, modified_options);
    return jsonParseFromValue(allocator, value, options);
}

pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !TextComponent {
    switch (source) {
        .string => |_text| return text(_text, .{}),
        .object => |obj| {
            var out = TextComponent.empty;
            if (obj.get("text")) |txt| {
                if (txt != .string) return error.UnexpectedToken;
                out.content = .{ .text = txt.string };
            } else if (obj.get("translate")) |_translate| {
                if (_translate != .string) return error.UnexpectedToken;
                const fallback = obj.get("fallback");
                const may_with = obj.get("with");
                if (fallback != null and fallback.? != .string) return error.UnexpectedToken;
                const fb_str = if (fallback) |fb| fb.string else null;
                var with_array = std.ArrayList(TextComponent).empty;
                if (may_with) |with| {
                    if (with != .array) return error.UnexpectedToken;
                    try with_array.ensureTotalCapacity(allocator, with.array.items.len);
                    for (with.array.items) |value| {
                        with_array.appendAssumeCapacity(try jsonParseFromValue(allocator, value, options));
                    }
                }
                out.content = .{ .translatable = .{
                    .id = _translate.string,
                    .fallback = fb_str orelse "",
                    .with = with_array.items,
                } };
            } else if (obj.get("score")) |score_v| {
                if (score_v != .object) return error.UnexpectedToken;
                const sc = score_v.object;
                const name = sc.get("name") orelse return error.MissingField;
                if (name != .string) return error.UnexpectedToken;
                const objective = sc.get("objective") orelse return error.MissingField;
                if (objective != .string) return error.UnexpectedToken;
                out.content = .{ .score = .{
                    .name = if (eql(u8, name.string, "*"))
                        .reader
                    else
                        @panic("Selector parsing not yet implemented"),
                    .objective = objective.string,
                } };
            } else if (obj.get("keybind")) |kb| {
                if (kb != .string) return error.UnexpectedToken;
                const key = if (kb.string.len > 4)
                    std.meta.stringToEnum(Keybind, kb.string[4..]) orelse .unknown
                else
                    .unknown;
                out.content = .{ .keybind = .{
                    .key = key,
                    .translation = if (key == .unknown) kb.string else "",
                } };
            } else if (obj.get("nbt")) |_| {
                return error.UnknownField; // TODO: Implement
            }

            var extra_array = std.ArrayList(TextComponent).empty;
            if (obj.get("extra")) |extra| {
                if (extra != .array) return error.UnexpectedToken;
                try extra_array.ensureTotalCapacity(allocator, extra.array.items.len);
                for (extra.array.items) |value| {
                    extra_array.appendAssumeCapacity(try jsonParseFromValue(allocator, value, options));
                }
            }
            out.children = extra_array.items;

            if (obj.get("color")) |color| color: {
                if (color != .string) break :color;
                const cstr = color.string;
                if (cstr.len > 0 and cstr[0] == '#') {
                    const hex = cstr[1..];
                    if (hex.len != 6) break :color;
                    const int = try std.fmt.parseInt(u24, hex, 16);
                    out.formatting_mask.set(&out.formatting, .color, Color.hex(int));
                    break :color;
                }
                out.formatting_mask.set(&out.formatting, .color, std.meta.stringToEnum(Color, cstr));
            }
            if (obj.get("font")) |font| font: {
                if (font != .string) break :font;
                out.formatting_mask.set(&out.formatting, .font, Identifier.validate(font.string) catch null);
            }
            if (obj.get("bold")) |bold| bold: {
                if (bold != .bool) break :bold;
                out.formatting_mask.set(&out.formatting, .bold, bold.bool);
            }
            if (obj.get("italic")) |italic| italic: {
                if (italic != .bool) break :italic;
                out.formatting_mask.set(&out.formatting, .italic, italic.bool);
            }
            if (obj.get("underlined")) |underlined| underlined: {
                if (underlined != .bool) break :underlined;
                out.formatting_mask.set(&out.formatting, .underlined, underlined.bool);
            }
            if (obj.get("strikethrough")) |strikethrough| strikethrough: {
                if (strikethrough != .bool) break :strikethrough;
                out.formatting_mask.set(&out.formatting, .strikethrough, strikethrough.bool);
            }
            if (obj.get("obfuscated")) |obfuscated| obfuscated: {
                if (obfuscated != .bool) break :obfuscated;
                out.formatting_mask.set(&out.formatting, .obfuscated, obfuscated.bool);
            }
            if (obj.get("shadow_color")) |color| color: switch (color) {
                .integer => |i| out.formatting_mask.set(
                    &out.formatting,
                    .shadow_color,
                    Color.ARGB.hex(@truncate(@as(u64, @bitCast(i)))),
                ),
                .array => |arr| {
                    var values: [4]f64 = undefined;
                    if (arr.items.len != 4) break :color;
                    for (arr.items, 0..) |value, i| {
                        if (value != .float) break :color;
                        if (value.float < 0 or value.float > 1) break :color;
                        values[i] = value.float;
                    }
                    out.formatting_mask.set(&out.formatting, .shadow_color, Color.ARGB.floatsNormalized(
                        f64,
                        values[3],
                        values[0],
                        values[1],
                        values[2],
                    ));
                },
                else => {},
            };

            if (obj.get("insertion")) |insertion| insertion: {
                if (insertion != .string) break :insertion;
                out.insertion = insertion.string;
            }
            if (obj.get("click_event")) |click_event| click_event: {
                _ = click_event;
                break :click_event;
            }
            if (obj.get("hover_event")) |hover_event| hover_event: {
                _ = hover_event;
                break :hover_event;
            }

            return out;
        },
        .array => |arr| {
            if (arr.items.len == 0) return TextComponent.empty;
            var root = try jsonParseFromValue(allocator, arr.items[0], options);
            var children = try std.ArrayList(TextComponent)
                .initCapacity(allocator, arr.items.len - 1);
            for (arr.items[1..]) |value| {
                children.appendAssumeCapacity(try jsonParseFromValue(allocator, value, options));
            }
            root.children = children.items;
            return root;
        },
        else => return error.UnexpectedToken,
    }
}

pub fn nbtWrite(self: TextComponent, writer: *Writer) NBT.WriteError!void {
    return nbtWriteInner(self, writer, null, false);
}

pub fn nbtWriteNamed(self: TextComponent, writer: *Writer, name: []const u8) NBT.WriteError!void {
    return nbtWriteInner(self, writer, name, false);
}
