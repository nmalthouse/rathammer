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

/// Any operation which changes state of game world should implement iUndo.
/// See "UndoTemplate" for an example of implementation
pub const iUndo = struct {
    const Vt = @This();
    undo_fn: *const fn (*Vt, *Editor) void,
    redo_fn: *const fn (*Vt, *Editor) void,

    deinit_fn: *const fn (*Vt, std.mem.Allocator) void,

    pub fn undo(self: *Vt, editor: *Editor) void {
        self.undo_fn(self, editor);
    }

    pub fn redo(self: *Vt, editor: *Editor) void {
        self.redo_fn(self, editor);
    }

    pub fn deinit(self: *Vt, alloc: std.mem.Allocator) void {
        self.deinit_fn(self, alloc);
    }
};

// IDEA
// mark dependancy relationships between undo items
// SelectionUndo has no dependents, thus, can be removed from stack without side effects
//
// Texture manip is only dependant on its ids CreateDestroy
// Translate is dependant on Translate and CreateDestroy

pub const UndoGroup = struct {
    description: []const u8,
    items: std.ArrayList(*iUndo),

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.description);
        for (self.items.items) |vt|
            vt.deinit(alloc);
        self.items.deinit();
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

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .stack_pointer = 0,
            .stack = std.ArrayList(UndoGroup).init(alloc),
            .alloc = alloc,
        };
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
    pub fn pushNew(self: *Self) !*std.ArrayList(*iUndo) {
        return try self.pushNewFmt("GenericUndo", .{});
    }

    pub fn pushNewFmt(self: *Self, comptime fmt: []const u8, args: anytype) !*std.ArrayList(*iUndo) {
        return self.pushNewFmtOpts(fmt, args, .{});
    }

    pub fn pushNewFmtOpts(self: *Self, comptime fmt: []const u8, args: anytype, opts: PushOpts) !*std.ArrayList(*iUndo) {
        var desc = std.ArrayList(u8).init(self.alloc);
        try desc.writer().print(fmt, args);
        if (self.stack_pointer > self.stack.items.len)
            self.stack_pointer = self.stack.items.len; // Sanity

        for (self.stack.items[self.stack_pointer..]) |*item| {
            item.deinit(self.alloc);
        }
        try self.stack.resize(self.stack_pointer); //Discard any
        self.stack_pointer += 1;
        const vec = std.ArrayList(*iUndo).init(self.alloc);
        const new_group = UndoGroup{
            .items = vec,
            .description = try desc.toOwnedSlice(),
        };
        try self.stack.append(new_group);
        if (!opts.soft_change)
            self.markDelta();
        return &self.stack.items[self.stack.items.len - 1].items;
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
        self.stack.deinit();
    }
};
///Rather than manually applying the operations when pushing a undo item,
///just call applyRedo on the stack you created.
pub fn applyRedo(list: []const *iUndo, editor: *Editor) void {
    for (list) |item|
        item.redo(editor);
}

pub const SelectionUndo = struct {
    const selection = @import("selection.zig");
    const StateSnapshot = selection.StateSnapshot;
    vt: iUndo,

    old: StateSnapshot,
    new: StateSnapshot,

    /// Assumes snapshots are allocated by 'alloc', takes memory ownership of snapshots
    pub fn create(alloc: std.mem.Allocator, old: StateSnapshot, new: StateSnapshot) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        editor.selection.setFromSnapshot(self.old) catch {};
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        editor.selection.setFromSnapshot(self.new) catch {};
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @fieldParentPtr("vt", vt);
        self.old.destroy(alloc);
        self.new.destroy(alloc);

        alloc.destroy(self);
    }
};

