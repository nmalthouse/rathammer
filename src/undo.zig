const std = @import("std");
const edit = @import("editor.zig");
const Editor = edit.Context;
const Id = edit.EcsT.Id;
const graph = @import("graph");
const vpk = @import("vpk.zig");
const Vec3 = graph.za.Vec3;
const ecs = @import("ecs.zig");
const util3d = @import("util_3d.zig");
const Lay = @import("layer.zig");
const LayerId = Lay.Id;

//Stack based undo,
//we push operations onto the stack.
//undo calls undo on stack pointer and increments
//redo calls redo on stack poniter and decrements
//push clear anything after the stack pointer

// IDEA
// mark dependancy relationships between undo items
// SelectionUndo has no dependents, thus, can be removed from stack without side effects
//
// Texture manip is only dependant on its ids CreateDestroy
// Translate is dependant on Translate and CreateDestroy
//
//  each undo item is given unique id
// function findPreviousDependant

pub const UndoGroup = struct {
    description: []const u8,
    items: std.ArrayListUnmanaged(UndoAmal),

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.description);
        for (self.items.items) |*vt|
            vt.deinit(alloc);
        self.items.deinit(alloc);
    }
};

/// Helper struct for creating a group of undo items
/// append() your undo
/// call apply()
pub const GroupBuilder = struct {
    items: *std.ArrayListUnmanaged(UndoAmal),
    ctx: *UndoContext,
    alloc: std.mem.Allocator,

    pub fn append(self: *const @This(), item: tt.UnionT) !void {
        var complete = UndoAmal{
            .d = item,
            .undo_id = self.ctx.getId(),
            .dep = 0,
        };
        //If slowdowns become an issue (n^2), stick dep_id in a hash_map
        if (complete.depId()) |dep_id| {
            // search through undo stack for one with matching id
            var found: u64 = 0; //0 indicates no dep

            var i: usize = self.ctx.stack.items.len;
            outer: while (i > 0) : (i -= 1) {
                const g = self.ctx.stack.items[i - 1];
                for (g.items.items) |substack| {
                    if (substack.depId()) |did| {
                        if (did == dep_id) {
                            found = substack.undo_id;
                            break :outer;
                        }
                    }
                }
            }
            complete.dep = found;
        }

        try self.items.append(self.ctx.alloc, complete);
    }

    pub fn apply(self: *const @This(), ed: *Editor) void {
        applyRedo(self.items.items, ed);
    }
};

pub const PushOpts = struct {
    /// A soft change doesn't increment delta_counter.
    /// Clearing the selection is a soft change.
    soft_change: bool = false,
};

