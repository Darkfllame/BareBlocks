const std = @import("std");

const Allocator = std.mem.Allocator;

pub const serial = @import("serial.zig");
pub const translation = @import("translation.zig");

pub const BitStack = @import("BitStack.zig");
pub const BlockChain = @import("block_chain.zig").BlockChain;
pub const Color = @import("color.zig").Color;
pub const CountingAllocator = @import("CountingAllocator.zig");
pub const GameProfile = @import("GameProfile.zig");
pub const Identifier = @import("Identifier.zig");
pub const Keybind = @import("keybinds.zig").Keybind;
pub const NBT = @import("NBT.zig");
pub const Selector = @import("Selector.zig");
pub const TextComponent = @import("TextComponent.zig");
pub const UUID = @import("uuid.zig").UUID;

pub const max_registry_id = std.math.maxInt(i32);

pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.ArrayHashMapUnmanaged(
            Identifier,
            T,
            Identifier.HashCtx,
            true,
        ),

        pub const empty = Self{
            .map = .empty,
            .current_id = 0,
        };

        pub const AddEntryError = Allocator.Error || error{ DuplicatedEntry, TooManyEntries };

        pub const EntryID = enum(u32) {
            fn isValid(self: EntryID) bool {
                return @intFromEnum(self) <= max_registry_id;
            }

            _,
        };

        pub fn addEntry(self: *Self, allocator: Allocator, key: Identifier, value: T) AddEntryError!EntryID {
            const new_id = self.map.count();
            if (new_id > max_registry_id) return error.TooManyEntries;
            const gop = try self.map.getOrPut(allocator, key);
            if (gop.found_existing) return error.DuplicateEntry;
            gop.value_ptr.* = value;
            return @enumFromInt(new_id);
        }
    };
}

pub const Utf8Iterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn init(bytes: []const u8) Utf8Iterator {
        return .{ .bytes = bytes, .i = 0 };
    }

    pub fn nextCodepointSlice(it: *Utf8Iterator) error{InvalidUTF8}!?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch return error.InvalidUTF8;
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }

    pub fn nextCodepoint(it: *Utf8Iterator) error{InvalidUTF8}!?u21 {
        const slice = (try it.nextCodepointSlice()) orelse return null;
        return std.unicode.utf8Decode(slice) catch return error.InvalidUTF8;
    }

    /// Look ahead at the next n codepoints without advancing the iterator.
    /// If fewer than n codepoints are available, then return the remainder of the string.
    pub fn peek(it: *Utf8Iterator, n: usize) error{InvalidUTF8}![]const u8 {
        const original_i = it.i;
        defer it.i = original_i;

        var end_ix = original_i;
        var found: usize = 0;
        while (found < n) : (found += 1) {
            const next_codepoint = (try it.nextCodepointSlice()) orelse return it.bytes[original_i..];
            end_ix += next_codepoint.len;
        }

        return it.bytes[original_i..end_ix];
    }
};

pub fn compileError(comptime fmt: []const u8, args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(fmt, args));
}

pub fn validateMethod(comptime Base: type, comptime name: []const u8, comptime params: []const type, comptime ReturnType: type) void {
    const fn_type_str, const fn_args_str = blk: {
        var str: []const u8 = "fn (" ++ @typeName(Base);
        for (params) |T| str = str ++ ", " ++ @typeName(T);
        const arg_end = str.len;
        str = str ++ ") " ++ @typeName(ReturnType);
        break :blk .{ str, str["fn (".len..arg_end] };
    };
    if (!@hasDecl(Base, name)) {
        compileError("{any}.{s}({s}) missing", .{ Base, name, fn_args_str });
    }
    const bad_fn_msg = std.fmt.comptimePrint("{any}.{s} must be a method of type {s}", .{
        Base, name, fn_type_str,
    });
    const info = sw: switch (@typeInfo(@TypeOf(@field(Base, name)))) {
        .@"fn" => |info| info,
        .pointer => |ptr| {
            if (@typeInfo(ptr.child) != .@"fn") @compileError(bad_fn_msg);
            if (ptr.size != .one) @compileError(bad_fn_msg);
            if (!ptr.is_const) @compileError(bad_fn_msg);
            break :sw @typeInfo(ptr.child).@"fn";
        },
        else => @compileError(bad_fn_msg),
    };
    if (info.params.len != params.len + 1) @compileError(bad_fn_msg);
    if (info.params[0].type) |SelfType| switch (SelfType) {
        Base, *Base, *const Base => {},
        else => switch (@typeInfo(SelfType)) {
            .pointer => |ptr| if (ptr.child != Base or ptr.size != .one) @compileError(bad_fn_msg),
            else => @compileError(bad_fn_msg),
        },
    };
    for (params, info.params[1..]) |T, p| {
        if (p.type != T) @compileError(bad_fn_msg);
    }
    // TODO: Make a 'canBeCastedTo' funtion
    if (info.return_type.? != ReturnType) @compileError(bad_fn_msg);
}

test {
    std.testing.refAllDecls(@This());
}
