const std = @import("std");

pub const Keybind = enum {
    unknown,

    jump,
    sneak,
    sprint,
    left,
    right,
    back,
    forward,

    advancements,
    quickActions,
    screenshot,
    smoothCamera,
    fullscreen,
    toggleGui,
    togglePerspectie,
    toggleSpectatorShaderEffects,

    playerList,
    chat,
    command,
    socialInteractions,

    attack,
    pickItem,
    use,

    drop,
    hotbar1,
    hotbar2,
    hotbar3,
    hotbar4,
    hotbar5,
    hotbar6,
    hotbar7,
    hotbar8,
    hotbar9,
    inventory,
    swapOffhand,

    loadToolbarActivator,
    saveToolbarActivator,

    spectatorOutlines,
    spectatorHotbar,

    @"debug.overlay",
    @"debug.modifier",
    @"debug.clearChat",
    @"debug.copyRecreateCommand",
    @"debug.copyLocation",
    @"debug.spectate",
    @"debug.crash",
    @"debug.debugOptions",
    @"debug.dumpDynamicTextures",
    @"debug.dumpVersion",
    @"debug.switchGameMode",
    @"debug.reloadChunk",
    @"debug.reloadResourcePacks",
    @"debug.showAdvancedTooltips",
    @"debug.showDebugBorders",
    @"debug.showHitboxes",
    @"debug.profiling",
    @"debug.focusPause",
    @"debug.profilingChart",
    @"debug.fpsChart",
    @"debug.networkCharts",

    pub const max_formatted_len = blk: {
        var max: usize = 0;
        for (@typeInfo(Keybind).@"enum".fields) |f| {
            max = @max(max, f.name.len);
        }
        break :blk max;
    };
};

test {
    _ = Keybind;
}
