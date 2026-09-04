const registry = @This();
const std = @import("std");
const utils = @import("utils");
const registries = @import("registries");

const Allocator = std.mem.Allocator;
const Identifier = utils.Identifier;

pub const max_registry_id = std.math.maxInt(i32);

// pub const RegistryType = registries.

pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.ArrayHashMapUnmanaged(Identifier, T, Identifier.HashCtx, true),

        pub const empty = Self{ .map = .empty };

        pub const AddEntryError = Allocator.Error || error{ DuplicatedEntry, TooManyEntries };

        pub const EntryID = enum(u32) {
            fn isValid(self: EntryID) bool {
                return @intFromEnum(self) <= max_registry_id;
            }

            _,
        };

        pub fn addEntry(self: *Self, allocator: Allocator, key: Identifier, value: T) AddEntryError!EntryID {
            const new_id = self.entry2id.items.len;
            if (new_id > max_registry_id) return error.TooManyEntries;
            const gop = try self.map.getOrPut(allocator, key);
            if (gop.found_existing) return error.DuplicateEntry;
            gop.value_ptr.* = value;
            return @enumFromInt(new_id);
        }

        pub fn getEntry(self: *Self, id: EntryID) *T {
            return &self.map.entries.items(.value)[@intFromEnum(id)];
        }

        pub fn getIdentifier(self: *Self, id: EntryID) Identifier {
            return self.map.entries.items(.key)[@intFromEnum(id)];
        }

        pub fn getEntryId(self: *Self, id: Identifier) EntryID {
            for (self.map.entries.items(.key), 0..) |value, i| {
                if (value.eql(id)) return @enumFromInt(i);
            }
            unreachable; // couldn't find id for Identifier
        }

        pub fn getEntryIdMaybe(self: *Self, id: Identifier) ?EntryID {
            for (self.map.entries.items(.key), 0..) |value, i| {
                if (value.eql(id)) return @enumFromInt(i);
            }
            return null;
        }

        pub fn hasIdentifier(self: *Self, id: Identifier) bool {
            for (self.map.entries.items(.key)) |value| {
                if (value.eql(id)) return true;
            }
            return false;
        }
    };
}
