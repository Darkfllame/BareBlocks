//! Packets callback can be defined here as declarations and will be automatically picked up by the "packets" module.
//! 
//! They follow the following naming: `@"<side>/<phase>/<resource>"`.
//! 
//! - `side` can be `clientbound` or `serverbound`
//! - `phase` can be `handshake`, `status`, `login`, `configuration` or `play`
//! - `resource` is defined in [the minecraft wiki page](https://minecraft.wiki/w/Java_Edition_protocol/Packets)
//!     - If the namespace is **"minecraft:"**, it will be entirely omitted, to maintain shorter names

const Server = @import("Server.zig");

pub const @"serverbound/handshake/intention" = Server.handleHandshake;

pub const @"serverbound/status/status_request" = Server.handleStatus;
pub const @"serverbound/status/ping_request" = Server.handleStatusPing;

pub const @"serverbound/login/hello" = Server.handleLoginHello;
pub const @"serverbound/login/key" = Server.handleLoginKey;
pub const @"serverbound/login/login_acknowledged" = Server.handleLoginAck;