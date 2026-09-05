const std = @import("std");
const utils = @import("utils");
const serial = @import("serial");
const StructuredPacket = @import("StructuredPacket.zig");
const PacketType = StructuredPacket.Type;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(StatusResponse);
    std.testing.refAllDecls(StatusResponse.PlayerEntry);
    std.testing.refAllDecls(StatusResponse.Version);
}

pub const HandshakeIntent = enum(u2) { status = 1, login, transfer };
pub const ServerLinkLabel = enum(u4) { bug_report, community_guidelines, support, statuts, feedback, community, website, forums, news, announcements };
pub const ChatMode = enum { enabled, commands_only, hidden };
pub const SkinPart = enum { cape, jacket, left_sleeve, right_sleeve, left_pants_leg, right_pants_leg, hat };
pub const MainHand = enum { left, right };
pub const ParticleSetting = enum { all, decreased, minimal };
pub const ResourcePackResponseResult = enum { successful_download, declined, failed_download, accepted, downloaded, invalid_url, failed_to_reload, discarded };
pub const StatusResponse = struct {
    version: Version = .@"1.21.11",
    players: ?struct {
        max: u31,
        online: u31,
        sample: []const PlayerEntry = &.{},
    } = null,
    description: utils.TextComponent = .empty,
    enforcesSecureChat: ?bool = null,
    preventsChatReports: ?bool = null,

    pub const PlayerEntry = struct {
        name: []const u8 = "Anonymous Player",
        id: utils.UUID = .null,
    };

    pub const Version = struct {
        name: []const u8,
        protocol: u32,

        pub const @"1.21.11" = named("Gecko-1.21.11", 774);
        pub const @"1.21.10" = named("Gecko-1.21.10", 773);
        pub const @"1.21.9" = named("Gecko-1.21.9", 773);
        pub const @"1.21.8" = named("Gecko-1.21.8", 772);
        pub const @"1.21.7" = named("Gecko-1.21.7", 772);
        pub const @"1.21.6" = named("Gecko-1.21.6", 771);
        pub const @"1.21.5" = named("Gecko-1.21.5", 770);
        pub const @"1.21.4" = named("Gecko-1.21.4", 769);
        pub const @"1.21.3" = named("Gecko-1.21.3", 768);
        pub const @"1.21.2" = named("Gecko-1.21.2", 768);
        pub const @"1.21.1" = named("Gecko-1.21.1", 767);
        pub const @"1.21" = named("Gecko-1.21", 767);

        pub fn named(comptime name: []const u8, comptime protocol: u32) Version {
            return .{ .name = name, .protocol = protocol };
        }
    };

    pub fn serialize(self: *const StatusResponse, mapw: *serial.MapWriter) !void {
        try mapw.beginAggregate();

        try mapw.fieldName("version");
        try mapw.beginAggregate();
        try mapw.fieldName("name");
        try mapw.writeString(self.version.name);
        try mapw.fieldName("protocol");
        try mapw.writeInt(@intCast(self.version.protocol));
        try mapw.endAggregate();

        if (self.players) |players| {
            try mapw.fieldName("players");
            try mapw.beginAggregate();
            try mapw.fieldName("max");
            try mapw.writeInt(players.max);
            try mapw.fieldName("online");
            try mapw.writeInt(players.online);
            if (players.sample.len > 0) {
                try mapw.fieldName("sample");
                try mapw.beginArray(players.sample.len);
                for (players.sample) |entry| {
                    try mapw.beginAggregate();
                    try mapw.fieldName("name");
                    try mapw.writeString(entry.name);
                    try mapw.fieldName("id");
                    try entry.id.serialize(mapw);
                    try mapw.endAggregate();
                }
                try mapw.endArray();
            }
            try mapw.endAggregate();
        }

        if (!self.description.isSimpleText() and !self.description.isEmpty()) {
            try mapw.fieldName("description");
            try self.description.serialize(mapw);
        }

        if (self.enforcesSecureChat) |enforcesSecureChat| {
            try mapw.fieldName("enforcesSecureChat");
            try mapw.writeBoolean(enforcesSecureChat);
        }

        if (self.preventsChatReports) |preventsChatReports| {
            try mapw.fieldName("preventsChatReports");
            try mapw.writeBoolean(preventsChatReports);
        }

        try mapw.endAggregate();
    }
};

//=====================common=========================//

