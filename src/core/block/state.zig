const std = @import("std");
const Block = @import("Block.zig");
const core = @import("../core.zig");
const RefCount = core.RefCount;

const Allocator = std.mem.Allocator;
const Io = std.Io;

// TODO: Block states in vanilla are all pre-computed at startup.
// TODO: Figure out a way to do lazy-loading on them. Some cache structure might be required. (weak refs inside the cache)
// NOTE: the 'neighbours' field into net.minecraft.world.level.block.state.StateHolder contains these
// NOTE: pre-loaded states. So "setting" a property just results in taking a different state from these.
// NOTE: They are addressed as neighbours[propertyIndex][valueIndex].

pub const PropertiesData = opaque {};

pub const State = struct {
    const dummy_vtable = State.VTable{
        .equal = dummyEqual,
        .free = dummyFree,
    };

    fn dummyEqual(a: *const State, b: *const State) bool {
        _ = a;
        _ = b;
        return false;
    }

    fn dummyFree(state: *State, gpa: Allocator) void {
        _ = state;
        _ = gpa;
    }

    /// Each block gets a unique block ID. That's it.
    state_id: Block.Id,
    vtable: *const State.VTable,
    owner: *Block,

    // Fields below can mutate between calls

    ref_count: RefCount,
    /// A shared lock. Zig's implementation should have a fair locking strategy.
    ///
    /// Basically shared locks will wait for blocking locks, and blocking locks will wait for
    /// shared locks.
    ///
    /// Shouldn't starve writers.
    rw: Io.RwLock,

    pub const VTable = struct {
        /// - If `a` and `b` are the same pointer, this function will not get called and `eql` will return `true`.
        /// - If they have different `state_id`, this function will not get called and `eql` will return `false`.
        equal: *const fn (a: *const State, b: *const State) bool,
        /// Gets called once the `ref_count` reaches `0`.
        free: *const fn (self: *State, gpa: Allocator) void,
    };

    pub inline fn dummyIota(comptime N: u32, comptime start: u32) [N]State {
        comptime {
            @setEvalBranchQuota(N);

            var arr: [N]State = @splat(.{
                .ref_count = .{},
                .state_id = undefined,
                .vtable = &dummy_vtable,
            });
            for (0..N) |i| {
                arr[i].state_id = @fromBackingInt(@intCast(start + i));
            }
            return arr;
        }
    }

    pub fn dummy(id: Block.Id) State {
        return dummyIota(1, @backingInt(id))[0];
    }

    /// Should be called when a thread pass the point
    pub noinline fn acquire(self: *State) *State {
        self.ref_count.acquireExtra(@returnAddress());
        return self;
    }

    pub fn release(self: *State, allocator: Allocator) void {
        if (self.ref_count.release()) {
            self.vtable.free(self, allocator);
        }
    }

    /// Does not acquire `self` or `other`.
    pub fn eql(self: *State, other: *State) bool {
        if (self == other) return true;
        if (self.state_id != other.state_id) return false;

        return self.vtable.equal(self, other);
    }
};

pub const Property = struct {
    name: []const u8,
    vtable: *const VTable,
    size: usize,
    alignment: std.mem.Alignment,

    pub const VTable = struct {
        
    };
};