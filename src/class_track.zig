const std = @import("std");
const ecs = @import("ecs.zig");
const Id = ecs.EcsT.Id;

//Map ent class's to entity id's
pub const Tracker = struct {
    const Self = @This();
    const List = std.ArrayListUnmanaged(Id);
    const MapT = std.StringHashMap(List);

    alloc: std.mem.Allocator,
    map: MapT,

    get_buf: std.ArrayList(Id),

    // All keys into map are not managed, must live forever
    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .alloc = alloc, .map = MapT.init(alloc), .get_buf = .{} };
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.iterator();

        self.get_buf.deinit(self.alloc);
        while (it.next()) |item| {
            item.value_ptr.deinit(self.alloc);
        }
        self.map.deinit();
    }

    pub fn put(self: *Self, class: []const u8, id: Id) !void {
        var res = try self.map.getOrPut(class);
        if (!res.found_existing) {
            res.value_ptr.* = .{};
        }
        for (res.value_ptr.items) |item| {
            if (item == id)
                return;
        }
        try res.value_ptr.append(self.alloc, id);
    }

    pub fn remove(self: *Self, class: []const u8, id: Id) void {
        if (self.map.getPtr(class)) |list| {
            for (list.items, 0..) |item, i| {
                if (item == id) {
                    _ = list.swapRemove(i);
                    return;
                }
            }
        }
    }

    pub fn change(self: *Self, new: []const u8, old: []const u8, id: Id) !void {
        self.remove(old, id);
        try self.put(new, id);
    }

    /// Becomes invalid if any are added or removed
    pub fn get(self: *Self, class: []const u8, ecs_p: *ecs.EcsT) ![]const Id {
        self.get_buf.clearRetainingCapacity();
        const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .deleted });
        if (self.map.get(class)) |list| {
            for (list.items) |id| {
                if (!ecs_p.intersects(id, vis_mask))
                    try self.get_buf.append(self.alloc, id);
            }
        }

        return self.get_buf.items;
    }

    // get the last one, so user can determine order
    // With multiple light_environment, user sets class of the one they want in the box
    pub fn getLast(self: *Self, class: []const u8, ecs_p: *ecs.EcsT) ?Id {
        const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .deleted });
        if (self.map.get(class)) |list| {
            var index = list.items.len;
            while (index > 0) : (index -= 1) {
                const id = list.items[index - 1];
                if (!ecs_p.intersects(id, vis_mask))
                    return id;
            }
        }
        return null;
    }

    pub fn getFirstDeprecate(self: *Self, class: []const u8) ?Id {
        if (self.map.get(class)) |list| {
            if (list.items.len > 0)
                return list.items[0];
        }
        return null;
    }
};