pub const UndoContext = struct {
    const Self = @This();

    stack: std.ArrayList(UndoGroup),
    stack_pointer: usize,

    alloc: std.mem.Allocator,

    delta_counter: u64 = 0,
    last_delta_timestamp: i64 = 0,

    item_counter: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .stack_pointer = 0,
            .stack = .{},
            .alloc = alloc,
        };
    }

    fn getId(self: *Self) u64 {
        self.item_counter += 1;
        return self.item_counter;
    }

    pub fn markDelta(self: *Self) void {
        if (self.delta_counter == std.math.maxInt(@TypeOf(self.delta_counter))) {
            self.delta_counter = 0;
        }
        self.delta_counter += 1;
        self.last_delta_timestamp = std.time.timestamp();
    }

    /// The returned array list should be treated as a stack.
    /// Each call to UndoContext.undo/redo will apply all the items in the arraylist at index stack_pointer.
    /// That is, the last item appended is the first item undone and the last redone.
    pub fn pushNew(self: *Self) !GroupBuilder {
        return try self.pushNewFmt("GenericUndo", .{});
    }

    pub fn pushNewFmt(self: *Self, comptime fmt: []const u8, args: anytype) !GroupBuilder {
        return self.pushNewFmtOpts(fmt, args, .{});
    }

    pub fn pushNewFmtOpts(self: *Self, comptime fmt: []const u8, args: anytype, opts: PushOpts) !GroupBuilder {
        var desc: std.ArrayList(u8) = .{};
        try desc.print(self.alloc, fmt, args);
        if (self.stack_pointer > self.stack.items.len)
            self.stack_pointer = self.stack.items.len; // Sanity

        for (self.stack.items[self.stack_pointer..]) |*item| {
            item.deinit(self.alloc);
        }
        try self.stack.resize(self.alloc, self.stack_pointer); //Discard any
        self.stack_pointer += 1;
        const new_group = UndoGroup{
            .items = .{},
            .description = try desc.toOwnedSlice(self.alloc),
        };
        try self.stack.append(self.alloc, new_group);
        if (!opts.soft_change)
            self.markDelta();
        return .{ .items = &self.stack.items[self.stack.items.len - 1].items, .ctx = self, .alloc = self.alloc };
    }

    pub fn undo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer > self.stack.items.len or self.stack_pointer == 0) //What
            return;
        self.stack_pointer -= 1;
        const ar = self.stack.items[self.stack_pointer];
        var i = ar.items.items.len;
        while (i > 0) : (i -= 1) {
            ar.items.items[i - 1].undo(editor);
        }
        editor.notify("undo: {s}", .{ar.description}, 0xFF8C00ff) catch return;
        self.markDelta();
    }

    pub fn redo(self: *Self, editor: *Editor) void {
        if (self.stack_pointer >= self.stack.items.len) return; //What to do?
        defer self.stack_pointer += 1;

        const th = self.stack.items[self.stack_pointer];
        applyRedo(th.items.items, editor);
        editor.notify("redo: {s}", .{th.description}, 0x8FBC_8F_ff) catch return;
        self.markDelta();
    }

    pub fn deinit(self: *Self) void {
        for (self.stack.items) |*item| {
            item.deinit(self.alloc);
        }
        self.stack.deinit(self.alloc);
    }

    pub fn writeToJson(self: *Self, writer: anytype) !void {
        try std.json.stringify(self.stack.items, .{}, writer);
    }
};
///Rather than manually applying the operations when pushing a undo item,
///just call applyRedo on the stack you created.
pub fn applyRedo(list: []const UndoAmal, editor: *Editor) void {
    for (list) |item|
        item.redo(editor);
}

pub const SelectionUndo = struct {
    const selection = @import("selection.zig");
    const StateSnapshot = selection.StateSnapshot;

    old: StateSnapshot,
    new: StateSnapshot,

    /// Assumes snapshots are allocated by 'alloc', takes memory ownership of snapshots
    pub fn create(alloc: std.mem.Allocator, old: StateSnapshot, new: StateSnapshot) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        editor.selection.setFromSnapshot(self.old) catch {};
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        editor.selection.setFromSnapshot(self.new) catch {};
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.old.destroy(alloc);
        self.new.destroy(alloc);

        alloc.destroy(self);
    }

    pub fn depId(_: *const @This()) ?Id {
        return null;
    }
};

pub const UndoTranslate = struct {
    const Quat = graph.za.Quat;

    vec: Vec3,
    angle_delta: ?Vec3,
    rot_origin: Vec3,
    id: Id,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, vec: Vec3, angle_delta: ?Vec3, id: Id, rot_origin: Vec3) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .vec = vec,
            .angle_delta = angle_delta,
            .rot_origin = rot_origin,
            .id = id,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        applyTransRot(editor, self.id, self.vec, self.angle_delta, self.rot_origin, -1);
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        applyTransRot(editor, self.id, self.vec, self.angle_delta, self.rot_origin, 1);
    }

    pub fn applyTransRot(editor: *Editor, id: Id, trans: Vec3, angle_delta: ?Vec3, origin: Vec3, scale: f32) void {
        const quat = if (angle_delta) |ad| util3d.extEulerToQuat(ad.scale(scale)) else null;
        if (editor.ecs.getOptPtr(id, .solid) catch return) |solid| {
            solid.translate(id, trans.scale(scale), editor, origin, quat) catch return;
        }
        if (editor.ecs.getOptPtr(id, .entity) catch return) |ent| {
            ent.setOrigin(editor, id, ent.origin.add(trans.scale(scale))) catch return;
            if (angle_delta) |angd| {
                ent.setAngle(editor, id, ent.angle.add(angd.scale(scale))) catch return;

                if (quat) |qq| {
                    const pos_v = ent.origin.sub(origin);
                    const new_o = qq.rotateVec(pos_v).add(origin);
                    ent.setOrigin(editor, id, new_o) catch return;
                }
            }
        }
        if (editor.ecs.getOptPtr(id, .displacements) catch return) |disps| {
            if (quat) |qq| {
                for (disps.disps.items) |*disp| {
                    disp.rotate(qq);
                }
            }
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoVertexTranslate = struct {
    id: Id,
    offset: Vec3,
    vert_indicies: []const u32,
    many: ?[]const Vec3,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }
    //If many is set, it should be parallel to vert_index slice and offset applies globally
    pub fn create(alloc: std.mem.Allocator, id: Id, offset: Vec3, vert_index: []const u32, many: ?[]const Vec3) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .offset = offset,
            .vert_indicies = try alloc.dupe(u32, vert_index),
            .many = if (many) |m| try alloc.dupe(Vec3, m) else null,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset.scale(-1), editor, self.vert_indicies, self.many, -1) catch return;
        }
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset, editor, self.vert_indicies, self.many, 1) catch return;
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.vert_indicies);
        if (self.many) |m|
            alloc.free(m);
        alloc.destroy(self);
    }
};

