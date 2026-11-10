const std = @import("std");

const assert = std.debug.assert;

const all_hooks: std.StaticStringMap([]const Hook) = blk: {
    @setEvalBranchQuota(std.math.maxInt(u32)); // needing this is so stupid

    const InitElem = struct { []const u8, []const Hook };

    const decls = @typeInfo(hooks_providers).@"struct".decl_names;
    var kvs: []InitElem = &.{};
    for (decls) |dname| {
        const provider = @field(hooks_providers, dname);
        const hooklist = if (@hasDecl(provider, "module_hooks")) provider.module_hooks else continue;
        hook_listing: for (hooklist) |_hook| {
            for (kvs) |*entry| {
                if (std.mem.eql(u8, _hook.name, entry[0])) {
                    var elems = entry.@"1".* ++ [_]Hook{_hook};
                    std.mem.sortUnstable(Hook, &elems, {}, Priority.hookLessThan);
                    const elems_constant = elems; // must copy elements to static buffer otherwise the compiler complains like a whinny bitch
                    entry.@"1" = &elems_constant;
                    continue :hook_listing;
                }
            }
            var new_elems = kvs.* ++ [_]InitElem{.{ _hook.name, (&_hook)[0..1] }};
            kvs = &new_elems;
        }
    }

    break :blk .initComptime(kvs);
};

fn splitHooks(comptime arr: []const Hook) struct { []const Hook, []const Hook } {
    comptime {
        for (arr, 0..) |hk, i| {
            if (hk.priority.isInBase(.monitor)) return .{ arr[0..i], arr[i..] };
        }
        return .{ arr, arr[0..0] };
    }
}

pub const hooks_providers = @import("hooks_providers");

pub fn HookResult(comptime T: type) type {
    return union(enum) {
        early_return: T,
        canceled,
        finished,

        pub fn earlyReturn(value: T) @This() {
            return .{ .early_return = value };
        }
    };
}

/// Represent an order of priority for hooks to get called in.
///
/// A higher backing value means it will execute sooner.
///
/// Hooks with the same level of priority may or may not execute in a fixed order between
/// compilations.
pub const Priority = enum(u32) {
    fn hookLessThan(_: void, lhs: Hook, rhs: Hook) bool {
        lhs.priority.assertInRange();
        rhs.priority.assertInRange();
        return @backingInt(lhs.priority) > @backingInt(rhs.priority);
    }

    fn assertInRange(self: Priority) void {
        assert(@backingInt(self) <= @backingInt(Priority.max));
    }

    /// Maximum value of priority. Any hook must not exceed this level of priority.
    max = base_multiple * 6 - 1,

    /// Highest hook priority, runs first as a way to setup further hook calls.
    highest = base_multiple * 5,
    /// High hook priority, will be run just after highest priority hooks.
    high = base_multiple * 4,
    /// Regular hook priority.
    normal = base_multiple * 3,
    /// Low priority hook.
    low = base_multiple * 2,
    /// Lowest priority hook, called in last just before monitor hooks.
    lowest = base_multiple * 1,
    /// Prefer using `Hook.monitor` instead of using this value raw. Monitors shouldn't cancel, make
    /// a function return early or modify mutable pointers, so having a specific priority between them is pointless.
    monitor = base_multiple * 0,
    _,

    pub const SubOffset = u24;
    pub const base_multiple = 1 << @bitSizeOf(SubOffset);
    pub const base_mask = ~@as(@typeInfo(Priority).@"enum".tag_type, std.math.maxInt(SubOffset));

    /// Hooks with the new priority will execute before hooks with `base` priority.
    ///
    /// Asserts that the resulting priority doesn't go ouside the base priority
    /// category or outside the priority range `(0-Priority.max)`.
    pub fn derive(base: Priority, offset: SubOffset) Priority {
        const base_int = @backingInt(base);
        assert(base_int <= (@backingInt(Priority.max) - offset));
        if (offset == 0) return base;

        const new_suboffset = @as(SubOffset, @truncate(base_int)) + offset;
        return @fromBackingInt((base_int & base_mask) | new_suboffset);
    }

    pub fn isInBase(self: Priority, base: Priority) bool {
        self.assertInRange();
        base.assertInRange();
        return (@backingInt(self) & base_mask) == (@backingInt(base) & base_mask);
    }
};

pub const Hook = struct {
    // TODO: Check function signature
    fn getFnData(func: anytype) struct { type, *const anyopaque } {
        return .{ @TypeOf(func.*), func };
    }

    inline fn call(self: Hook, comptime RetType: type, ctx: *HookContext, args: anytype) HookResult(RetType) {
        return @call(.auto, @as(*const self.fn_type, @ptrCast(@alignCast(self.fn_ptr))).*, .{ctx} ++ args);
    }

    inline fn monitorCall(self: Hook, comptime RetType: type, hkres: HookResult(RetType), args: anytype) void {
        return @call(.auto, @as(*const self.fn_type, @ptrCast(@alignCast(self.fn_ptr))).*, .{hkres} ++ args);
    }

    name: []const u8,
    fn_type: type,
    fn_ptr: *const anyopaque,
    priority: Priority,

    pub fn simple(name: []const u8, func: anytype) Hook {
        const FnT, const ptr = getFnData(func);
        return .{
            .name = name,
            .fn_type = FnT,
            .fn_ptr = ptr,
            .priority = .normal,
        };
    }

    pub fn monitor(name: []const u8, func: anytype) Hook {
        const FnT, const ptr = getFnData(func);
        return .{
            .name = name,
            .fn_type = FnT,
            .fn_ptr = ptr,
            .priority = .monitor,
        };
    }

    pub fn prioritized(name: []const u8, priority: Priority, func: anytype) Hook {
        priority.assertInRange();
        assert(!priority.isInBase(.monitor));
        const FnT, const ptr = getFnData(func);
        return .{
            .name = name,
            .fn_type = FnT,
            .fn_ptr = ptr,
            .priority = priority,
        };
    }
};

// TODO: Maybe add userdata pointer ?
pub const HookContext = struct {
    current_priority: Priority = .highest,
};

pub inline fn hook(comptime name: []const u8, comptime RetType: type, args: anytype) HookResult(RetType) {
    const hooks, const monitors = comptime splitHooks(all_hooks.get(name) orelse return .finished);

    var ctx = HookContext{};

    inline for (hooks) |hk| {
        ctx.current_priority = hk.priority;
        const hkres = hk.call(RetType, &ctx, args);
        switch (hkres) {
            .early_return => |retv| {
                ctx.value = retv;
                inline for (monitors) |mhk| {
                    mhk.monitorCall(RetType, hkres, args);
                }
                return hkres;
            },
            .canceled => {
                ctx.canceled = true;
                break;
            },
            .finished => continue,
        }
    }
    const no_force_return: HookResult(RetType) = if (ctx.canceled) .canceled else .finished;
    inline for (monitors) |mhk| {
        mhk.monitorCall(RetType, no_force_return, args);
    }

    return no_force_return;
}

test {
    std.testing.refAllDecls(@This());
}
