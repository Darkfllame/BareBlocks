const std = @import("std");
const utils = @import("utils");
const serial = @import("serial");
const StructuredPacket = @import("StructuredPacket.zig");
const PacketType = StructuredPacket.Type;

test {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = @typeInfo(@This()).@"struct";
    inline for (info.decl_names) |dname| {
        const value = @field(@This(), dname);
        if (@TypeOf(value) == PacketType) {
            aw.clearRetainingCapacity();
            _ = arena.reset(.retain_capacity);
            errdefer {
                var buffer: [64]u8 = undefined;
                const stderr = std.debug.lockStderr(&buffer);
                defer std.debug.unlockStderr();
                const w = &stderr.file_writer.interface;
                w.print("{s}\n{f}\n", .{
                    aw.written(),
                    value,
                }) catch {};
                // w.flush() catch {};
            }
            try value.write(.newWithArena(std.testing.allocator, &arena), &aw.writer, value.default());
            var reader = std.Io.Reader.fixed(aw.written());
            _ = try PacketType.readRoot(value, .streamedInput(std.testing.allocator, &arena), &reader);
        }
    }
    std.testing.refAllDecls(StatusResponse);
    std.testing.refAllDecls(StatusResponse.PlayerEntry);
    std.testing.refAllDecls(StatusResponse.Version);
}

