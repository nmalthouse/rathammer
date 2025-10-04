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

    pub fn clear(self: *@This()) void {
        self.ids.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.idmap.clearRetainingCapacity();
        self.groupmap.clearRetainingCapacity();
    }

    pub fn add(self: *@This(), id: Id, group: GroupId) !void {
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

    pub fn updateGroup(self: *@This(), id: Id, group: GroupId) !void {
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

    pub fn countGroup(self: *const @This()) usize {
        return self.groupmap.count();
    }

    pub fn getLast(self: *const @This()) ?Id {
        if (self.ids.items.len > 0)
            return self.ids.items[self.ids.items.len - 1];
        return null;
    }

    pub fn getGroup(self: *const @This(), id: Id) ?GroupId {
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

list: SelectionList,

alloc: std.mem.Allocator,

scratch_list: std.ArrayListUnmanaged(Id) = .{},

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
        .alloc = alloc,
        .list = SelectionList.init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    self.list.deinit();
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
    const multi = try alloc.dupe(Id, self.list.ids.items);
    const groups = try alloc.dupe(GroupId, self.list.groups.items);

    return StateSnapshot{
        .mode = self.mode,
        .multi = multi,
        .groups = groups,
    };
}

pub fn setFromSnapshot(self: *Self, snapshot: StateSnapshot) !void {
    if (snapshot.multi.len != snapshot.groups.len) return error.invalidSnapshot;
    self.list.clear();

    for (snapshot.multi, 0..) |m, mi| {
        try self.list.add(m, snapshot.groups[mi]);
    }

    self.mode = snapshot.mode;
}

pub fn countSelected(self: *Self) usize {
    return self.list.count();
}

// Only return selected if length of selection is 1
pub fn getExclusive(self: *Self) ?Id {
    if (self.countSelected() == 1) {
        return self.list.getLast();
    }
    return null;
}

/// Returns either the owner of a selected group if that group is exclusive,
/// or it returns the selection when len == 1
pub fn getGroupOwnerExclusive(self: *Self, groups: *ecs.Groups) ?Id {
    blk: {
        if (self.list.countGroup() != 1) break :blk;

        const last = self.list.getLast() orelse break :blk;
        const lgroup = self.list.getGroup(last) orelse break :blk;
        if (lgroup == 0) break :blk;

        return groups.getOwner(lgroup);
    }
    return self.getExclusive();
}

pub fn setToSingle(self: *Self, id: Id, ed: *edit.Context) !void {
    self.mode = .one;
    self.list.clear();
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
    if (!self.ignore_groups) {
        if (try editor.ecs.getOpt(id, .group)) |group| {
            if (group.id != 0) {
                switch (self.mode) {
                    .one => self.list.clear(),
                    .many => {},
                }
                const to_remove = self.list.contains(id);

                if (to_remove) {
                    try self.list.removeGroup(group.id);
                } else {
                    // Add the group owner ent aswell, not technically a part of group but shouldn't cause issues.
                    // Selecting a func_tracktrain and moving it will move the origin (group owner ent) aswell.
                    if (editor.groups.getOwner(group.id)) |owner| {
                        try self.list.add(owner, group.id);
                    }
                    var it = editor.editIterator(.group);
                    while (it.next()) |ent| {
                        if (ent.id == group.id) {
                            try self.list.add(it.i, ent.id);
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
            return try self.list.addOrRemove(id, group);
        },
    }
}

///ensure no hidden entities are selected
pub fn sanitizeSelection(self: *Self, ed: *edit.Context) !void {
    const vis_mask = edit.EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });

    self.scratch_list.clearRetainingCapacity();

    for (self.list.ids.items) |pot| {
        if (ed.ecs.intersects(pot, vis_mask))
            try self.scratch_list.append(self.alloc, pot);
    }

    for (self.scratch_list.items) |to_remove| {
        try self.list.remove(to_remove);
    }
}

pub fn add(self: *Self, id: Id, editor: *edit.Context) !void {
    const group = if (try editor.ecs.getOpt(id, .group)) |g| g.id else 0;
    try self.list.add(id, group);
}