//TODO deprecate, use UndoVertexTranslate
pub const UndoSolidFaceTranslate = struct {
    id: Id,
    side_id: usize,
    offset: Vec3,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }
    pub fn create(alloc: std.mem.Allocator, id: Id, side_id: usize, offset: Vec3) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .side_id = side_id,
            .offset = offset,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset.scale(-1), editor, self.side_id) catch return;
        }
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset, editor, self.side_id) catch return;
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

/// Rather than actually creating/deleting entities, this just unsleeps/sleeps them
/// On map serial, slept entities are omitted
/// Sleep/unsleep is idempotent so no need to sleep before calling applyAll
pub const UndoCreateDestroy = struct {
    pub const Kind = enum { create, destroy };

    id: Id,
    /// are we undoing a creation, or a destruction
    kind: Kind,

    pub fn depId(self: *const @This()) ?Id {
        if (self.kind == .create) return null;
        return self.id;
    }
    pub fn create(alloc: std.mem.Allocator, id: Id, kind: Kind) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .kind = kind,
        };
        return obj;
    }

    fn undoCreate(self: *@This(), editor: *Editor) !void {
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            try solid.removeFromMeshMap(self.id, editor);
        }
        editor.ecs.attach(self.id, .deleted, .{}) catch {};
        //try editor.ecs.sleepEntity(self.id);
    }

    fn redoCreate(self: *@This(), editor: *Editor) !void {
        _ = editor.ecs.removeComponentOpt(self.id, .deleted) catch {};
        //editor.ecs.attach(self.id, .deleted, .{}) catch {};
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            try solid.rebuild(self.id, editor);
        }
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        switch (self.kind) {
            .create => self.undoCreate(editor) catch return,
            .destroy => self.redoCreate(editor) catch return,
        }
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        switch (self.kind) {
            .destroy => self.undoCreate(editor) catch return,
            .create => self.redoCreate(editor) catch return,
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoTextureManip = struct {
    pub const State = struct {
        u: ecs.Side.UVaxis,
        v: ecs.Side.UVaxis,
        tex_id: vpk.VpkResId,
        lightmapscale: i32,
        smoothing_groups: i32,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.u.eql(b.u) and a.v.eql(b.v) and a.tex_id == b.tex_id and a.lightmapscale == b.lightmapscale and a.smoothing_groups == b.smoothing_groups;
        }
    };

    id: Id,
    face_id: u32,
    old: State,
    new: State,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, old: State, new: State, id: Id, face_id: u32) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
            .id = id,
            .face_id = face_id,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        self.set(self.old, editor) catch return;
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        self.set(self.new, editor) catch return;
    }

    fn set(self: *@This(), new: State, editor: *Editor) !void {
        if (try editor.ecs.getOptPtr(self.id, .solid)) |solid| {
            if (self.face_id >= solid.sides.items.len) return;
            const side = &solid.sides.items[self.face_id];
            side.u = new.u;
            side.v = new.v;
            if (new.tex_id != side.tex_id) {
                try solid.removeFromMeshMap(self.id, editor);
            }
            side.tex_id = new.tex_id;
            side.lightmapscale = new.lightmapscale;
            side.smoothing_groups = new.smoothing_groups;
            try solid.rebuild(self.id, editor);
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoChangeGroup = struct {
    const GroupId = ecs.Groups.GroupId;

    old: GroupId,
    new: GroupId,
    id: Id,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, old: GroupId, new: GroupId, id: Id) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
            .id = id,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        setGroup(editor, self.id, self.old) catch return;
    }

    fn setGroup(editor: *Editor, id: Id, new_group: GroupId) !void {
        if (try editor.ecs.getOptPtr(id, .group)) |group| {
            group.id = new_group;
        } else {
            try editor.ecs.attach(id, .group, .{ .id = new_group });
        }
        try editor.selection.list.updateGroup(id, new_group);
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        setGroup(editor, self.id, self.new) catch return;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoSetKeyValue = struct {
    key: []const u8, //Not allocated

    old_value: []const u8, //Both allocated
    new_value: []const u8,

    ent_id: Id,

    pub fn depId(self: *const @This()) ?Id {
        return self.ent_id;
    }

    pub fn create(alloc: std.mem.Allocator, id: Id, key: []const u8, old_value: []const u8, new_value: []const u8) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .key = key,
            .ent_id = id,
            .old_value = try alloc.dupe(u8, old_value),
            .new_value = try alloc.dupe(u8, new_value),
        };
        return obj;
    }

    pub fn createFloats(alloc: std.mem.Allocator, id: Id, key: []const u8, old_value: []const u8, comptime count: usize, floats: [count]f32) !*@This() {
        var printer = std.ArrayList(u8){};
        defer printer.deinit(alloc);
        for (floats, 0..) |f, i| {
            printer.print(alloc, "{s}{d}", .{ if (i == 0) "" else " ", f }) catch {};
        }
        return create(alloc, id, key, old_value, printer.items);
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.ent_id, .key_values) catch null) |kvs| {
            kvs.putString(editor, self.ent_id, self.key, self.old_value) catch return;
        }
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.ent_id, .key_values) catch null) |kvs| {
            kvs.putString(editor, self.ent_id, self.key, self.new_value) catch return;
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.old_value);
        alloc.free(self.new_value);
        alloc.destroy(self);
    }
};

