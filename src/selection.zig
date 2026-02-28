const std = @import("std");
const edit = @import("editor.zig");
const ecs = @import("ecs.zig");
const GroupId = ecs.Groups.GroupId;
const EventCtx = @import("app.zig").EventCtx;
const Id = edit.EcsT.Id;

const Self = @This();
const Mode = enum {
    one,
    many,
};

const SelectionList = struct {
    alloc: std.mem.Allocator,

    /// parallel
    ids: std.ArrayListUnmanaged(Id) = .{},
    groups: std.ArrayListUnmanaged(GroupId) = .{},

    //map id -> index
    idmap: std.AutoHashMapUnmanaged(Id, usize) = .{},
    // map group -> count
    groupmap: std.AutoHashMapUnmanaged(GroupId, usize) = .{},

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *@This()) void {
        self.ids.deinit(self.alloc);
        self.groups.deinit(self.alloc);
        self.idmap.deinit(self.alloc);
        self.groupmap.deinit(self.alloc);
    }

    fn clear(self: *@This()) void {
        self.ids.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.idmap.clearRetainingCapacity();
        self.groupmap.clearRetainingCapacity();
    }

    fn add(self: *@This(), id: Id, group: GroupId) !void {
        if (self.idmap.get(id)) |index| {
            if (index < self.groups.items.len) {
                const old_group = self.groups.items[index];
                if (old_group != group) {
                    self.groups.items[index] = group;
                    self.decrementGroup(old_group);
                    try self.incrementGroup(group);
                }
            }
        } else {
            const index = self.ids.items.len;
            try self.idmap.put(self.alloc, id, index);
            try self.ids.append(self.alloc, id);
            try self.groups.append(self.alloc, group);
            try self.incrementGroup(group);
        }
    }

    fn updateGroup(self: *@This(), id: Id, group: GroupId) !void {
        if (self.idmap.get(id)) |index| {
            if (index < self.groups.items.len) {
                const old_group = self.groups.items[index];
                if (old_group != group) {
                    self.groups.items[index] = group;
                    self.decrementGroup(old_group);
                    try self.incrementGroup(group);
                }
            }
        }
    }

    pub fn remove(self: *@This(), id: Id) !void {
        if (self.idmap.get(id)) |index| {
            _ = self.idmap.remove(id);
            const is_last = index == self.ids.items.len - 1;
            _ = self.ids.swapRemove(index);
            const group = self.groups.swapRemove(index);

            if (!is_last) {
                try self.idmap.put(self.alloc, self.ids.items[index], index);
            }

            self.decrementGroup(group);
        }
    }

    pub fn addOrRemove(self: *@This(), id: Id, group: GroupId) !PutResult {
        if (self.idmap.contains(id)) {
            try self.remove(id);
            return .{ .res = .removed, .group = group };
        } else {
            try self.add(id, group);
            return .{ .res = .added, .group = group };
        }
    }

    fn decrementGroup(self: *@This(), group: GroupId) void {
        if (self.groupmap.getPtr(group)) |group_count| {
            if (group_count.* == 1) {
                _ = self.groupmap.remove(group);
            } else {
                group_count.* -= 1;
            }
        }
    }

    fn incrementGroup(self: *@This(), group: GroupId) !void {
        const res = try self.groupmap.getOrPut(self.alloc, group);
        if (res.found_existing) {
            res.value_ptr.* += 1;
        } else {
            res.value_ptr.* = 1;
        }
    }

    pub fn removeGroup(self: *@This(), group: GroupId) !void {
        var to_remove = std.ArrayListUnmanaged(Id){};
        defer to_remove.deinit(self.alloc);

        for (self.groups.items, 0..) |g, i| {
            if (g == group)
                try to_remove.append(self.alloc, self.ids.items[i]);
        }
        for (to_remove.items) |to| {
            try self.remove(to);
        }
    }

    pub fn count(self: *const @This()) usize {
        return self.ids.items.len;
    }

    fn countGroup(self: *const @This()) usize {
        return self.groupmap.count();
    }

    fn getLast(self: *const @This()) ?Id {
        if (self.ids.items.len > 0)
            return self.ids.items[self.ids.items.len - 1];
        return null;
    }

    fn getGroup(self: *const @This(), id: Id) ?GroupId {
        if (self.idmap.get(id)) |index| {
            return self.groups.items[index];
        }
        return null;
    }

    pub fn contains(self: *const @This(), id: Id) bool {
        return self.idmap.contains(id);
    }

    pub fn containsGroup(self: *const @This(), group: GroupId) bool {
        return self.groupmap.contains(group);
    }

    fn hash(self: *const @This()) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, self.ids.items, .Deep);
        std.hash.autoHashStrat(&hasher, self.groups.items, .Deep);
        return hasher.final();
    }
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

_list: SelectionList,

alloc: std.mem.Allocator,

scratch_list: std.ArrayListUnmanaged(Id) = .{},
event_ctx: *EventCtx,
last_selection_hash: u64 = 0,

options: struct {
    brushes: bool = true,
    props: bool = true,
    entity: bool = true,
    func: bool = true,
    disp: bool = true,

    select_nearby: bool = false,
    nearby_distance: f32 = 0.1,
} = .{},

pub fn init(alloc: std.mem.Allocator, event_ctx: *EventCtx) Self {
    return .{
        .alloc = alloc,
        ._list = SelectionList.init(alloc),
        .event_ctx = event_ctx,
    };
}

pub fn deinit(self: *Self) void {
    self._list.deinit();
    self.scratch_list.deinit(self.alloc);
}

