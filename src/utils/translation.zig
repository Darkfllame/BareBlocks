const std = @import("std");
const utils = @import("utils.zig");
const json = std.json;
const assert = std.debug.assert;

const en_us = @embedFile("en_us");

pub const logger = std.log.scoped(.translation);

var initialized: bool = false;
var map: std.StringHashMapUnmanaged([]const Component) = .empty;

pub const Component = union(enum) {
    text: []const u8,
    argument: ArgumentIdx,

    const ArgumentIdx = u8;
};

/// `allocator` should be initialized with an `ArenaAllocator`,
/// `FixedBufferAllocator` or something that works in a similar way
/// (automatically frees used memory).
pub fn init(allocator: std.mem.Allocator) !void {
    if (initialized) return;
    errdefer map.deinit(allocator);

    // This shit is not well written and probably the naive-est attempt to
    // implement the reading of this json file without over-allocating

    // The current translation file has that many entries.
    // Might as well pre-allocate them
    try map.ensureTotalCapacity(allocator, 7770);

    var scanner = json.Scanner.initCompleteInput(allocator, en_us);

    assert(try scanner.next() == .object_begin);

    main: while (true) {
        const name = switch (try scanner.next()) {
            .string, .allocated_string => |s| s,
            .object_end => break,
            else => unreachable,
        };

        const text = switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => unreachable,
        };

        if (std.mem.startsWith(u8, name, "translation.test")) {
            continue;
        }

        var fmt_count: usize = 0;
        for (text) |c| {
            fmt_count += @intFromBool(c == '%');
        }

        if (fmt_count == 0) {
            const gop = try map.getOrPut(allocator, name);
            if (gop.found_existing) {
                logger.warn("Translation {s} might not be available (Duplicate hash)", .{name});
            } else {
                gop.value_ptr.* = try allocator.dupe(Component, &.{.{ .text = text }});
            }
            continue;
        }

        var array = try std.ArrayList(Component)
            .initCapacity(allocator, fmt_count * 2 + 1);
        var arg_mask: std.bit_set.ArrayBitSet(usize, @bitSizeOf(Component.ArgumentIdx)) =
            .initFull();

        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '%') continue;
            i += 1;
            const c = if (i < text.len) text[i] else {
                logger.warn("Invalid translation format on {s}: \"{s}\" (Invalid argument format)", .{ name, text });
                continue :main;
            };

            switch (c) {
                's' => {
                    const end = i - 1;
                    if (start != end) {
                        array.appendAssumeCapacity(.{ .text = text[start..end] });
                    }
                    start = i + 1;
                    const arg_idx = arg_mask.findFirstSet() orelse {
                        logger.warn("Out of arguments, (max: {d}) {s}: \"{s}\" (Too many arguments)", .{
                            @bitSizeOf(Component.ArgumentIdx), name, text,
                        });
                        continue :main;
                    };
                    arg_mask.unset(arg_idx);
                    array.appendAssumeCapacity(.{ .argument = @intCast(arg_idx) });
                    continue;
                },
                '0'...'9' => {
                    const str_end = i - 1;
                    const num_start = i;
                    const end = end: while (i < text.len) : (i += 1) {
                        if (text[i] == '$') break :end i;
                    } else {
                        logger.warn("Invalid translation format on {s}: \"{s}\" (Unclosed argument index)", .{ name, text });
                        continue :main;
                    };
                    i += 1;
                    if (i >= text.len or text[i] != 's') {
                        logger.warn("Invalid translation format on {s}: \"{s}\" (Invalid argument format)", .{ name, text });
                        continue :main;
                    }
                    const arg_idx = std.fmt.parseInt(u8, text[num_start..end], 10) catch |e| {
                        logger.warn("Invalid translation format on ({t}) {s}: \"{s}\" (Invalid argument index)", .{
                            e, name, text,
                        });
                        continue :main;
                    };
                    const real_idx = if (arg_idx > 0)
                        arg_idx - 1
                    else {
                        logger.warn("Invalid translation format on {s}: \"{s}\" (Invalid argument index)", .{
                            name, text,
                        });
                        continue :main;
                    };
                    arg_mask.unset(real_idx);
                    array.appendSliceAssumeCapacity(&.{
                        .{ .text = text[start..str_end] },
                        .{ .argument = real_idx },
                    });
                    start = i + 1;
                },
                '%' => {},
                else => {
                    logger.warn("Out of arguments {s}: \"{s}\" (Invalid argument format)", .{
                        name, text,
                    });
                    continue :main;
                },
            }
        }

        if (start != i) {
            array.appendAssumeCapacity(.{ .text = text[start..i] });
        }

        const gop = try map.getOrPut(allocator, name);
        if (gop.found_existing) {
            logger.warn("Translation {s} might not be available (Duplicate hash)", .{name});
        } else {
            gop.value_ptr.* = array.items;
        }
    }

    assert(try scanner.next() == .end_of_document);

    initialized = true;
}

pub fn get(name: []const u8) []const Component {
    return map.get(name) orelse &.{.{ .text = name }};
}

pub fn getKeybind(kb: utils.Keybind) []const u8 {
    var buf: [4 + utils.Keybind.max_formatted_len]u8 = undefined;
    var fba = std.Io.Writer.fixed(&buf);

    fba.print("key.{t}", .{kb}) catch unreachable;
    return get(fba.buffered())[0].text;
}