pub const UndoDisplacmentModify = struct {
    id: Id,
    disp_id: u32,
    offset_offset: []const Vec3, //Added to disp.offsets on redo. Subtracted on undo
    offset_index: []const u32, //parallel to offset_offset indexes into disp.offset

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, id: Id, disp_id: u32, offset: []const Vec3, index: []const u32) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .offset_offset = try alloc.dupe(Vec3, offset),
            .offset_index = try alloc.dupe(u32, index),
            .id = id,
            .disp_id = disp_id,
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .displacements) catch null) |disps| {
            const disp = disps.getDispPtrFromDispId(self.disp_id) orelse return;
            for (self.offset_index, 0..) |ind, i| {
                disp.offsets.items[ind] = disp.offsets.items[ind].add(self.offset_offset[i].scale(-1));
            }
            disp.markForRebuild(self.id, editor) catch return;
            editor.draw_state.meshes_dirty = true;
        }
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .displacements) catch null) |disps| {
            const disp = disps.getDispPtrFromDispId(self.disp_id) orelse return;
            for (self.offset_index, 0..) |ind, i| {
                disp.offsets.items[ind] = disp.offsets.items[ind].add(self.offset_offset[i]);
            }
            disp.markForRebuild(self.id, editor) catch return;
            editor.draw_state.meshes_dirty = true;
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.offset_offset);
        alloc.free(self.offset_index);
        alloc.destroy(self);
    }
};