const cookie_payload = PacketType.prefixedOptional(.prefixedMaxArray(.ubyte, 5120));
const get_set_cookie_fields = &[_]StructuredPacket.Field{
    .{ .name = "key", .type = .identifier },
    .{ .name = "payload", .type = cookie_payload },
};

pub const ping_pong = PacketType{ .long = {} };
pub const plugin_message = StructuredPacket.getType(.{
    .name = "PluginMessage",
    .fields = &.{
        .{ .name = "channel", .type = .identifier },
        .{ .name = "data", .type = .remainingArray(.ubyte) },
    },
});
pub const keep_alive = PacketType{ .long = {} };

pub const disconnect_s2c = PacketType.nbt_text_component;
pub const cookie_request_s2c = PacketType{ .identifier = {} };
pub const resource_pack_pop_s2c = PacketType{ .uuid = {} };
pub const resource_pack_push_s2c = StructuredPacket.getType(.{
    .name = "ResourcePackPushS2C",
    .fields = &.{
        .{ .name = "uuid", .type = .uuid },
        .{ .name = "url", .type = .max_string },
        .{ .name = "hash", .type = .limitedString(40) },
        .{ .name = "forces", .type = .bool },
        .{ .name = "prompt_message", .type = .prefixedOptional(.nbt_text_component) },
    },
});
pub const store_cookie_s2c = StructuredPacket.getType(.{
    .name = "StoreCookieS2C",
    .fields = get_set_cookie_fields,
});
pub const transfer_s2c = StructuredPacket.getType(.{
    .name = "TransferS2C",
    .fields = &.{
        .{ .name = "host", .type = .max_string },
        .{ .name = "port", .type = .var_int },
    },
});
/// ```
/// []const struct {
///     registry: Identifier,
///     tags: []const struct {
///         /// Name of the tag without the #-prefix, such as `minecraft:climbable`
///         /// Numeric IDs of the given type (block, item, etc.). This list replaces the previous list of IDs for the given tag.
///         name: Identifier,
///         entries: []const i32,
///     }
/// }
/// ```
pub const update_tags_s2c = PacketType.prefixedArray(StructuredPacket.getType(.{
    .name = "UpdateTagsS2C::RegistryTag",
    .fields = &.{
        .{ .name = "registry", .type = .identifier },
        .{ .name = "tags", .type = .prefixedArray(StructuredPacket.getType(.{
            .name = "UpdateTagsS2C::Tag",
            .fields = &.{
                .{ .name = "name", .type = .identifier },
                .{ .name = "entries", .type = .prefixedArray(.var_int) },
            },
        })) },
    },
}));
pub const custom_report_details_s2c = PacketType.prefixedMaxArray(StructuredPacket.getType(.{
    .name = "CustomReportDetailsS2C::Detail",
    .fields = &.{
        .{ .name = "title", .type = .limitedString(128) },
        .{ .name = "description", .type = .limitedString(4096) },
    },
}), 32);
pub const server_links_s2c = PacketType.prefixedArray(StructuredPacket.getType(.{
    .name = "ServerLinksS2C::Entry",
    .fields = &.{
        .{ .name = "label", .type = .{ .either = &.{
            PacketType{ .@"enum" = .of(ServerLinkLabel, .var_int) },
            PacketType.nbt_text_component,
        } } },
        .{ .name = "url", .type = .max_string },
    },
}));
pub const clear_dialog_s2c = StructuredPacket.named("ClearDialogS2C");

pub const cookie_response_c2s = StructuredPacket.getType(.{
    .name = "CookieResponseC2S",
    .fields = get_set_cookie_fields,
});
pub const client_information_c2s = StructuredPacket.getType(.{
    .name = "ClientInformationC2S",
    .fields = &.{
        .{ .name = "locale", .type = .limitedString(16) },
        .{ .name = "view_distance", .type = .ibyte },
        .{ .name = "chat_mode", .type = .{ .@"enum" = .of(ChatMode, .var_int) } },
        .{ .name = "chat_colors", .type = .bool },
        .{ .name = "displayed_skin_parts", .type = .{ .enum_set = .of(SkinPart, .u8) } },
        .{ .name = "main_hand", .type = .{ .@"enum" = .of(MainHand, .var_int) } },
        .{ .name = "enable_text_filtering", .type = .bool },
        .{ .name = "allow_server_listing", .type = .bool },
        .{ .name = "particles", .type = .{ .@"enum" = .of(ParticleSetting, .var_int) } },
    },
});
pub const resource_pack_response_c2s = StructuredPacket.getType(.{
    .name = "ResourcePackResponseC2S",
    .fields = &.{
        .{ .name = "uuid", .type = .uuid },
        .{ .name = "result", .type = .{ .@"enum" = .of(ResourcePackResponseResult, .var_int) } },
    },
});
pub const custom_click_action_c2s = StructuredPacket.getType(.{
    .name = "CustomClickActionC2S",
    .fields = &.{
        .{ .name = "id", .type = .identifier },
        .{ .name = "payload", .type = .{ .nbt = null } },
    },
});

