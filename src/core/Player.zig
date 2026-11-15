const Player = @This();
const std = @import("std");
const utils = @import("utils");
const core = @import("core.zig");

const Server = core.Server;

conn: Server.PlayConnection,

pub fn getOwned(self: *const Player) *Server.OwnedConnection {
    return self.conn.owned;
}

pub fn getOwner(self: *const Player) *Server {
    return self.getOwned().owner;
}

pub fn getGameProfile(self: *const Player) utils.GameProfile {
    return self.conn.profile;
}