pub const UndoSetLayer = struct {
    id: Id,
    old: LayerId,
    new: LayerId,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, id: Id, old: LayerId, new: LayerId) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .old = old,
            .new = new,
        };
        return obj;
    }

    fn set(editor: *Editor, id: Id, lay: LayerId) void {
        const ent = editor.ecs.getEntity(id) catch return;
        if (!ent.isSet(@intFromEnum(ecs.EcsT.Components.layer))) {
            editor.ecs.attach(id, .layer, .{ .id = lay }) catch {};
            return;
        }

        if (editor.ecs.getPtr(id, ecs.EcsT.Components.layer) catch null) |ptr|
            ptr.* = .{ .id = lay };
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        set(editor, self.id, self.old);
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        set(editor, self.id, self.new);
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoAttachLayer = struct {
    const Kind = enum { attach, detach };

    kind: Kind,

    layer: LayerId,

    parent: LayerId,
    child_index: usize,

    pub fn depId(_: *const @This()) ?Id {
        return null;
    }

    pub fn create(alloc: std.mem.Allocator, layer: LayerId, parent: LayerId, child_index: usize, kind: Kind) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .child_index = child_index,
            .parent = parent,
            .layer = layer,
            .kind = kind,
        };
        return obj;
    }

    pub fn undo(self: *@This(), ed: *Editor) void {
        switch (self.kind) {
            .attach => self.undoCreate(ed),
            .detach => self.redoCreate(ed),
        }
    }

    pub fn redo(self: *@This(), ed: *Editor) void {
        switch (self.kind) {
            .detach => self.undoCreate(ed),
            .attach => self.redoCreate(ed),
        }
    }

    pub fn undoCreate(self: *@This(), editor: *Editor) void {
        const layers = &editor.layers;
        const parent = layers.getLayerFromId(self.parent) orelse return;

        const child = layers.getLayerFromId(self.layer) orelse return;
        if (self.child_index < parent.children.items.len) {
            if (parent.children.items[self.child_index].id == self.layer) {
                layers.recurDisable(child, false) catch {}; //disable all children
                _ = parent.children.orderedRemove(self.child_index);
            }
        }
    }

    pub fn redoCreate(self: *@This(), editor: *Editor) void {
        const layers = &editor.layers;
        const parent = layers.getLayerFromId(self.parent) orelse return;
        const child = layers.getLayerFromId(self.layer) orelse return;
        if (self.child_index <= parent.children.items.len) {
            parent.children.insert(layers.alloc, self.child_index, child) catch return;
            layers.recurDisable(child, child.enabled) catch {};
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

pub const UndoSetClass = struct {
    id: Id,

    old_class: []const u8,
    new_class: []const u8,

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn create(alloc: std.mem.Allocator, id: Id, old: []const u8, new: []const u8) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .id = id,
            .old_class = try alloc.dupe(u8, old),
            .new_class = try alloc.dupe(u8, new),
        };
        return obj;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            ent.setClass(editor, self.old_class, self.id) catch {};
        }
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            ent.setClass(editor, self.new_class, self.id) catch {};
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.old_class);
        alloc.free(self.new_class);
        alloc.destroy(self);
    }
};

pub const UndoConnectDelta = struct {
    /// Allocation matches that of Connection.
    /// index 0 is old, 1 is new
    pub const Delta = union(enum) {
        listen_event: [2][]const u8,
        target: [2][]const u8, //duped
        input: [2][]const u8,
        value: [2][]const u8, //duped
        delay: [2]f32,
        fire_count: [2]i32,
    };

    delta: Delta,
    id: Id,
    index: usize,

    /// delta memory is duped
    pub fn create(alloc: std.mem.Allocator, delta: Delta, id: Id, index: usize) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{
            .delta = switch (delta) {
                else => delta, //Those fields are static strings or numbers
                .target => |t| .{ .target = [2][]const u8{ try alloc.dupe(u8, t[0]), try alloc.dupe(u8, t[1]) } },
                .value => |t| .{ .value = [2][]const u8{ try alloc.dupe(u8, t[0]), try alloc.dupe(u8, t[1]) } },
            },
            .id = id,
            .index = index,
        };
        return obj;
    }

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        self.undoArg(editor, 0) catch {};
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        self.undoArg(editor, 1) catch {};
    }

    pub fn undoArg(self: *@This(), ed: *Editor, comptime ind: u1) !void {
        if (try ed.ecs.getOptPtr(self.id, .connections)) |cons| {
            if (self.index >= cons.list.items.len) return;
            const mod = &cons.list.items[self.index];
            switch (self.delta) {
                .listen_event => |l| mod.listen_event = l[ind],
                .input => |l| mod.input = l[ind],
                .delay => |l| mod.delay = l[ind],
                .fire_count => |l| mod.fire_count = l[ind],
                .target => |t| {
                    mod.target.clearRetainingCapacity();
                    try mod.target.appendSlice(mod._alloc, t[ind]);
                },
                .value => |v| {
                    mod.value.clearRetainingCapacity();
                    try mod.value.appendSlice(mod._alloc, v[ind]);
                },
            }
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.delta) {
            else => {},
            .target, .value => |tv| {
                alloc.free(tv[0]);
                alloc.free(tv[1]);
            },
        }
        alloc.destroy(self);
    }
};