//=====================handshake=======================//

pub const handshake_c2s = StructuredPacket.getType(.{
    .name = "HandshakeC2SPacket",
    .fields = &.{
        .{ .name = "protocol_version", .type = .var_int },
        .{ .name = "server_address", .type = .limitedString(255) },
        .{ .name = "server_port", .type = .{ .short = .unsigned } },
        .{ .name = "intent", .type = .{ .@"enum" = .of(HandshakeIntent, .var_int) } },
    },
});

//=====================status==========================//

pub const status_response_s2c = PacketType{ .json = StatusResponse };

pub const status_request_c2s = StructuredPacket.named("StatusRequestC2S");

//=====================login===========================//

pub const login_disconnect_s2c = PacketType.json_text_component;
pub const encryption_request_s2c = StructuredPacket.getType(.{
    .name = "EncryptionRequestS2C",
    .fields = &.{
        .{ .name = "server_id", .type = .limitedString(20) },
        .{ .name = "public_key", .type = .byte_array },
        .{ .name = "verify_token", .type = .byte_array },
        .{ .name = "should_authenticate", .type = .bool },
    },
});
pub const login_success_s2c = PacketType{ .game_profile = {} };
pub const set_compression_s2c = PacketType{ .var_int = {} };
pub const login_plugin_request_s2c = StructuredPacket.getType(.{
    .name = "LoginPluginRequestS2C",
    .fields = &.{
        .{ .name = "message_id", .type = .var_int },
        .{ .name = "channel", .type = .identifier },
        .{ .name = "data", .type = .remainingArray(.ubyte) },
    },
});

pub const login_start_c2s = StructuredPacket.getType(.{
    .name = "LoginStartC2S",
    .fields = &.{
        .{ .name = "name", .type = .max_string },
        .{ .name = "player_uuid", .type = .uuid },
    },
});
pub const encryption_response_c2s = StructuredPacket.getType(.{
    .name = "EncryptionResponseC2S",
    .fields = &.{
        .{ .name = "shared_secret", .type = .byte_array },
        .{ .name = "verify_token", .type = .byte_array },
    },
});
pub const login_plugin_response_c2s = StructuredPacket.getType(.{
    .name = "LoginPluginResponseC2S",
    .fields = &.{
        .{ .name = "message_id", .type = .var_int },
        .{ .name = "data", .type = .prefixedOptional(.remainingArray(.ubyte)) },
    },
});
pub const login_acknowledged_c2s = StructuredPacket.getType(.{ .name = "LoginAcknowledgedC2S" });

//=====================configuration===================//

pub const known_packs = PacketType.prefixedArray(StructuredPacket.getType(.{
    .name = "KnownPacksPacket",
    .fields = &.{
        .{ .name = "namespace", .type = .max_string },
        .{ .name = "id", .type = .max_string },
        .{ .name = "version", .type = .max_string },
    },
}));

pub const finish_configuration_s2c = StructuredPacket.named("FinishConfigurationS2C");
pub const reset_chat_s2c = StructuredPacket.named("ResetChatS2C");
pub const registry_data_s2c = StructuredPacket.getType(.{
    .name = "RegistryDataS2C",
    .fields = &.{
        .{ .name = "registry_id", .type = .identifier },
        .{ .name = "entries", .type = .prefixedArray(StructuredPacket.getType(.{
            .name = "RegistryDataS2C::Entry",
            .fields = &.{
                .{ .name = "entry_id", .type = .identifier },
                .{ .name = "data", .type = .prefixedOptional(.{ .nbt = null }) },
            },
        })) },
    },
});
pub const feature_flags_s2c = PacketType.prefixedArray(.identifier);
pub const configuration_show_dialog_s2c = PacketType{ .nbt = null };
pub const code_of_conduct_s2c = PacketType.max_string;

pub const ack_finish_configuration_c2s = StructuredPacket.named("AcknownledgeFinishConfigurationC2S");
pub const accept_code_of_conduct_c2s = StructuredPacket.named("AcceptCodeOfConductC2S");

//=====================play===========================//
