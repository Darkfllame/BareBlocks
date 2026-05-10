const std = @import("std");
const assert = std.debug.assert;

pub const Color = enum(u24) {
    black = 0x000000,
    dark_blue = 0x0000AA,
    dark_green = 0x00AA00,
    dark_aqua = 0x00AAAA,
    dark_red = 0xAA0000,
    dark_purple = 0xAA00AA,
    gold = 0xFFAA00,
    gray = 0xAAAAAA,
    dark_gray = 0x555555,
    blue = 0x5555FF,
    green = 0x55FF55,
    aqua = 0x55FFFF,
    red = 0xFF5555,
    light_purple = 0xFF55FF,
    yellow = 0xFFFF55,
    white = 0xFFFFFF,
    _,

    pub const ARGB = packed struct(u32) {
        color: Color,
        alpha: u8 = 0xFF,

        pub fn hex(x: u32) ARGB {
            return @bitCast(x);
        }

        pub fn values(a: u8, r: u8, g: u8, b: u8) ARGB {
            return ARGB.hex(
                (@as(u32, a) << 24) |
                    (@as(u32, r) << 16) |
                    (@as(u32, g) << 8) |
                    b,
            );
        }

        pub fn floatsNormalized(comptime T: type, a: T, r: T, g: T, b: T) ARGB {
            comptime assert(@typeInfo(T) == .float);

            return ARGB.values(
                @intFromFloat(@min(255, a * 255)),
                @intFromFloat(@min(255, r * 255)),
                @intFromFloat(@min(255, g * 255)),
                @intFromFloat(@min(255, b * 255)),
            );
        }

        pub fn floats(comptime T: type, a: T, r: T, g: T, b: T) ARGB {
            comptime assert(@typeInfo(T) == .float);

            return ARGB.values(
                @intFromFloat(@min(255, a / 255)),
                @intFromFloat(@min(255, r / 255)),
                @intFromFloat(@min(255, g / 255)),
                @intFromFloat(@min(255, b / 255)),
            );
        }
    };

    pub fn hex(x: u24) Color {
        return @enumFromInt(x);
    }

    pub fn values(r: u8, g: u8, b: u8) Color {
        return hex((@as(u24, r) << 16) | (@as(u24, g) << 8) | b);
    }

    pub fn floatsNormalized(r: f32, g: f32, b: f32) Color {
        return values(
            @intFromFloat(@min(255, r * 255)),
            @intFromFloat(@min(255, g * 255)),
            @intFromFloat(@min(255, b * 255)),
        );
    }

    pub fn floats(r: f32, g: f32, b: f32) Color {
        return values(
            @intFromFloat(@min(255, r / 255)),
            @intFromFloat(@min(255, g / 255)),
            @intFromFloat(@min(255, b / 255)),
        );
    }
};
