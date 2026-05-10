const std = @import("std");

pub const Color = @import("color.zig").Color;
pub const BlockChain = @import("block_chain.zig").BlockChain;
pub const GameProfile = @import("GameProfile.zig");
pub const Identifier = @import("Identifier.zig");
pub const Keybind = @import("keybinds.zig").Keybind;
pub const NBT = @import("NBT.zig");
pub const Selector = @import("Selector.zig");
pub const TextComponent = @import("TextComponent.zig");
pub const UUID = @import("UUID.zig");

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