pub fn toggle(self: *Self) void {
    self.mode = switch (self.mode) {
        .one => .many,
        .many => .one,
    };
}

//IF groups change ?
//shouldn't be a problem becouse we have a seperate undo item for setting groups.
pub fn createStateSnapshot(self: *Self, alloc: std.mem.Allocator) !StateSnapshot {
    const multi = try alloc.dupe(Id, self._list.ids.items);
    const groups = try alloc.dupe(GroupId, self._list.groups.items);

    return StateSnapshot{
        .mode = self.mode,
        .multi = multi,
        .groups = groups,
    };
}

pub fn setFromSnapshot(self: *Self, snapshot: StateSnapshot) !void {
    if (snapshot.multi.len != snapshot.groups.len) return error.invalidSnapshot;
    self._list.clear();

    for (snapshot.multi, 0..) |m, mi| {
        try self._list.add(m, snapshot.groups[mi]);
    }

    self.mode = snapshot.mode;
    defer self.notifySelectionChanged();
}

pub fn countSelected(self: *Self) usize {
    return self._list.count();
}

// Only return selected if length of selection is 1
pub fn getExclusive(self: *Self) ?Id {
    if (self.countSelected() == 1) {
        return self._list.getLast();
    }
    return null;
}

/// If ignore_groups, don't return group owners
/// Returns either the owner of a selected group if that group is exclusive,
/// or it returns the selection when len == 1
pub fn getGroupOwnerExclusive(self: *Self, groups: *ecs.Groups) ?Id {
    blk: {
        if (self.ignore_groups) break :blk;
        if (self._list.countGroup() != 1) break :blk;

        const last = self._list.getLast() orelse break :blk;
        const lgroup = self._list.getGroup(last) orelse break :blk;
        if (lgroup == 0) break :blk;

        return groups.getOwner(lgroup);
    }
    return self.getExclusive();
}

pub fn setToSingle(self: *Self, id: Id, ed: *edit.Context) !void {
    self.mode = .one;
    self._list.clear();
    try self.add(id, ed);
}

pub fn setToMulti(self: *Self) void {
    self.mode = .many;
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

const PutResult = struct {
    res: enum { masked, added, removed },
    group: GroupId,
};
pub fn put(self: *Self, id: Id, editor: *edit.Context) !PutResult {
    if (!self.canSelect(id, editor)) return .{ .res = .masked, .group = 0 };
    defer self.notifySelectionChanged();
    if (!self.ignore_groups) {
        if (try editor.ecs.getOpt(id, .group)) |group| {
            if (group.id != 0) {
                switch (self.mode) {
                    .one => self._list.clear(),
                    .many => {},
                }
                const to_remove = self._list.contains(id);

                if (to_remove) {
                    try self._list.removeGroup(group.id);
                } else {
                    // Add the group owner ent aswell, not technically a part of group but shouldn't cause issues.
                    // Selecting a func_tracktrain and moving it will move the origin (group owner ent) aswell.
                    if (editor.groups.getOwner(group.id)) |owner| {
                        try self._list.add(owner, group.id);
                    }
                    var it = editor.editIterator(.group);
                    while (it.next()) |ent| {
                        if (ent.id == group.id) {
                            try self._list.add(it.i, ent.id);
                        }
                    }
                }

                return .{ .group = group.id, .res = if (to_remove) .removed else .added };
            }
        }
    }
    const group = if (try editor.ecs.getOpt(id, .group)) |g| g.id else 0;
    switch (self.mode) {
        .one => {
            try self.setToSingle(id, editor);
            return .{ .group = group, .res = .added };
        },
        .many => {
            return try self._list.addOrRemove(id, group);
        },
    }
}

///ensure no hidden entities are selected
pub fn sanitizeSelection(self: *Self, ed: *edit.Context) !void {
    const vis_mask = edit.EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });

    self.scratch_list.clearRetainingCapacity();

    for (self._list.ids.items) |pot| {
        if (ed.ecs.intersects(pot, vis_mask))
            try self.scratch_list.append(self.alloc, pot);
    }

    for (self.scratch_list.items) |to_remove| {
        try self._list.remove(to_remove);
    }

    if (self.scratch_list.items.len > 0)
        self.notifySelectionChanged();
}

pub fn add(self: *Self, id: Id, editor: *edit.Context) !void {
    const group = if (try editor.ecs.getOpt(id, .group)) |g| g.id else 0;
    try self._list.add(id, group);
    self.notifySelectionChanged();
}

pub fn getLast(self: *const Self) ?Id {
    return self._list.getLast();
}

pub fn updateGroup(self: *Self, id: Id, group: GroupId) !void {
    try self._list.updateGroup(id, group);
    self.notifySelectionChanged();
}

pub fn clear(self: *Self) void {
    self._list.clear();
    self.notifySelectionChanged();
}

pub fn countGroup(self: *Self) usize {
    return self._list.countGroup();
}

pub fn getGroup(self: *const Self, id: Id) ?GroupId {
    return self._list.getGroup(id);
}

pub fn addWithGroup(self: *Self, id: Id, group: GroupId) !void {
    try self._list.add(id, group);
    self.notifySelectionChanged();
}

fn notifySelectionChanged(self: *Self) void {
    const last_hash = self.last_selection_hash;
    self.last_selection_hash = self._list.hash();
    if (last_hash != self.last_selection_hash)
        self.event_ctx.pushEvent(.{ .selection_changed = {} });
}