pub const UndoConnectionManip = struct {
    old: ?ecs.Connection,
    new: ?ecs.Connection,
    id: Id,
    index: usize,

    /// takes ownership of passed in Connection's, be sure to dupe any currently living
    pub fn create(alloc: std.mem.Allocator, new: UndoConnectionManip) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = new;
        return obj;
    }

    pub fn depId(self: *const @This()) ?Id {
        return self.id;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        undoArgs(self.old, self.new, self.index, self.id, editor) catch {};
    }

    pub fn redo(self: *@This(), editor: *Editor) void {
        undoArgs(self.new, self.old, self.index, self.id, editor) catch {};
    }

    fn undoArgs(old: ?ecs.Connection, new: ?ecs.Connection, index: usize, id: Id, ed: *Editor) !void {
        if (try ed.ecs.getOptPtr(id, .connections)) |cons| {
            if (old) |*old_| {
                // we can't insert past end of list, it would create uninit items
                if (index > cons.list.items.len)
                    return;

                if (new) |_| {
                    var rem = cons.list.orderedRemove(index);
                    rem.deinit();
                }

                try cons.list.insert(cons._alloc, index, try old_.dupe());
            } else {
                if (index >= cons.list.items.len) return;

                var rem = cons.list.orderedRemove(index);
                rem.deinit();
            }
        }
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.old) |*old|
            old.deinit();
        if (self.new) |*new|
            new.deinit();
        alloc.destroy(self);
    }
};

/// This is a noop
pub const UndoTemplate = struct {
    pub fn create(alloc: std.mem.Allocator) !*@This() {
        const obj = try alloc.create(@This());
        obj.* = .{};
        return obj;
    }

    pub fn depId(self: *const @This()) ?Id {
        _ = self;
        return null;
    }

    pub fn undo(self: *@This(), editor: *Editor) void {
        _ = self;
        _ = editor;
    }
    pub fn redo(self: *@This(), editor: *Editor) void {
        _ = self;
        _ = editor;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

fn genUnion(comptime list: []const struct { [:0]const u8, type }) type {
    var ufields: [list.len]std.builtin.Type.UnionField = undefined;
    var efields: [list.len]std.builtin.Type.EnumField = undefined;
    inline for (list, 0..) |lf, i| {
        ufields[i] = .{
            .name = lf[0],
            .type = *lf[1],
            .alignment = @alignOf(*lf[1]),
        };

        efields[i] = .{ .name = lf[0], .value = i };
    }

    const _EnumT = @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = &efields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    const _UnionT = @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = _EnumT,
        .fields = &ufields,
        .decls = &.{},
    } });

    return struct {
        const EnumT = _EnumT;
        const UnionT = _UnionT;
        const Count = list.len;
        const List = list;
    };
}

const tt = genUnion(&.{
    //.{ "template", UndoTemplate },
    .{ "selection", SelectionUndo },
    .{ "translate", UndoTranslate },
    .{ "vertex_translate", UndoVertexTranslate },
    .{ "face_translate", UndoSolidFaceTranslate },
    .{ "create_destroy", UndoCreateDestroy },
    .{ "texture_manip", UndoTextureManip },
    .{ "change_group", UndoChangeGroup },
    .{ "set_kv", UndoSetKeyValue },
    .{ "disp_modify", UndoDisplacmentModify },
    .{ "set_layer", UndoSetLayer },
    .{ "attach_layer", UndoAttachLayer },
    .{ "set_class", UndoSetClass },
    .{ "connect", UndoConnectionManip },
    .{ "connect_delta", UndoConnectDelta },
});

pub const UndoAmal = struct {
    const Self = @This();

    d: tt.UnionT,
    undo_id: u64,
    dep: u64 = 0, // The id of the first undo item this depends on

    pub fn deinit(self: *const Self, alloc: std.mem.Allocator) void {
        switch (self.d) {
            inline else => |w| w.deinit(alloc),
        }
    }

    pub fn undo(self: *const Self, ed: *Editor) void {
        switch (self.d) {
            inline else => |w| w.undo(ed),
        }
    }

    pub fn redo(self: *const Self, ed: *Editor) void {
        switch (self.d) {
            inline else => |w| w.redo(ed),
        }
    }

    pub fn depId(self: *const Self) ?Id {
        switch (self.d) {
            inline else => |w| return w.depId(),
        }
        return null;
    }
};
