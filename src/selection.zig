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
    last: ?Id,

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

_multi: std.AutoHashMap(Id, void),
last_selected: ?Id = null,

/// stores set of groups present in current selection.
groups: std.AutoHashMap(GroupId, void),

alloc: std.mem.Allocator,
_multi_slice_scratch: std.ArrayListUnmanaged(Id) = .{},

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
        ._multi = std.AutoHashMap(Id, void).init(alloc),
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
    const group_list = try getHashSetSlice(GroupId, &self.groups, alloc);
    const multi = try getHashSetSlice(Id, &self._multi, alloc);
    return StateSnapshot{
        .mode = self.mode,
        .multi = multi,
        .groups = group_list,
        .last = self.last_selected,
    };
}

pub fn setFromSnapshot(self: *Self, snapshot: StateSnapshot) !void {
    self._multi.clearRetainingCapacity();
    for (snapshot.multi) |m|
        try self._multi.put(m, {});

    self.groups.clearRetainingCapacity();
    for (snapshot.groups) |g|
        try self.groups.put(g, {});

    self.mode = snapshot.mode;
}

pub fn getLast(self: *Self) ?Id {
    return self.last_selected;
}

pub fn countSelected(self: *Self) usize {
    return self._multi.count();
}

// Only return selected if length of selection is 1
pub fn getExclusive(self: *Self) ?Id {
    if (self.countSelected() == 1) {
        var it = self._multi.keyIterator();
        const n = it.next() orelse return null;
        return n.*;
    }
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
    try self._multi.put(id, {});
    self.last_selected = id;
}

pub fn setToMulti(self: *Self) void {
    self.mode = .many;
}

// Add an id without checking if it exists
pub fn addUnchecked(self: *Self, id: Id) !void {
    try self._multi.put(id, {});
    self.last_selected = id;
}

pub fn multiContains(self: *Self, id: Id) bool {
    return self._multi.contains(id);
}

pub fn tryRemoveMulti(self: *Self, id: Id) void {
    if (self._multi.remove(id)) {
        if (self.last_selected) |ls| {
            if (ls == id)
                self.last_selected = null;
        }
    }
}

pub fn tryAddMulti(self: *Self, id: Id) !void {
    if (self.multiContains(id)) return;

    try self.addUnchecked(id);
}

pub fn clear(self: *Self) void {
    self._multi.clearRetainingCapacity();
    self.groups.clearAndFree();
    self.last_selected = null;
}

pub fn deinit(self: *Self) void {
    self._multi.deinit();
    self.groups.deinit();
    self._multi_slice_scratch.deinit(self.alloc);
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
            try self.setToSingle(id);
            self.groups.clearRetainingCapacity();
            try self.groups.put(group, {});
        },
        .many => {
            if (self._multi.remove(id)) {
                if (self.last_selected != null and self.last_selected.? == id) self.last_selected = null;
                _ = self.groups.remove(group); //TODO only remove group if all are of group are gone?
            } else {
                try self.addUnchecked(id);
                try self.groups.put(group, {});
            }
        },
    }
    return true;
}

fn getHashSetSlice(comptime KeyT: type, hs: *std.AutoHashMap(KeyT, void), alloc: std.mem.Allocator) ![]const KeyT {
    const list = try alloc.alloc(KeyT, hs.count());
    var g_it = hs.keyIterator();

    var g_i: usize = 0;
    while (g_it.next()) |g| {
        if (g_i >= list.len)
            break;

        list[g_i] = g.*;

        g_i += 1;
    }

    return list;
}
