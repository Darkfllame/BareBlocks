const std = @import("std");

const value_providers = @import("value_providers.zig");

pub const IntProvider = value_providers.IntProvider;
pub const FloatProvider = value_providers.FloatProvider;

pub const logger = std.log.scoped(.bare_blocks);