pub const UndoTranslate = struct {
    const Quat = graph.za.Quat;
    vt: iUndo,

    vec: Vec3,
    angle_delta: ?Vec3,
    rot_origin: Vec3,
    id: Id,

    pub fn create(alloc: std.mem.Allocator, vec: Vec3, angle_delta: ?Vec3, id: Id, rot_origin: Vec3) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vec = vec,
            .angle_delta = angle_delta,
            .rot_origin = rot_origin,
            .id = id,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    //TODO translate entity about rot_origin;
    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const quat = if (self.angle_delta) |ad| util3d.extEulerToQuat(ad.scale(-1)) else null;
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translate(self.id, self.vec.scale(-1), editor, self.rot_origin, quat) catch return;
        }
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            ent.setOrigin(editor, self.id, ent.origin.add(self.vec.scale(-1))) catch return;
            if (self.angle_delta) |angd| {
                ent.setAngle(editor, self.id, ent.angle.sub(angd)) catch return;
                if (quat) |qq| {
                    const pos_v = ent.origin.sub(self.rot_origin);
                    const new_o = qq.rotateVec(pos_v).add(self.rot_origin);
                    ent.setOrigin(editor, self.id, new_o) catch return;
                }
            }
        }
        if (editor.ecs.getOptPtr(self.id, .displacements) catch return) |disps| {
            if (quat) |qq| {
                for (disps.disps.items) |*disp| {
                    disp.rotate(qq);
                }
            }
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const quat = if (self.angle_delta) |ad| util3d.extEulerToQuat(ad) else null;
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translate(self.id, self.vec, editor, self.rot_origin, quat) catch return;
        }
        if (editor.ecs.getOptPtr(self.id, .entity) catch return) |ent| {
            ent.setOrigin(editor, self.id, ent.origin.add(self.vec)) catch return;
            if (self.angle_delta) |angd| {
                ent.setAngle(editor, self.id, ent.angle.add(angd)) catch return;

                if (quat) |qq| {
                    const pos_v = ent.origin.sub(self.rot_origin);
                    const new_o = qq.rotateVec(pos_v).add(self.rot_origin);
                    ent.setOrigin(editor, self.id, new_o) catch return;
                }
            }
        }
        if (editor.ecs.getOptPtr(self.id, .displacements) catch return) |disps| {
            if (quat) |qq| {
                for (disps.disps.items) |*disp| {
                    disp.rotate(qq);
                }
            }
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoVertexTranslate = struct {
    vt: iUndo,

    id: Id,
    offset: Vec3,
    vert_indicies: []const u32,
    many: ?[]const Vec3,

    //If many is set, it should be parallel to vert_index slice and offset applies globally
    pub fn create(alloc: std.mem.Allocator, id: Id, offset: Vec3, vert_index: []const u32, many: ?[]const Vec3) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .offset = offset,
            .vert_indicies = try alloc.dupe(u32, vert_index),
            .many = if (many) |m| try alloc.dupe(Vec3, m) else null,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset.scale(-1), editor, self.vert_indicies, self.many, -1) catch return;
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateVerts(self.id, self.offset, editor, self.vert_indicies, self.many, 1) catch return;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.free(self.vert_indicies);
        if (self.many) |m|
            alloc.free(m);
        alloc.destroy(self);
    }
};

//TODO deprecate, use UndoVertexTranslate
pub const UndoSolidFaceTranslate = struct {
    vt: iUndo,

    id: Id,
    side_id: usize,
    offset: Vec3,

    pub fn create(alloc: std.mem.Allocator, id: Id, side_id: usize, offset: Vec3) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .side_id = side_id,
            .offset = offset,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset.scale(-1), editor, self.side_id) catch return;
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .solid) catch return) |solid| {
            solid.translateSide(self.id, self.offset, editor, self.side_id) catch return;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

/// Rather than actually creating/deleting entities, this just unsleeps/sleeps them
/// On map serial, slept entities are omitted
/// Sleep/unsleep is idempotent so no need to sleep before calling applyAll
pub const UndoCreateDestroy = struct {
    pub const Kind = enum { create, destroy };
    vt: iUndo,

    id: Id,
    /// are we undoing a creation, or a destruction
    kind: Kind,

    pub fn create(alloc: std.mem.Allocator, id: Id, kind: Kind) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .kind = kind,
        };
        return &obj.vt;
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

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .create => self.undoCreate(editor) catch return,
            .destroy => self.redoCreate(editor) catch return,
        }
    }

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .destroy => self.undoCreate(editor) catch return,
            .create => self.redoCreate(editor) catch return,
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoTextureManip = struct {
    pub const State = struct {
        u: ecs.Side.UVaxis,
        v: ecs.Side.UVaxis,
        tex_id: vpk.VpkResId,
        lightmapscale: i32,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.u.eql(b.u) and a.v.eql(b.v) and a.tex_id == b.tex_id and a.lightmapscale == b.lightmapscale;
        }
    };

    id: Id,
    face_id: u32,
    vt: iUndo,
    old: State,
    new: State,

    pub fn create(alloc: std.mem.Allocator, old: State, new: State, id: Id, face_id: u32) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .old = old,
            .new = new,
            .id = id,
            .face_id = face_id,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.set(self.old, editor) catch return;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
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
            try solid.rebuild(self.id, editor);
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoChangeGroup = struct {
    const GroupId = ecs.Groups.GroupId;
    vt: iUndo,

    old: GroupId,
    new: GroupId,
    id: Id,

    pub fn create(alloc: std.mem.Allocator, old: GroupId, new: GroupId, id: Id) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .old = old,
            .new = new,
            .id = id,
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
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

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        setGroup(editor, self.id, self.new) catch return;
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoSetKeyValue = struct {
    vt: iUndo,

    key: []const u8, //Not allocated

    old_value: []const u8, //Both allocated
    new_value: []const u8,

    ent_id: Id,

    pub fn create(alloc: std.mem.Allocator, id: Id, key: []const u8, old_value: []const u8, new_value: []const u8) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .key = key,
            .ent_id = id,
            .old_value = try alloc.dupe(u8, old_value),
            .new_value = try alloc.dupe(u8, new_value),
        };
        return &obj.vt;
    }

    pub fn createFloats(alloc: std.mem.Allocator, id: Id, key: []const u8, old_value: []const u8, comptime count: usize, floats: [count]f32) !*iUndo {
        var printer = std.ArrayList(u8).init(alloc);
        defer printer.deinit();
        for (floats, 0..) |f, i| {
            printer.writer().print("{s}{d}", .{ if (i == 0) "" else " ", f }) catch {};
        }
        return create(alloc, id, key, old_value, printer.items);
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.ent_id, .key_values) catch null) |kvs| {
            kvs.putString(editor, self.ent_id, self.key, self.old_value) catch return;
        }
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.ent_id, .key_values) catch null) |kvs| {
            kvs.putString(editor, self.ent_id, self.key, self.new_value) catch return;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.free(self.old_value);
        alloc.free(self.new_value);
        alloc.destroy(self);
    }
};

