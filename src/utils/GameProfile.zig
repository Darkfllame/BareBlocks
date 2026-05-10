const GameProfile = @This();
const std = @import("std");
const UUID = @import("UUID.zig");

uuid: UUID,
lengths: packed struct {
    username: @Int(.unsigned, std.math.log2_int_ceil(usize, max_lengths.username)),
    properties: @Int(.unsigned, std.math.log2_int_ceil(usize, max_lengths.properties)),
},
username_ptr: [*]const u8,
properties_ptr: [*]const Property,

pub const HashCtx = struct {
    pub fn hash(_: HashCtx, key: GameProfile) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.username());
        hasher.update(@ptrCast(&key.uuid.value));
        return hasher.final();
    }
    pub fn eql(_: HashCtx, a: GameProfile, b: GameProfile) bool {
        return a.eql(b);
    }
};

pub const max_lengths = opaque {
    /// Mesured in unicode codepoints
    pub const username: usize = 16;
    pub const properties: usize = 16;
    /// Mesured in unicode codepoints
    pub const property_name: usize = 64;
    /// Mesured in unicode codepoints
    pub const property_value: usize = 32767;
    /// Mesured in unicode codepoints
    pub const signature: usize = 1024;
};

pub const Property = struct {
    lengths: packed struct {
        name: @Int(.unsigned, std.math.log2_int_ceil(usize, max_lengths.property_name * 3)),
        value: @Int(.unsigned, std.math.log2_int_ceil(usize, max_lengths.property_value * 3)),
        signature: @Int(.unsigned, std.math.log2_int_ceil(usize, max_lengths.signature * 3)),
    },
    name_ptr: [*]const u8,
    value_ptr: [*]const u8,
    signature_ptr: ?[*]const u8,

    pub fn name(self: Property) []const u8 {
        return self.name_ptr[0..self.lengths.name];
    }

    pub fn value(self: Property) []const u8 {
        return self.value_ptr[0..self.lengths.value];
    }

    pub fn signature(self: Property) ?[]const u8 {
        return if (self.signature_ptr) |sptr|
            sptr[0..self.lengths.signature]
        else
            null;
    }
};

pub fn validate(_username: []const u8, uuid: UUID) error{ InvalidCharacter, InvalidLength }!GameProfile {
    for (_username) |c| {
        if (c <= 32 or c >= 127) return error.InvalidCharacter;
    }
    if (_username.len > max_lengths.username) return error.InvalidLength;

    return .{
        .uuid = uuid,
        .lengths = .{
            .username = @intCast(_username.len),
            .properties = 0,
        },
        .username_ptr = _username.ptr,
        .properties_ptr = &[_]Property{},
    };
}

pub fn username(self: GameProfile) []const u8 {
    return self.username_ptr[0..self.lengths.username];
}

pub fn properties(self: GameProfile) []const Property {
    return self.properties_ptr[0..self.lengths.properties];
}

pub fn format(self: GameProfile, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("GameProfile{{ {f}, \"{s}\", {d} properties }}", .{
        self.uuid, self.username(), self.lengths.properties,
    });
}

pub fn eql(self: GameProfile, other: GameProfile) bool {
    return self.uuid.eql(other.uuid) or
        std.mem.eql(u8, self.username(), other.username());
}
