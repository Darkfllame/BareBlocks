const TextComponent = @This();
const std = @import("std");
const Color = @import("color.zig").Color;
const Keybind = @import("keybinds.zig").Keybind;
const Selector = @import("Selector.zig");
const Identifier = @import("Identifier.zig");
const NBT = @import("NBT.zig");
const utils = @import("utils.zig");

const translation = utils.translation;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const json = std.json;
const serial = utils.serial;
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
        payload: ?[]const u8 = null,
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
        var types: [info.fields.len]type = undefined;
        @memset(&types, bool);
        var names: [info.fields.len][]const u8 = undefined;
        var attribs: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;
        @memset(&attribs, .{ .default_value_ptr = &@as(bool, false) });
        for (info.fields, &names) |f, *out| {
            out.* = f.name;
        }

        break :blk @Struct(
            .@"packed",
            @Int(.unsigned, info.fields.len),
            &names,
            &types,
            &attribs,
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
                    try writer.writeAll(t.fallback orelse t.id);
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
            .nbt,
            => try writer.print("(TODO: Implement TextComponent::format<content.{t}>)", .{self.content}),
            // TODO: TextComponent::format<content.(score, selector, nbt)>
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
    // and fits within the size of this union.
    /// This will never be returned by the client, and will be
    /// formatted to a simple 'text' component when serialized.
    int: i128,
    // 128 bits will represent most floats commonly used
    // and fits within the size of this union.
    /// This will never be returned by the client, and will be
    /// formatted to a simple 'text' component when serialized.
    float: f128,
    translatable: struct {
        id: []const u8,
        fallback: ?[]const u8 = null,
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
        separator: ?*const TextComponent = null,
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

fn gatherScoreValue(_arena: Allocator, mapr: *serial.MapReader, out: anytype) serial.MapReader.ReadError!void {
    _ = _arena;

    try mapr.nextExpect(.aggregate_start);

    var name_f: ?[]const u8 = null;
    var objective_f: ?[]const u8 = null;

    while (true) {
        const token = try mapr.next();
        switch (token) {
            .string => |s| {
                if (eql(u8, s, "name")) {
                    name_f = try mapr.nextDupeExpectString();
                } else if (eql(u8, s, "objective")) {
                    objective_f = try mapr.nextDupeExpectString();
                } else try mapr.skipValue();
            },
            .aggregate_end => break,
            else => return error.UnexpectedToken,
        }
    }

    if (name_f == null or objective_f == null) return error.MissingField;

    out.* = @FieldType(Content, "score"){
        .name = if (eql(u8, name_f.?, "*"))
            .reader
        else
            @panic("Selector parsing not yet implemented"),
        // .{ .selector = try Selector.parse(name_f.?) },
        .objective = objective_f.?,
    };
}

fn gatherShadowColor(_arena: Allocator, mapr: *serial.MapReader, out: anytype) serial.MapReader.ReadError!void {
    _ = _arena;
    switch (try mapr.next()) {
        .int => |v| out.* = @bitCast(v),
        .long => |v| out.* = @truncate(@as(u64, @bitCast(v))),
        .array_start => |arr| {
            if (arr.length) |l| {
                if (l != 4) return error.LengthMismatch;
            }
            if (arr.type) |t| {
                if (t != .float) return error.UnexpectedToken;
            }
            var values: [4]f32 = @splat(0);
            inline for (&values) |*v| {
                v.* = @floatCast(try mapr.nextAsFloat());
            }
            try mapr.nextExpect(.array_end);
            var res: u32 = 0;
            inline for (values, 0..) |v, i| {
                res |= @as(u32, @as(u8, @intFromFloat(@max(0, @min(v, 1)) * 255))) << ((values.len - i - 1) * 8);
            }
            out.* = res;
        },
        else => return error.UnexpectedToken,
    }
}

// This is actually really useful for comptime computing :D
arena_state: ArenaAllocator.State = .{},
content: Content,
children: []const TextComponent = &.{},
formatting_mask: Formatting.Mask = .{},
formatting: Formatting = undefined,

insertion: ?[]const u8 = null,
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
pub const exceeded_packet_rate = translate("disconnect.exceeded_packet_rate", null, &.{}, .{});

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

    insertion: ?[]const u8 = null,
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
            .fallback = if (tr.fallback) |fb| try allocator.dupe(u8, fb) else null,
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
                .selector => |sel| .{ .selector = try sel.cloneLeaky(allocator) },
            },
            .objective = try allocator.dupe(u8, sc.objective),
        } },
        .selector => |sel| .{ .selector = .{
            .value = try sel.value.cloneLeaky(allocator),
            .separator = if (sel.separator) |sep| sep: {
                const tc = try allocator.create(TextComponent);
                tc.* = try sep.cloneLeaky(allocator);
                break :sep tc;
            } else null,
        } },
        .keybind => |kb| .{ .keybind = .{
            .key = kb.key,
            .translation = try allocator.dupe(u8, kb.translation),
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
    if (self.formatting_mask.get(self.formatting, .font)) |font| {
        tc.formatting.font = try font.dupe(allocator);
    }
    tc.insertion = if (self.insertion) |ins| try allocator.dupe(u8, ins) else null;
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
        .show_dialog => @panic("Not Yet Implemented"), // TODO: TextComponent::cloneLeaky<click_event.show_dialog>
        .custom => |custom| .{ .custom = .{
            .id = try custom.id.dupe(allocator),
            .payload = if (custom.payload) |pl| try allocator.dupe(u8, pl) else null,
        } },
    };
    tc.hover_event = switch (tc.hover_event) {
        .none => .none,
        .show_text => |sht| txt: {
            const tc2 = try allocator.create(TextComponent);
            tc2.* = try sht.cloneLeaky(allocator);
            break :txt .{ .show_text = tc2 };
        },
        .show_item => @panic("Not Yet Implemented"), // TODO: TextComponent::cloneLeaky<hover_event.show_item>
        .show_entity => @panic("Not Yet Implemented"), // TODO: TextComponent::cloneLeaky<hover_event.show_entity>
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
        self.formatting_mask.sub == Formatting.MaskPacked{} and self.insertion == null and
        self.click_event == .none and self.hover_event == .none;
}

pub fn isEmpty(self: TextComponent) bool {
    return self.isSimpleText() and self.content.text.len == 0;
}

pub fn format(self: TextComponent, writer: *Writer) Writer.Error!void {
    try FormatContext.format(.{ .self = &self }, writer);
}

pub fn serialize(self: *const TextComponent, mapw: *serial.MapWriter) serial.MapWriter.WriteError!void {
    if (self.isSimpleText()) {
        return mapw.writeString(self.content.text);
    }
    if (self.children.len > 0) {
        try mapw.beginArray(self.children.len);
    }

    try mapw.beginAggregate();

    var string_buffer: [16]u8 = undefined;
    switch (self.content) {
        .text => |_text| {
            try mapw.fieldName("text");
            try mapw.writeString(_text);
        },
        inline .int, .float => |num| {
            try mapw.fieldName("text");
            const w = try mapw.stringWriter(null, &string_buffer);
            try w.print("{d}", .{num});
            try w.flush();
        },
        .translatable => |tr| {
            try mapw.fieldName("translate");
            try mapw.writeString(tr.id);
            if (tr.fallback) |fb| {
                try mapw.fieldName("fallback");
                try mapw.writeString(fb);
            }
            if (tr.with.len > 0) {
                try mapw.fieldName("with");
                try mapw.beginArray(tr.with.len);
                for (tr.with) |tc| try tc.serialize(mapw);
                try mapw.endArray();
            }
        },
        .score => |score| {
            try mapw.fieldName("score");
            try mapw.beginAggregate();
            try mapw.fieldName("name");
            switch (score.name) {
                .reader => try mapw.writeString("*"),
                .selector => |sel| {
                    const w = try mapw.stringWriter(null, &string_buffer);
                    var modified = sel;
                    modified.limit = 1;

                    try modified.format(w);
                    try w.flush();
                },
            }
            try mapw.fieldName("objective");
            try mapw.writeString(score.objective);
            try mapw.endAggregate();
        },
        .selector => |sel| {
            try mapw.fieldName("selector");
            {
                const w = try mapw.stringWriter(null, &string_buffer);
                try sel.value.format(w);
                try w.flush();
            }
            if (sel.separator) |sep| {
                try mapw.fieldName("separator");
                try sep.serialize(mapw);
            }
        },
        .keybind => |kb| {
            try mapw.fieldName("keybind");
            if (kb.key == .unknown) {
                try mapw.writeString(kb.translation);
            } else {
                const w = try mapw.stringWriter(null, &string_buffer);
                try w.print("key.{t}", .{kb.key});
                try w.flush();
            }
        },
        .nbt => @panic("Not Yet Implemented"), // TODO: TextComponent::serialize<content.nbt>
    }

    inline for (@typeInfo(Formatting).@"struct".fields) |f| {
        if (@field(self.formatting_mask.sub, f.name)) {
            const value = @field(self.formatting, f.name);
            try mapw.fieldName(f.name);
            switch (f.type) {
                Color => switch (value) {
                    else => |tag| try mapw.writeString(@tagName(tag)),
                    _ => |tag| {
                        const w = try mapw.stringWriter(null, &string_buffer);
                        try w.print("#{x:0>6}", .{@intFromEnum(tag)});
                        try w.flush();
                    },
                },
                Color.ARGB => try mapw.writeInt(@bitCast(value)),
                bool => try mapw.writeBoolean(value),
                Identifier => try value.serialize(mapw),
                else => comptime unreachable,
            }
        }
    }

    if (self.insertion) |ins| {
        try mapw.fieldName("insertion");
        try mapw.writeString(ins);
    }

    if (self.click_event != .none) {
        try mapw.fieldName("click_event");
        try mapw.beginAggregate();
        try mapw.fieldName("action");
        try mapw.writeString(@tagName(self.click_event));
        switch (self.click_event) {
            .none => unreachable,
            .open_url => |s| {
                try mapw.fieldName("url");
                try mapw.writeString(s);
            },
            .open_file => |s| {
                try mapw.fieldName("path");
                try mapw.writeString(s);
            },
            .run_command, .suggest_command => |s| {
                try mapw.fieldName("command");
                try mapw.writeString(s);
            },
            .change_page => |p| {
                try mapw.fieldName("page");
                try mapw.writeInt(p);
            },
            .copy_to_clipboard => |v| {
                try mapw.fieldName("value");
                try mapw.writeString(v);
            },
            .show_dialog => {
                @panic("Dialog not yet implemented");
            },
            .custom => |cus| {
                try mapw.fieldName("id");
                try cus.id.serialize(mapw);
                if (cus.payload) |p| {
                    try mapw.fieldName("payload");
                    try mapw.writeString(p);
                }
            },
        }
        try mapw.endAggregate();
    }

    if (self.hover_event != .none) {
        try mapw.fieldName("hover_event");
        try mapw.beginAggregate();
        try mapw.fieldName("action");
        try mapw.writeString(@tagName(self.hover_event));
        switch (self.hover_event) {
            .none => unreachable,
            .show_text => |tc| {
                try mapw.fieldName("value");
                try tc.serialize(mapw);
            },
            .show_item => {
                @panic("Show Item not yet implemented");
            },
            .show_entity => {
                @panic("Show Entity not yet implemented");
            },
        }
        try mapw.endAggregate();
    }

    try mapw.endAggregate();

    if (self.children.len > 0) {
        for (self.children) |tc| try tc.serialize(mapw);
        try mapw.endArray();
    }
}

pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!TextComponent {
    const gpa = mapr.getAlloctor();
    const _arena = mapr.getArena();

    var current: TextComponent = undefined;
    switch (try mapr.next()) {
        .string => |s| return .text(s, .{}),
        .aggregate_start => {
            current = .empty;

            var fg = serial.FieldGatherer(&.{
                .{ .name = "type", .type = .string },

                .{ .name = "text", .type = .string },

                .{ .name = "translate", .type = .string },
                .{ .name = "fallback", .type = .string },
                .{ .name = "with", .type = .{ .array = &.{ .deserializeable = TextComponent } } },

                .{ .name = "score", .type = .{ .custom = .{
                    .type = @FieldType(Content, "score"),
                    .read = gatherScoreValue,
                } } },

                .{ .name = "selector", .type = .string },
                .{ .name = "separator", .type = .{ .copy = &.{ .deserializeable = TextComponent } } }, // both used for selector and nbt

                .{ .name = "keybind", .type = .string },

                .{ .name = "source", .type = .string },
                .{ .name = "nbt", .type = .string },
                .{ .name = "interpret", .type = .string },
                .{ .name = "plain", .type = .string },
                .{ .name = "entity", .type = .string },
                .{ .name = "block", .type = .string },
                .{ .name = "storage", .type = .string },

                .{ .name = "font", .type = .string },
                .{ .name = "bold", .type = .boolean },
                .{ .name = "italic", .type = .boolean },
                .{ .name = "underlined", .type = .boolean },
                .{ .name = "strikethrough", .type = .boolean },
                .{ .name = "obfuscated", .type = .boolean },
                .{ .name = "shadow_color", .type = .{ .custom = .{ .type = u32, .read = gatherShadowColor } } },
                .{ .name = "insertion", .type = .string },
                .{ .name = "click_event", .type = .string },
                .{ .name = "hover_event", .type = .string },
                .{ .name = "extra", .type = .{ .array = &.{ .deserializeable = TextComponent } } },
            }){ .opts = .{
                .duplicate_field_mode = .use_last,
                .ignore_unknown_fields = true,
            } };
            defer fg.deinit(gpa);

            var first: enum {
                none,
                text,
                translatable,
                score,
                selector,
                keybind,
                nbt,

                fn maybeSet(self: *@This(), new: @This()) void {
                    if (self.* == .none) self.* = new;
                }
            } = .none;

            while (try fg.next(gpa, _arena, mapr)) |chosen| {
                switch (chosen) {
                    else => {},

                    .text => first.maybeSet(.text),
                    .translate => first.maybeSet(.translatable),
                    .score => first.maybeSet(.score),
                    .keybind => first.maybeSet(.keybind),
                    .nbt => first.maybeSet(.nbt),
                }
            }

            const ContentType = @typeInfo(Content).@"union".tag_type.?;

            const real_type: ContentType = blk: {
                if (fg.get(.type)) |typ| notype: {
                    break :blk switch (std.meta.stringToEnum(ContentType, typ) orelse break :notype) {
                        .int, .float => break :notype,
                        else => |v| v,
                    };
                } else |_| {}

                switch (first) {
                    .none => return .empty,
                    inline else => |tag| break :blk @field(ContentType, @tagName(tag)),
                }
            };

            switch (real_type) {
                .int, .float => unreachable,
                .text => current.content = .{ .text = try fg.get(.text) },
                .translatable => current.content = .{ .translatable = .{
                    .id = try fg.get(.translate),
                    .fallback = fg.getNullable(.fallback),
                    .with = try _arena.dupe(TextComponent, fg.getNullable(.with) orelse &.{}),
                } },
                .score => current.content = .{ .score = try fg.get(.score) },
                .selector => {
                    @panic("Selector parsing not yet implemented");
                    //     current.content = .{ .selector = .{
                    //     .value = try Selector.parsetry fg.get((.selector)),
                    //     .separator = separator_f,
                    // } }
                },
                .keybind => {
                    const kb_translation = try fg.get(.keybind);
                    if (kb_translation.len < 4 or kb_translation.len > Keybind.max_formatted_len) {
                        return error.LengthMismatch;
                    }
                    var buf: [Keybind.max_formatted_len]u8 = undefined;
                    var bw = std.Io.Writer.fixed(&buf);
                    bw.print("key.{s}", .{kb_translation}) catch unreachable;
                    const real_kb = std.meta.stringToEnum(Keybind, bw.buffered());
                    current.content = .{ .keybind = .{
                        .key = real_kb orelse .unknown,
                        .translation = kb_translation,
                    } };
                },
                .nbt => {
                    @panic("Nbt not yet implemented");
                    // const Source = @FieldType(@FieldType(Content, "nbt"), "source");
                    // var src: Source = undefined;
                    // if (entity_f) |ent| {
                    //     src = .{ .entity = try Selector.parse(ent) };
                    // } else if (block_f) |block| {
                    // }

                    // current.content = .{ .nbt = .{
                    //     .source =
                    // } };
                },
            }
        },
        .array_start => |arr| {
            var next_token = try mapr.peek();
            switch (next_token) {
                .string, .aggregate_start, .array_start => current = try deserialize(mapr),
                .array_end => return .empty,
                else => return error.UnexpectedToken,
            }

            var list = try std.ArrayList(TextComponent).initCapacity(gpa, (arr.length orelse 1) - 1);
            defer list.deinit(gpa);

            while (true) {
                next_token = try mapr.peek();
                switch (next_token) {
                    .string, .aggregate_start, .array_start => try list.append(gpa, try deserialize(mapr)),
                    .array_end => break,
                    else => return error.UnexpectedToken,
                }
            }

            current.children = try _arena.dupe(TextComponent, list.items);
        },
        else => return error.UnexpectedToken,
    }
    return current;
}

test {
    std.testing.refAllDecls(@This());
}