pub const UndoDisplacmentModify = struct {
    vt: iUndo,

    id: Id,
    disp_id: u32,
    offset_offset: []const Vec3, //Added to disp.offsets on redo. Subtracted on undo
    offset_index: []const u32, //parallel to offset_offset indexes into disp.offset

    pub fn create(alloc: std.mem.Allocator, id: Id, disp_id: u32, offset: []const Vec3, index: []const u32) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .offset_offset = try alloc.dupe(Vec3, offset),
            .offset_index = try alloc.dupe(u32, index),
            .id = id,
            .disp_id = disp_id,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .displacements) catch null) |disps| {
            const disp = disps.getDispPtrFromDispId(self.disp_id) orelse return;
            for (self.offset_index, 0..) |ind, i| {
                disp.offsets.items[ind] = disp.offsets.items[ind].add(self.offset_offset[i].scale(-1));
            }
            disp.markForRebuild(self.id, editor) catch return;
            editor.draw_state.meshes_dirty = true;
        }
    }

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.ecs.getOptPtr(self.id, .displacements) catch null) |disps| {
            const disp = disps.getDispPtrFromDispId(self.disp_id) orelse return;
            for (self.offset_index, 0..) |ind, i| {
                disp.offsets.items[ind] = disp.offsets.items[ind].add(self.offset_offset[i]);
            }
            disp.markForRebuild(self.id, editor) catch return;
            editor.draw_state.meshes_dirty = true;
        }
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.free(self.offset_offset);
        alloc.free(self.offset_index);
        alloc.destroy(self);
    }
};

pub const UndoSetLayer = struct {
    vt: iUndo,

    id: Id,
    old: LayerId,
    new: LayerId,

    pub fn create(alloc: std.mem.Allocator, id: Id, old: LayerId, new: LayerId) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .id = id,
            .old = old,
            .new = new,
        };
        return &obj.vt;
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

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        set(editor, self.id, self.old);
    }

    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        set(editor, self.id, self.new);
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub const UndoAttachLayer = struct {
    const Kind = enum { attach, detach };

    kind: Kind,

    vt: iUndo,
    layer: LayerId,

    parent: LayerId,
    child_index: usize,

    pub fn create(alloc: std.mem.Allocator, layer: LayerId, parent: LayerId, child_index: usize, kind: Kind) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
            .child_index = child_index,
            .parent = parent,
            .layer = layer,
            .kind = kind,
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, ed: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .attach => self.undoCreate(ed),
            .detach => self.redoCreate(ed),
        }
    }

    pub fn redo(vt: *iUndo, ed: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
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

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

/// This is a noop
pub const UndoTemplate = struct {
    vt: iUndo,

    pub fn create(alloc: std.mem.Allocator) !*iUndo {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{ .undo_fn = &@This().undo, .redo_fn = &@This().redo, .deinit_fn = &@This().deinit },
        };
        return &obj.vt;
    }

    pub fn undo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        _ = editor;
    }
    pub fn redo(vt: *iUndo, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        _ = editor;
    }

    pub fn deinit(vt: *iUndo, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};