pub const HandshakeIntent = enum(u2) { invalid = 0, status = 1, login = 2, transfer = 3 };
pub const ServerLinkLabel = enum(u4) { bug_report, community_guidelines, support, statuts, feedback, community, website, forums, news, announcements };
pub const ChatMode = enum { enabled, commands_only, hidden };
pub const SkinPart = enum { cape, jacket, left_sleeve, right_sleeve, left_pants_leg, right_pants_leg, hat };
pub const MainHand = enum { left, right };
pub const ParticleSetting = enum { all, decreased, minimal };
pub const ResourcePackResponseResult = enum { successful_download, declined, failed_download, accepted, downloaded, invalid_url, failed_to_reload, discarded };
pub const StatusResponse = struct {
    version: Version = .@"1.21.11",
    players: ?Players = null,
    description: utils.TextComponent = .empty,
    enforcesSecureChat: ?bool = null,
    preventsChatReports: ?bool = null,

    pub const default = StatusResponse{};

    pub const Players = struct {
        max: u31,
        online: u31 = 0,
        sample: []const PlayerEntry = &.{},
    };

    pub const PlayerEntry = struct {
        name: []const u8 = "Anonymous Player",
        id: utils.UUID = .null,

        pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!PlayerEntry {
            const gpa = mapr.getAlloctor();
            const arena = mapr.getArena();

            var fg = serial.FieldGatherer(&.{
                .{ .name = "name", .type = .string },
                .{ .name = "id", .type = .{ .deserializeable = utils.UUID } },
            }){};
            defer fg.deinit(gpa);

            try mapr.nextExpect(.aggregate_start);

            while (try fg.next(gpa, arena, mapr)) |_| {}

            return .{
                .name = try fg.get(.name),
                .id = try fg.get(.id),
            };
        }
    };

    pub const Version = struct {
        name: []const u8,
        protocol: u32,

        pub const @"26.3" = named("Gecko-26.3", 777);
        pub const @"26.2" = named("Gecko-26.2", 776);
        pub const @"26.1.2" = named("Gecko-26.2", 775);
        pub const @"26.1.1" = named("Gecko-26.2", 775);
        pub const @"26.1" = named("Gecko-26.2", 775);
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

        pub fn named(name: []const u8, protocol: u32) Version {
            return .{ .name = name, .protocol = protocol };
        }

        pub fn renamed(self: Version, name: []const u8) Version {
            return .{ .name = name, .protocol = self.protocol };
        }
    };

    pub fn serialize(self: *const StatusResponse, mapw: *serial.MapWriter) serial.MapWriter.WriteError!void {
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

        if (!self.description.isEmpty()) {
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

    pub fn deserialize(mapr: *serial.MapReader) serial.MapReader.ReadError!StatusResponse {
        const gpa = mapr.getAlloctor();
        const arena = mapr.getArena();

        var fg = serial.FieldGatherer(&.{
            .{ .name = "version", .type = .{ .external = Version } },
            .{ .name = "players", .type = .{ .external = Players } },
            .{ .name = "description", .type = .{ .deserializeable = utils.TextComponent } },
            .{ .name = "enforcesSecureChat", .type = .boolean },
            .{ .name = "preventsChatReports", .type = .boolean },
        }){};
        defer fg.deinit(gpa);

        try mapr.nextExpect(.aggregate_start);

        while (try fg.next(gpa, arena, mapr)) |field| {
            switch (field) {
                .version => {
                    var vfg = serial.FieldGatherer(&.{
                        .{ .name = "name", .type = .string },
                        .{ .name = "protocol", .type = .int },
                    }){};
                    defer vfg.deinit(gpa);

                    try mapr.nextExpect(.aggregate_start);
                    while (try vfg.next(gpa, arena, mapr)) |_| {}

                    fg.set(.version, .{
                        .name = try vfg.get(.name),
                        .protocol = @intCast(try vfg.get(.protocol)),
                    });
                },
                .players => {
                    var pfg = serial.FieldGatherer(&.{
                        .{ .name = "max", .type = .int },
                        .{ .name = "online", .type = .int },
                        .{ .name = "sample", .type = .{ .array = &.{ .deserializeable = PlayerEntry } } },
                    }){};
                    defer pfg.deinit(gpa);

                    try mapr.nextExpect(.aggregate_start);
                    while (try pfg.next(gpa, arena, mapr)) |_| {}

                    fg.set(.players, .{
                        .max = @intCast(try pfg.get(.max)),
                        .online = @intCast(try pfg.get(.online)),
                        .sample = try pfg.get(.sample),
                    });
                },
                else => {},
            }
        }

        return .{
            .version = try fg.get(.version),
            .players = fg.getNullable(.players),
            .description = fg.getNullable(.description) orelse .empty,
            .enforcesSecureChat = fg.getNullable(.enforcesSecureChat),
            .preventsChatReports = fg.getNullable(.preventsChatReports),
        };
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
pub const login_success_s2c = StructuredPacket.getType(.{
    .name = "LoginSuccessS2C",
    .fields = &.{
        .{ .name = "profile", .type = .game_profile },
        .{ .name = "session_id", .type = .uuid },
    },
});
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
pub const key = StructuredPacket.getType(.{
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

pub const GameMode = enum { survival, creative, adventure, spectator };

pub const login_s2c = StructuredPacket.getType(.{
    .name = "LoginS2C",
    .fields = &.{
        .{ .name = "entity_id", .type = .int },
        .{ .name = "hardcore", .type = .bool },
        .{ .name = "dimensions", .type = .prefixedArray(.identifier) },
        .{ .name = "max_players", .type = .var_int },
        .{ .name = "view_distance", .type = .var_int },
        .{ .name = "simulation_distance", .type = .var_int },
        .{ .name = "reduced_debug_info", .type = .bool },
        .{ .name = "show_death_screen", .type = .bool },
        .{ .name = "limited_crafting", .type = .bool },
        // CommonPlayerSpawnInfo
        // Id in the `minecraft:dimension_type` registry, in the order it was sent.
        .{ .name = "dimension_type", .type = .var_int },
        .{ .name = "dimension", .type = .identifier },
        .{ .name = "hashed_seed", .type = .long },
        .{ .name = "game_mode", .type = .{ .@"enum" = .of(GameMode, .var_int) } },
        // The game mode's id + 1, 0 when there's none.
        .{ .name = "previous_game_mode", .type = .var_int },
        .{ .name = "debug", .type = .bool },
        .{ .name = "flat", .type = .bool },
        .{ .name = "death_location", .type = .prefixedOptional(StructuredPacket.getType(.{
            .name = "LoginS2C::DeathLocation",
            .fields = &.{
                .{ .name = "dimension", .type = .identifier },
                .{ .name = "position", .type = .block_position },
            },
        })) },
        .{ .name = "portal_cooldown", .type = .var_int },
        .{ .name = "sea_level", .type = .var_int },
        // end of CommonPlayerSpawnInfo
        .{ .name = "online_mode", .type = .bool },
        .{ .name = "enforces_secure_chat", .type = .bool },
    },
});
pub const game_event_s2c = StructuredPacket.getType(.{
    .name = "GameEventS2C",
    .fields = &.{
        .{ .name = "event", .type = .ubyte },
        .{ .name = "value", .type = .float },
    },
});
pub const player_position_s2c = StructuredPacket.getType(.{
    .name = "PlayerPositionS2C",
    .fields = &.{
        .{ .name = "teleport_id", .type = .var_int },
        .{ .name = "x", .type = .double },
        .{ .name = "y", .type = .double },
        .{ .name = "z", .type = .double },
        .{ .name = "velocity_x", .type = .double },
        .{ .name = "velocity_y", .type = .double },
        .{ .name = "velocity_z", .type = .double },
        .{ .name = "yaw", .type = .float },
        .{ .name = "pitch", .type = .float },
        .{ .name = "flags", .type = .teleport_flags },
    },
});
pub const PlayerInfoAction = enum {
    add_player,
    initialize_chat,
    update_game_mode,
    update_listed,
    update_latency,
    update_display_name,
    update_list_order,
    update_hat,
};
pub const ChatSession = StructuredPacket.getType(.{
    .name = "ChatSession",
    .fields = &.{
        .{ .name = "session_id", .type = .uuid },
        .{ .name = "expires_at", .type = .long },
        .{ .name = "public_key", .type = .byte_array },
        .{ .name = "key_signature", .type = .byte_array },
    },
});
/// A player in `player_info_initialize_s2c`, with every action's data in the actions' order.
pub const player_info_entry = StructuredPacket.getType(.{
    .name = "PlayerInfoEntry",
    .fields = &.{
        // The uuid, then add_player's name and properties, same bytes as a game profile
        .{ .name = "profile", .type = .game_profile },
        // initialize_chat
        .{ .name = "chat_session", .type = .prefixedOptional(ChatSession) },
        // update_game_mode
        .{ .name = "game_mode", .type = .{ .@"enum" = .of(GameMode, .var_int) } },
        // update_listed
        .{ .name = "listed", .type = .bool },
        // update_latency
        .{ .name = "latency", .type = .var_int },
        // update_display_name
        .{ .name = "display_name", .type = .prefixedOptional(.nbt_text_component) },
        // update_list_order
        .{ .name = "list_order", .type = .var_int },
        // update_hat
        .{ .name = "show_hat", .type = .bool },
    },
});
/// Only the form vanilla sends when players join (`createPlayerInitializing`): every action.
pub const player_info_initialize_s2c = StructuredPacket.getType(.{
    .name = "PlayerInfoInitializeS2C",
    .fields = &.{
        // A fixed `java.util.BitSet` of 8 bits, all set
        .{ .name = "actions", .type = .{ .enum_set = .of(PlayerInfoAction, .u8) } },
        .{ .name = "players", .type = .prefixedArray(player_info_entry) },
    },
});
pub const player_info_remove_s2c = PacketType.prefixedArray(.uuid);
pub const set_chunk_cache_center_s2c = StructuredPacket.getType(.{
    .name = "SetChunkCacheCenterS2C",
    .fields = &.{
        .{ .name = "x", .type = .var_int },
        .{ .name = "z", .type = .var_int },
    },
});
pub const chunk_batch_start_s2c = StructuredPacket.named("ChunkBatchStartS2C");
/// How many chunks the batch had.
pub const chunk_batch_finished_s2c = PacketType{ .var_int = {} };
/// Bytes that are written as they are, for what's encoded somewhere else. Takes everything left when read.
const raw_bytes = PacketType{ .custom = .{
    .type = []const u8,
    .readFn = struct {
        fn read(params: PacketType.ReadParams, reader: *std.Io.Reader, _: anytype, out: anytype) PacketType.ReadError!void {
            out.* = reader.allocRemaining(params.arena.allocator(), .unlimited) catch |e| return switch (e) {
                error.StreamTooLong => unreachable,
                else => |err| err,
            };
        }
    }.read,
    .writeFn = struct {
        fn write(_: PacketType.AllocPair, writer: *std.Io.Writer, val: anytype) PacketType.WriteError!void {
            try writer.writeAll(val);
        }
    }.write,
    .default_value_ptr = @ptrCast(&@as([]const u8, &.{})),
} };
pub const level_chunk_with_light_s2c = StructuredPacket.getType(.{
    .name = "LevelChunkWithLightS2C",
    .fields = &.{
        .{ .name = "x", .type = .int },
        .{ .name = "z", .type = .int },
        // Heightmaps, sections, block entities and light: core's `world.chunk_packet`
        .{ .name = "data", .type = raw_bytes },
    },
});
pub const system_chat_s2c = StructuredPacket.getType(.{
    .name = "SystemChatS2C",
    .fields = &.{
        .{ .name = "content", .type = .nbt_text_component },
        .{ .name = "overlay", .type = .bool },
    },
});

pub const accept_teleportation_c2s = StructuredPacket.getType(.{
    .name = "AcceptTeleportationC2S",
    .fields = &.{
        .{ .name = "teleport_id", .type = .var_int },
        .{ .name = "x", .type = .double },
        .{ .name = "y", .type = .double },
        .{ .name = "z", .type = .double },
        .{ .name = "yaw", .type = .float },
        .{ .name = "pitch", .type = .float },
    },
});
pub const chat_c2s = StructuredPacket.getType(.{
    .name = "ChatC2S",
    .fields = &.{
        .{ .name = "message", .type = .limitedString(256) },
        // Milliseconds since the epoch.
        .{ .name = "timestamp", .type = .long },
        .{ .name = "salt", .type = .long },
        .{ .name = "signature", .type = .prefixedOptional(.fixedArray(.ubyte, 256)) },
        .{ .name = "message_count", .type = .var_int },
        // A 20 bits `java.util.BitSet`, little endian.
        .{ .name = "acknowledged", .type = .fixedArray(.ubyte, 3) },
        .{ .name = "checksum", .type = .ibyte },
    },
});
pub const chat_command_c2s = PacketType.max_string;
pub const player_loaded_c2s = StructuredPacket.named("PlayerLoadedC2S");

test "player_position_s2c size" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try player_position_s2c.write(.newWithArena(std.testing.allocator, &arena), &aw.writer, .{
        .teleport_id = 1,
        .x = 0,
        .y = 0,
        .z = 0,
        .velocity_x = 0,
        .velocity_y = 0,
        .velocity_z = 0,
        .yaw = 0,
        .pitch = 0,
        .flags = .initMany(&.{.rel_x}),
    });
    // var int + 6 doubles + 2 floats + the flags as an int, like vanilla's `Relative.SET_STREAM_CODEC`
    try std.testing.expectEqual(1 + 6 * 8 + 2 * 4 + 4, aw.written().len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1 }, aw.written()[aw.written().len - 4 ..]);
}

test "player_info_initialize_s2c size" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var players = [_]player_info_entry.getZigType(){.{
        .profile = try .validate("sioworker", .{ .value = 0 }),
        .chat_session = null,
        .game_mode = .spectator,
        .listed = true,
        .latency = 0,
        .display_name = null,
        .list_order = 0,
        .show_hat = true,
    }};
    try player_info_initialize_s2c.write(.newWithArena(std.testing.allocator, &arena), &aw.writer, .{
        .actions = .full,
        .players = &players,
    });
    const written = aw.written();
    // actions, player count, uuid, name, properties, then 1 byte for each other action
    try std.testing.expectEqual(1 + 1 + 16 + (1 + "sioworker".len) + 1 + 7, written.len);
    try std.testing.expectEqual(0xFF, written[0]);
    // update_game_mode comes right after the empty properties and the absent chat session
    try std.testing.expectEqual(3, written[1 + 1 + 16 + 10 + 1 + 1]);
}
