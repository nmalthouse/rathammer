const std = @import("std");
const edit = @import("editor.zig");
const ecs = @import("ecs.zig");
const GroupId = ecs.Groups.GroupId;
const Id = edit.EcsT.Id;

const Self = @This();
const Mode = enum {
    one,
    many,
};

pub const StateSnapshot = struct {
    multi: []const Id,
    groups: []const GroupId,

    mode: Mode,

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.multi);
        alloc.free(self.groups);
    }
};

/// When .one, selecting an entity will clear the current selection
/// When .many, the new selection is xored with the current one
/// Note that in state .one, more than one entity may be selected if ignore groups is false
mode: Mode = .one,
/// Toggling this only effects the behavior of fn put()
ignore_groups: bool = false,

_multi: std.ArrayList(Id),

/// stores set of groups present in current selection.
groups: std.AutoHashMap(GroupId, void),

options: struct {
    brushes: bool = true,
    props: bool = true,
    entity: bool = true,
    func: bool = true,
    disp: bool = true,

    select_nearby: bool = false,
    nearby_distance: f32 = 0.1,
} = .{},

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        ._multi = std.ArrayList(Id).init(alloc),
        .groups = std.AutoHashMap(GroupId, void).init(alloc),
    };
}

pub fn toggle(self: *Self) void {
    self.mode = switch (self.mode) {
        .one => .many,
        .many => .one,
    };
}

pub fn createStateSnapshot(self: *Self, alloc: std.mem.Allocator) !StateSnapshot {
    const group_list = try alloc.alloc(GroupId, self.groups.count());
    var g_it = self.groups.keyIterator();

    var g_i: usize = 0;
    while (g_it.next()) |g| {
        if (g_i >= group_list.len)
            break;

        group_list[g_i] = g.*;

        g_i += 1;
    }
    const multi = try alloc.dupe(Id, self._multi.items);

    return StateSnapshot{
        .mode = self.mode,
        .multi = multi,
        .groups = group_list,
    };
}

pub fn setFromSnapshot(self: *Self, snapshot: StateSnapshot) !void {
    self._multi.clearRetainingCapacity();
    try self._multi.appendSlice(snapshot.multi);

    self.groups.clearRetainingCapacity();
    for (snapshot.groups) |g| {
        try self.groups.put(g, {});
    }
    self.mode = snapshot.mode;
}

pub fn getLast(self: *Self) ?Id {
    return self._multi.getLastOrNull();
}

pub fn countSelected(self: *Self) usize {
    return self._multi.items.len;
}

// Only return selected if length of selection is 1
pub fn getExclusive(self: *Self) ?Id {
    if (self._multi.items.len == 1)
        return self._multi.items[0];
    return null;
}

/// Returns either the owner of a selected group if that group is exclusive,
/// or it returns the selection when len == 1
pub fn getGroupOwnerExclusive(self: *Self, groups: *ecs.Groups) ?Id {
    blk: {
        if (self.groups.count() != 1) break :blk;
        var it = self.groups.keyIterator();
        const first = it.next() orelse break :blk;
        if (first.* == 0) break :blk;

        return groups.getOwner(first.*);
    }
    return self.getExclusive();
}

pub fn setToSingle(self: *Self, id: Id) !void {
    self.mode = .one;
    self.clear();
    try self._multi.append(id);
}

pub fn setToMulti(self: *Self) void {
    self.mode = .many;
}

// Add an id without checking if it exists
pub fn addUnchecked(self: *Self, id: Id) !void {
    try self._multi.append(id);
}

pub fn multiContains(self: *Self, id: Id) bool {
    for (self._multi.items) |item| {
        if (item == id)
            return true;
    }
    return false;
}

pub fn tryRemoveMulti(self: *Self, id: Id) void {
    if (std.mem.indexOfScalar(Id, self._multi.items, id)) |index|
        _ = self._multi.orderedRemove(index);
}

pub fn tryAddMulti(self: *Self, id: Id) !void {
    //TODO no n^2 please, thanks.
    if (std.mem.indexOfScalar(Id, self._multi.items, id)) |_| {
        return;
    }
    try self._multi.append(id);
}

pub fn getSlice(self: *Self) []const Id {
    return self._multi.items;
}

pub fn clear(self: *Self) void {
    self._multi.clearRetainingCapacity();
    self.groups.clearAndFree();
}

pub fn deinit(self: *Self) void {
    self._multi.deinit();
    self.groups.deinit();
}

fn canSelect(self: *Self, id: Id, editor: *edit.Context) bool {
    //IF objects are part of group, check that too
    const any_brush = self.options.brushes and self.options.disp;
    if (!any_brush) {
        if (editor.getComponent(id, .solid)) |_| {
            if (!self.options.brushes) return false;
            if (!self.options.disp and editor.getComponent(id, .displacements) != null) return false;
            if (editor.getComponent(id, .group)) |group| {
                if (editor.groups.getOwner(group.id)) |owner| {
                    //Risk of recursion!
                    return self.canSelect(owner, editor);
                }
            }
        }
    }
    const any_ent = self.options.entity and self.options.props and self.options.func;
    if (!any_ent) {
        if (editor.getComponent(id, .entity)) |ent| {
            if (!self.options.entity) return false;
            if (!self.options.props and std.mem.startsWith(u8, ent.class, "prop")) return false;
            if (!self.options.func and std.mem.startsWith(u8, ent.class, "func")) return false;
        }
    }

    return true;
}

/// Returns true if the item was added
pub fn put(self: *Self, id: Id, editor: *edit.Context) !bool {
    if (!self.canSelect(id, editor)) return false;
    if (!self.ignore_groups) {
        if (try editor.ecs.getOpt(id, .group)) |group| {
            if (group.id != 0) {
                switch (self.mode) {
                    .one => self.clear(),
                    .many => {},
                }
                const to_remove = self.multiContains(id);
                if (to_remove) _ = self.groups.remove(group.id) else try self.groups.put(group.id, {});
                //TODO specify it manually autovis entities should be added
                var it = editor.editIterator(.group);
                while (it.next()) |ent| {
                    if (ent.id == group.id and ent.id != 0) {
                        if (to_remove) self.tryRemoveMulti(it.i) else try self.tryAddMulti(it.i);
                    }
                }
                return true;
            }
        }
    }
    const group = if (try editor.ecs.getOpt(id, .group)) |g| g.id else 0;
    switch (self.mode) {
        .one => {
            try self._multi.resize(1);
            self._multi.items[0] = id;
            self.groups.clearRetainingCapacity();
            try self.groups.put(group, {});
        },
        .many => {
            if (std.mem.indexOfScalar(Id, self._multi.items, id)) |index| {
                _ = self._multi.orderedRemove(index);
                _ = self.groups.remove(group);
            } else {
                try self._multi.append(id);
                try self.groups.put(group, {});
            }
        },
    }
    return true;
}
