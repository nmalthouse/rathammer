/// This file is where all the core data types are for those interested
const std = @import("std");
const limits = @import("limits.zig");
const graph = @import("graph");
const profile = @import("profile.zig");
const Vec3 = graph.za.Vec3;
const Vec3f64 = graph.za.Vec3_f64;
const Mat4 = graph.za.Mat4;
const Quat = graph.za.Quat;
const vpk = @import("vpk.zig");
const vmf = @import("vmf.zig");
const util3d = @import("util_3d.zig");
const meshutil = graph.meshutil;
const thread_pool = @import("thread_pool.zig");
const Editor = @import("editor.zig").Context;
const DrawCtx = graph.ImmediateDrawingContext;
const layer = @import("layer.zig");
const prim_gen = @import("primitive_gen.zig");
const csg = @import("csg.zig");
const toolutil = @import("tool_common.zig");
const StringStorage = @import("string.zig").StringStorage;
pub const SparseSet = graph.SparseSet;
const ArrayList = std.ArrayListUnmanaged;
//Global TODO for ecs stuff
//Many strings in kvs and connections are stored by editor.StringStorage
//as they act as an enum value specified in the fgd.
//Is allowing arbirtary values for this a usecase? Maybe then we need to explcitly allocate.
//rather than storing a []const u8, put a wrapper struct or typedef atleast to indicate its allocation status.
//All arraylists should be converted to Unmanaged, registry could have a pub var component_alloc they can call globally.

/// Some notes about ecs.
/// All components are currently stored in dense arrays mapped by sparse sets. May change this to vtables components which can choose their own alloc.
/// Each Entity is just an integer Id and a bitset representing the components attached.
/// The id's are persistant across map save-loads.
/// When converted to vmf, the entity and solid ids are not mangled so if vbsp gives an error with solid id:xx that maps directly back to the ecs id.
/// vmf solid side ids have no relation as they are not entities.
///
/// Don't take pointers into components as they are not stable, use the entity id instead.
///
const Comp = graph.Ecs.Component;
/// Component fields begining with an _ are not serialized
// This is a bit messy currently.
const EmptyT = struct {
    pub const ECS_NO_SERIAL = void;
    pub fn dupe(_: *@This(), _: anytype, _: anytype) !@This() {
        return .{};
    }
};
pub const EcsT = graph.Ecs.Registry(&.{
    Comp("group", Groups.Group),
    Comp("bounding_box", AABB),
    Comp("solid", Solid),
    Comp("entity", Entity),

    Comp("displacements", Displacements),
    Comp("key_values", KeyValues),
    Comp("connections", Connections),
    Comp("layer", Layer),

    // transient state
    Comp("autovis_invisible", EmptyT),
    Comp("invisible", EmptyT),
    Comp("deleted", EmptyT),
});

/// Groups are used to group entities together. Any entities can be grouped but it is mainly used for brush entities
/// An entity can only belong to one group at a time.
///
/// The editor creates a Groups which manages the mapping between a owning entity and its groupid
pub const Groups = struct {
    const Self = @This();
    pub const GroupId = u16;
    pub const MAX_GROUP = std.math.maxInt(u16) - 1;
    pub const NO_GROUP = 0;

    pub const Group = struct {
        id: GroupId = NO_GROUP,

        pub fn dupe(self: *@This(), _: anytype, _: anytype) !@This() {
            return self.*;
        }

        pub fn serial(self: @This(), _: anytype, jw: anytype, _: EcsT.Id) !void {
            try jw.write(self.id);
        }

        pub fn initFromJson(v: std.json.Value, _: anytype) !@This() {
            if (v != .integer) return error.broken;

            return .{ .id = @intCast(v.integer) };
        }
    };

    group_counter: u16 = NO_GROUP,

    /// Map owners to groups.
    entity_mapper: std.AutoHashMap(EcsT.Id, GroupId),
    /// Map Groups to owners, groups need not be owned.
    group_mapper: std.AutoHashMap(GroupId, ?EcsT.Id),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .entity_mapper = std.AutoHashMap(EcsT.Id, GroupId).init(alloc),
            .group_mapper = std.AutoHashMap(GroupId, ?EcsT.Id).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entity_mapper.deinit();
        self.group_mapper.deinit();
    }

    pub fn getOwner(self: *Self, group: GroupId) ?EcsT.Id {
        if (group == NO_GROUP) return null;
        return self.group_mapper.get(group) orelse null;
    }

    pub fn getGroup(self: *Self, owner: EcsT.Id) ?GroupId {
        return self.entity_mapper.get(owner);
    }

    pub fn setOwner(self: *Self, group: GroupId, owner: EcsT.Id) !void {
        //TODO should we disallow clobbering of this?
        try self.entity_mapper.put(owner, group);
        try self.group_mapper.put(group, owner);
    }

    pub fn ensureUnownedPresent(self: *Self, group: GroupId) !void {
        if (group == NO_GROUP) return;
        const ret = try self.group_mapper.getOrPut(group);
        if (!ret.found_existing) {
            ret.value_ptr.* = null;
        }
    }

    pub fn newGroup(self: *Self, owner: ?EcsT.Id) !GroupId {
        while (true) {
            self.group_counter += 1;
            if (self.group_counter >= MAX_GROUP) return error.tooManyGroups;
            if (!self.group_mapper.contains(self.group_counter))
                break;
        }
        const new = self.group_counter;
        try self.group_mapper.put(new, owner);
        if (owner) |own| {
            try self.entity_mapper.put(own, new);
        }
        return self.group_counter;
    }
};

pub const MeshMap = std.AutoHashMap(vpk.VpkResId, *MeshBatch);
pub threadlocal var mesh_build_time = profile.BasicProfiler.init();

//HOW to DO THE BLEND?
//problem is we map materials -> texture 1:1.
//so blend.vmt ?? how to map it to two texture?

/// Solid mesh storage:
/// Solids are stored as entities in the ecs.
/// The actual mesh data is stored in `Meshmap'.
/// There is one MeshBatch per material. So if there are n materials in use by a map we have n draw calls regardless of the number of solids.
/// This means that modifying a solids verticies or uvs requires the rebuilding of any mesh batches the solid's materials use.
///
/// Every MeshBatch has a hashset 'contains' which stores the ecs ids of all solids it contains
pub const MeshBatch = struct {
    const Self = @This();
    tex: graph.Texture,
    tex_res_id: vpk.VpkResId,
    mesh: meshutil.Mesh,
    contains: std.AutoHashMap(EcsT.Id, void),
    is_dirty: bool = false,

    notify_vt: thread_pool.DeferredNotifyVtable,

    // These are used to draw the solids in 2d views
    lines_vao: c_uint,
    lines_ebo: c_uint,
    lines_index: std.array_list.Managed(u32),

    pub fn init(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, tex: graph.Texture) Self {
        var ret = MeshBatch{
            .mesh = meshutil.Mesh.init(alloc, tex.id),
            .tex_res_id = tex_id,
            .tex = tex,
            .contains = std.AutoHashMap(EcsT.Id, void).init(alloc),
            .notify_vt = .{ .notify_fn = &notify },
            .lines_vao = 0,
            .lines_ebo = 0,
            .lines_index = .init(alloc),
        };

        {
            const c = graph.c;
            c.glGenBuffers(1, &ret.lines_ebo);
            c.glGenVertexArrays(1, &ret.lines_vao);
            meshutil.Mesh.setVertexAttribs(ret.lines_vao, ret.mesh.vbo);
        }

        return ret;
    }

    pub fn deinit(self: *@This()) void {
        self.mesh.deinit();
        self.lines_index.deinit();
        //self.tex.deinit();
        self.contains.deinit();
    }

    pub fn rebuildIfDirty(self: *Self, editor: *Editor) !void {
        if (self.is_dirty) {
            defer self.is_dirty = false; //we defer this incase rebuild marks them dirty again to avoid a loop
            return self.rebuild(editor);
        }
    }

    pub fn notify(vt: *thread_pool.DeferredNotifyVtable, id: vpk.VpkResId, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("notify_vt", vt));
        if (id == self.tex_res_id) {
            self.tex = (editor.textures.get(id) orelse return);
            self.mesh.diffuse_texture = self.tex.id;
            self.is_dirty = true;
        }
    }

    pub fn rebuild(self: *Self, editor: *Editor) !void {
        //Clear self.mesh
        //For solid in contains:
        //for side in solid:
        //if side.texid == this.tex_id
        //  rebuild
        self.mesh.clearRetainingCapacity();
        self.lines_index.clearRetainingCapacity();
        var it = self.contains.iterator();
        while (it.next()) |id| {
            if (editor.ecs.getOptPtr(id.key_ptr.*, .solid) catch null) |solid| {
                for (solid.sides.items) |*side| {
                    if (side.tex_id == self.tex_res_id) {
                        try side.rebuild(solid, self, editor);
                    }
                }
            }
            if (editor.ecs.getOptPtr(id.key_ptr.*, .displacements) catch null) |disp| {
                try disp.rebuild(id.key_ptr.*, editor);
            }
        }
        self.mesh.setData();
        {
            graph.c.glBindVertexArray(self.lines_vao);
            graph.GL.bufferData(graph.c.GL_ARRAY_BUFFER, self.mesh.vbo, meshutil.MeshVert, self.mesh.vertices.items);
            graph.GL.bufferData(graph.c.GL_ELEMENT_ARRAY_BUFFER, self.lines_ebo, u32, self.lines_index.items);
        }
    }
};

pub const AABB = struct {
    pub const ECS_NO_SERIAL = void;
    a: Vec3 = Vec3.zero(),
    b: Vec3 = Vec3.zero(),

    origin_offset: Vec3 = Vec3.zero(),

    pub fn dupe(self: *@This(), _: anytype, _: anytype) !AABB {
        return self.*;
    }

    pub fn setFromOrigin(self: *@This(), new_origin: Vec3) void {
        const delta = new_origin.sub(self.a.add(self.origin_offset));
        self.a = self.a.add(delta);
        self.b = self.b.add(delta);
    }

    pub fn initFromJson(_: std.json.Value, _: anytype) !@This() {
        return error.notAllowed;
    }
};

//How to deal with kvs and entity fields?
//Model id is the biggest, I don't want to do a vpk lookup for every model every frame,
//caching the id in entity makes sense.
//origin and angle are the same
//
//kvs can have a flag that indicates they must sync with parent entity
//no dependency in inspector code then!
//
//What about the reverse?
//just have setters like we already do.

pub const Entity = struct {
    // When a new kv is created, try to cast key to KvSync
    pub const KvSync = enum {
        none,
        origin,
        angles,
        model,
        point0,
        targetname,

        pub fn needsSync(key: []const u8) @This() {
            return std.meta.stringToEnum(@This(), key) orelse .none;
        }
    };

    origin: Vec3 = Vec3.zero(),
    angle: Vec3 = Vec3.zero(),
    class: []const u8 = "",

    _targetname: []const u8 = "",

    /// Fields with _ are not serialized
    /// These are used to draw the entity
    _model_id: ?vpk.VpkResId = null,
    _sprite: ?vpk.VpkResId = null,

    /// set to true when this entity has a kv point0 that should be synced with origin
    /// used for the damn hl2 ladders.
    _has_point0: bool = false,

    pub fn dupe(self: *const @This(), ecs: *EcsT, new_id: EcsT.Id) anyerror!@This() {
        _ = ecs;
        _ = new_id;
        return self.*;
    }

    //TODO what is this for again?
    pub fn getKvString(self: *@This(), kind: KvSync, kvs: *KeyValues, val: *KeyValues.Value) !void {
        switch (kind) {
            .none => {}, //no op
            .origin => try kvs.printInternal(val, "{d} {d} {d}", .{ self.origin.x(), self.origin.y(), self.origin.z() }),
            else => std.debug.print("NOT WORKING UNSUPPORTED\n", .{}),
        }
    }

    pub fn setKvString(self: *@This(), ed: *Editor, id: EcsT.Id, val: *const KeyValues.Value) !void {
        std.debug.print("set kv string with {s} :{s}\n", .{ val.slice(), @tagName(val.sync) });
        switch (val.sync) {
            .origin, .point0 => {
                const floats = val.getFloats(3);
                try self.setOrigin(ed, id, Vec3.new(floats[0], floats[1], floats[2]));
            },
            .angles => {
                const floats = val.getFloats(3);
                try self.setAngle(ed, id, Vec3.new(floats[0], floats[1], floats[2]));
            },
            .model => {
                try self.setModel(ed, id, .{ .name = val.slice() }, false);
            },
            .targetname => try self.setTargetname(ed, id, val.slice()),
            .none => {},
        }
    }

    pub fn setTargetname(self: *@This(), ed: *Editor, id: EcsT.Id, targetname: []const u8) !void {
        const stored = try ed.storeString(targetname);
        try ed.targetname_track.change(stored, self._targetname, id);
        self._targetname = stored;
        if (try ed.ecs.getOptPtr(id, .key_values)) |kvs| {
            try kvs.putStringNoNotify("targetname", self._targetname);
        }
    }

    pub fn setOrigin(self: *@This(), ed: *Editor, self_id: EcsT.Id, origin: Vec3) !void {
        self.origin = origin;
        const bb = try ed.ecs.getPtr(self_id, .bounding_box);
        bb.setFromOrigin(origin);
        if (try ed.ecs.getOptPtr(self_id, .key_values)) |kvs| {
            try kvs.putStringNoNotify("origin", try ed.printScratch("{d} {d} {d}", .{ origin.x(), origin.y(), origin.z() }));
            //If we are a ladder, update that
            if (self._has_point0) {
                try kvs.putStringNoNotify("point0", try ed.printScratch("{d} {d} {d}", .{ origin.x(), origin.y(), origin.z() }));
            }
        }
    }

    pub fn setAngle(self: *@This(), editor: *Editor, self_id: EcsT.Id, angle: Vec3) !void {
        self.angle = angle;
        if (try editor.ecs.getOptPtr(self_id, .key_values)) |kvs| {
            try kvs.putStringNoNotify("angles", try editor.printScratch("{d} {d} {d}", .{ angle.x(), angle.y(), angle.z() }));
            if (kvs.getString("pitch") != null) {
                //Workaround to valve's shitty fgd
                //try kvs.putStringNoNotify("pitch", try editor.printScratch("{d}", .{-angle.x()}));
            }
        }
        self.updateModelbb(editor, self_id);
    }

    fn updateModelbb(self: *@This(), editor: *Editor, self_id: EcsT.Id) void {
        const omod = if (self._model_id) |mid| editor.models.getPtr(mid) else null;
        if (omod) |mod| {
            const mesh = mod.mesh orelse return;
            const bb = editor.getComponent(self_id, .bounding_box) orelse return;
            const quat = util3d.extEulerToQuat(self.angle);
            const rot = quat.toMat3();
            const rbb = util3d.bbRotate(rot, Vec3.zero(), mesh.hull_min, mesh.hull_max);
            bb.origin_offset = rbb[0].scale(-1);
            bb.a = rbb[0];
            bb.b = rbb[1];
            bb.setFromOrigin(self.origin);
        } else { //Set it to the default bb

            var def_bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
            def_bb.setFromOrigin(self.origin);
            const bb = editor.getComponent(self_id, .bounding_box) orelse return;
            bb.* = def_bb;
        }
    }

    pub fn setModel(self: *@This(), editor: *Editor, self_id: EcsT.Id, model: vpk.IdOrName, sanitize: bool) !void {
        if (editor.vpkctx.resolveId(model, sanitize) catch null) |idAndName| {
            self._model_id = idAndName.id;
            if (try editor.ecs.getOptPtr(self_id, .key_values)) |kvs| {
                const stored_model = try editor.storeString(idAndName.name);
                try kvs.putStringNoNotify("model", stored_model);
            }
        }
        self.updateModelbb(editor, self_id);
    }

    pub fn setClass(self: *@This(), editor: *Editor, class: []const u8, self_id: EcsT.Id) !void {
        const old = self.class;
        self.class = try editor.storeString(class);
        self._has_point0 = false;

        try editor.classtrack.change(self.class, old, self_id);

        self._sprite = null;
        { //Fgd stuff
            if (editor.fgd_ctx.getPtr(self.class)) |base| {
                var sl = base.iconsprite;
                if (sl.len > 0) {
                    if (std.mem.endsWith(u8, base.iconsprite, ".vmt"))
                        sl = base.iconsprite[0 .. base.iconsprite.len - 4];
                    const sprite_tex_ = try editor.loadTextureFromVpk(sl);
                    if (sprite_tex_.res_id != 0)
                        self._sprite = sprite_tex_.res_id;
                }
                if (!base.fields.contains("model")) {
                    //We do this before studio_model.
                    //We don't delete the kv so if we change back to a class with model it is retained.
                    self._model_id = null;
                    self.updateModelbb(editor, self_id);
                } else {
                    if (editor.getComponent(self_id, .key_values)) |kvs| {
                        if (kvs.getString("model")) |model_name| {
                            try self.setModel(editor, self_id, .{ .name = model_name }, false);
                        }
                    }
                }

                if (base.studio_model.len > 0) {
                    const id = try editor.loadModel(base.studio_model);
                    if (id != 0)
                        self._model_id = id;
                }
                if (base.has_hull) {
                    self._has_point0 = true;
                    const bb = (try editor.ecs.getPtr(self_id, .bounding_box));
                    bb.a = Vec3.new(0, 0, 0);
                    bb.b = Vec3.new(32, 32, 72);
                    bb.origin_offset = Vec3.new(16, 16, 0);
                    bb.setFromOrigin(self.origin);
                }
            }
        }
    }

    pub fn drawEnt(ent: *@This(), editor: *Editor, view_3d: Mat4, draw: *DrawCtx, draw_nd: *DrawCtx, param: struct {
        frame_color: u32 = 0x00ff00ff,
        draw_model_bb: bool = false,
        ent_id: ?EcsT.Id = null,
        text_param: ?*const graph.ImmediateDrawingContext.TextParam = null,
        screen_area: graph.Rect,
    }) !void {
        //if(ent._has_point0 != null) {
        //    draw.cube(ent.origin)
        //}
        const EXTRA_RENDER_DIST = 64 * 5;
        const ENT_RENDER_DIST = 64 * 10;
        const dist = ent.origin.distance(editor.draw_state.cam3d.pos);
        if (editor.draw_state.tog.models and dist < editor.draw_state.tog.model_render_dist) {
            if (ent._model_id) |m| {
                if (editor.models.getPtr(m)) |o_mod| {
                    if (o_mod.mesh) |mod| {
                        const mat1 = Mat4.fromTranslate(ent.origin);
                        const quat = util3d.extEulerToQuat(ent.angle);
                        const mat3 = mat1.mul(quat.toMat4());
                        mod.drawSimple(view_3d, mat3, editor.draw_state.basic_shader);
                        editor.renderer.countDCall();
                        if (param.draw_model_bb) {
                            const rot = quat.toMat3();
                            //const rot = util3d.extrinsicEulerAnglesToMat3(ent.angle);
                            const bb = util3d.bbRotate(rot, ent.origin, mod.hull_min, mod.hull_max);
                            const cc = util3d.cubeFromBounds(bb[0], bb[1]);
                            //TODO rotate it
                            //draw.cubeFrame(ent.origin.add(cc[0]), cc[1], param.frame_color);
                            draw.cubeFrame(cc[0], cc[1], param.frame_color);
                        }
                    }
                } else {
                    try editor.loadModelFromId(m);
                }
            }
        }
        if (dist < EXTRA_RENDER_DIST and param.ent_id != null and param.text_param != null) {
            if (try editor.ecs.getOptPtr(param.ent_id.?, .key_values)) |kvs| {
                if (kvs.getString("targetname")) |tname| {
                    toolutil.drawText3D(ent.origin.add(Vec3.new(0, 0, 12)), draw_nd, param.text_param.?.*, param.screen_area, view_3d, "{s}", .{tname});
                }
            }
        }
        if (dist > ENT_RENDER_DIST)
            return;
        //TODO set the model size of entities hitbox thingy
        if (editor.draw_state.tog.sprite) {
            if (ent._sprite) |spr| {
                const isp = try editor.getTexture(spr);
                draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
            }
            if (ent._model_id == null) { //Only draw the frame if it doesn't have a model
                draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), param.frame_color);
            }
        }
    }
};

pub const Side = struct {
    const Justify = enum {
        left,
        right,
        center,
        fit,
        top,
        bottom,
    };
    pub const UVaxis = struct {
        axis: Vec3 = Vec3.zero(),
        trans: f32 = 0,
        scale: f32 = 0.25,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.trans == b.trans and a.scale == b.scale and a.axis.x() == b.axis.x() and a.axis.y() == b.axis.y() and
                a.axis.z() == b.axis.z();
        }
    };

    /// Used by displacement
    omit_from_batch: bool = false,

    _alloc: std.mem.Allocator,
    index: ArrayList(u32) = .{},
    u: UVaxis = .{},
    v: UVaxis = .{},
    tex_id: vpk.VpkResId = 0,
    tw: i32 = 10,
    th: i32 = 10,

    lightmapscale: i32 = 16,
    smoothing_groups: i32 = 0,

    /// This field is allocated by StringStorage.
    /// It is only used to keep track of textures that are missing, so they are persisted across save/load.
    /// the actual material assigned is stored in `tex_id`
    material: []const u8 = "",
    pub fn deinit(self: *@This()) void {
        self.index.deinit(self._alloc);
    }

    pub fn dupe(self: *@This()) !@This() {
        var ret = self.*;
        ret.index = try self.index.clone(self._alloc);
        return ret;
    }

    pub fn flipNormal(self: *@This()) void {
        std.mem.reverse(u32, self.index.items);
    }

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ ._alloc = alloc };
    }

    pub fn normal(self: *const @This(), solid: *const Solid) Vec3 {
        const ind = self.index.items;
        if (ind.len < 3) return Vec3.zero();
        const v = solid.verts.items;
        return util3d.trianglePlane(.{ v[ind[0]], v[ind[1]], v[ind[2]] });
    }

    pub fn rebuild(side: *@This(), solid: *Solid, batch: *MeshBatch, editor: *Editor) !void {
        if (side.omit_from_batch)
            return;
        side.tex_id = batch.tex_res_id;
        side.tw = batch.tex.w;
        side.th = batch.tex.h;
        const mesh = &batch.mesh;

        try mesh.vertices.ensureUnusedCapacity(mesh.alloc, side.index.items.len);

        try batch.lines_index.ensureUnusedCapacity(side.index.items.len * 2);
        //const uv_origin = solid.verts.items[side.index.items[0]];
        const uvs = try editor.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
            Vec3.zero(),
        );
        const offset = mesh.vertices.items.len;
        for (side.index.items, 0..) |v_i, i| {
            const v = solid.verts.items[v_i];
            const norm = side.normal(solid).scale(-1);
            try mesh.vertices.append(mesh.alloc, .{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uvs[i].x(),
                .v = uvs[i].y(),
                .nx = norm.x(),
                .ny = norm.y(),
                .nz = norm.z(),
                .color = 0xffffffff,
            });
            const next = (i + 1) % side.index.items.len;
            try batch.lines_index.append(@intCast(offset + i));
            try batch.lines_index.append(@intCast(offset + next));
        }
        const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(offset));
        try mesh.indicies.appendSlice(mesh.alloc, indexs);
    }

    pub fn serial(self: @This(), editor: *Editor, jw: anytype, ent_id: EcsT.Id) !void {
        try jw.beginObject();
        {
            try jw.objectField("index");
            try jw.beginArray();

            for (self.index.items) |id| {
                try jw.write(id);
            }

            try jw.endArray();
            try jw.objectField("u");
            try editor.writeComponentToJson(jw, self.u, ent_id);
            try jw.objectField("v");
            try editor.writeComponentToJson(jw, self.v, ent_id);
            try jw.objectField("tex_id");
            try editor.writeComponentToJson(jw, self.tex_id, ent_id);
            try jw.objectField("lightmapscale");
            try editor.writeComponentToJson(jw, self.lightmapscale, ent_id);
            try jw.objectField("smoothing_groups");
            try editor.writeComponentToJson(jw, self.smoothing_groups, ent_id);
        }
        try jw.endObject();
    }

    pub fn resetUv(self: *@This(), norm: Vec3, face: bool) void {
        if (face) {
            const basis = Vec3.new(0, 0, 1);
            const ang = std.math.radiansToDegrees(
                std.math.acos(basis.dot(norm)),
            );
            const mat = graph.za.Mat3.fromRotation(ang, basis.cross(norm));
            self.u = .{ .axis = mat.mulByVec3(Vec3.new(1, 0, 0)), .trans = 0, .scale = 0.25 };
            self.v = .{ .axis = mat.mulByVec3(Vec3.new(0, 1, 0)), .trans = 0, .scale = 0.25 };
        } else {
            var n: u8 = 0;
            var dist: f32 = 0;
            const vs = [3]Vec3{ Vec3.new(1, 0, 0), Vec3.new(0, 1, 0), Vec3.new(0, 0, 1) };
            for (vs, 0..) |v, i| {
                const d = @abs(norm.dot(v));
                if (d > dist) {
                    n = @intCast(i);
                    dist = d;
                }
            }
            const b = util3d.getBasis(norm);
            self.u = .{ .axis = b[0], .trans = 0, .scale = 0.25 };
            self.v = .{ .axis = b[1], .trans = 0, .scale = 0.25 };
        }
    }

    pub fn justify(self: *@This(), verts: []const Vec3, kind: Justify) struct { u: UVaxis, v: UVaxis } {
        var u = self.u;
        var v = self.v;
        if (self.index.items.len < 3) return .{ .u = u, .v = v };

        const p0 = verts[self.index.items[0]];
        var umin = std.math.floatMax(f32);
        var umax = -std.math.floatMax(f32);
        var vmin = std.math.floatMax(f32);
        var vmax = -std.math.floatMax(f32);

        for (self.index.items) |ind| {
            const vert = verts[ind];
            const udot = vert.dot(self.u.axis);
            const vdot = vert.dot(self.v.axis);

            umin = @min(udot, umin);
            umax = @max(udot, umax);

            vmin = @min(vdot, vmin);
            vmax = @max(vdot, vmax);
        }
        const u_dist = umax - umin;
        const v_dist = vmax - vmin;

        const tw: f32 = @floatFromInt(self.tw);
        const th: f32 = @floatFromInt(self.th);

        switch (kind) {
            .fit => {
                u.scale = u_dist / tw;
                v.scale = v_dist / th;

                u.trans = @mod(-p0.dot(self.u.axis) / u.scale, tw);
                v.trans = @mod(-p0.dot(self.v.axis) / v.scale, th);
            },
            .left => u.trans = @mod(-umin / u.scale, tw),
            .right => u.trans = @mod(-umax / u.scale, tw),
            .top => v.trans = @mod(-vmin / v.scale, th),
            .bottom => v.trans = @mod(-vmax / v.scale, th),
            .center => {
                u.trans = @mod((-(umin + u_dist / 2) / u.scale) - tw / 2, tw);
                v.trans = @mod((-(vmin + v_dist / 2) / v.scale) - th / 2, th);
            },
        }
        return .{ .u = u, .v = v };
    }
};

pub const Solid = struct {
    const Self = @This();
    _alloc: std.mem.Allocator,
    sides: ArrayList(Side) = .{},
    verts: ArrayList(Vec3) = .{},

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    pub fn init(alloc: std.mem.Allocator) Solid {
        return .{ ._alloc = alloc };
    }

    //pub fn initFromJson(v: std.json.Value, editor: *Context) !@This() {
    //    //var ret = init(editor.alloc);
    //    return editor.readComponentFromJson(v, Self);
    //}

    pub fn dupe(self: *const Self, _: anytype, _: anytype) !Self {
        const ret_sides = try self.sides.clone(self._alloc);
        for (ret_sides.items, 0..) |*side, i| {
            side.* = try self.sides.items[i].dupe();
        }
        return .{
            ._alloc = self._alloc,
            .sides = ret_sides,
            .verts = try self.verts.clone(self._alloc),
        };
    }

    //TODO make this good
    pub fn isValid(self: *const Self) bool {
        // a prism is the simplest valid solid
        if (self.verts.items.len < 4) return false;
        var last = self.verts.items[0];
        var all_same = true;
        for (self.verts.items[1..]) |vert| {
            if (!vert.eql(last))
                all_same = false;
            last = vert;
        }
        return !all_same;
    }

    /// Check if this solid can be written to a vmf file
    /// Assumes optimizeMesh has been called on self
    /// returns error if invalid
    pub fn validateVmfSolid(self: *const Self, csgctx: *csg.Context) !void {
        //To be valid:
        //  sides.len >= 4
        //  Every normal is unique

        if (self.sides.items.len < 4) return error.lessThan4Sides;

        var sstr = @import("string.zig").DummyStorage{};

        const vmf_sides = try self._alloc.alloc(vmf.Side, self.sides.items.len);
        defer self._alloc.free(vmf_sides);
        for (self.sides.items, 0..) |s, i| {
            if (s.index.items.len < 3) return error.degenerateSide;
            const inds = s.index.items;
            const v1 = self.verts.items[inds[0]];
            const v2 = self.verts.items[inds[1]];
            const v3 = self.verts.items[inds[2]];

            vmf_sides[i] = .{ .plane = .{ .tri = .{
                Vec3f64.new(v1.x(), v1.y(), v1.z()),
                Vec3f64.new(v2.x(), v2.y(), v2.z()),
                Vec3f64.new(v3.x(), v3.y(), v3.z()),
            } } };
        }

        var new_solid = try csgctx.genMesh2(vmf_sides, self._alloc, &sstr);
        defer new_solid.deinit();
        if (new_solid.sides.items.len != self.sides.items.len) return error.sideLen;
        if (new_solid.verts.items.len != self.verts.items.len) {
            std.debug.print("{d} {d}\n", .{ new_solid.verts.items.len, self.verts.items.len });
            return error.vertLen;
        }

        const eps: f32 = 0.1;
        for (new_solid.verts.items, 0..) |nv, i| {
            if (nv.distance(self.verts.items[i]) > eps)
                return error.vertsDifferent;
        }

        //for(new_solid.sides.items, 0..)|ns, i|{ }
    }

    pub fn initFromPrimitive(alloc: std.mem.Allocator, verts: []const Vec3, faces: []const std.ArrayList(u32), tex_id: vpk.VpkResId, offset: Vec3, rot: graph.za.Mat3) !Solid {
        var ret = init(alloc);
        for (verts) |v|
            try ret.verts.append(alloc, rot.mulByVec3(v).add(offset));

        for (faces) |face| {
            var ind = ArrayList(u32){};
            try ind.appendSlice(alloc, face.items);

            try ret.sides.append(alloc, .{
                ._alloc = alloc,
                .index = ind,
                .u = .{},
                .v = .{},
                .material = "",
                .tex_id = tex_id,
            });
        }
        try ret.optimizeMesh();
        for (ret.sides.items) |*side| {
            const norm = side.normal(&ret);
            side.resetUv(norm, true);
        }
        return ret;
    }

    /// Ensures the following:
    ///     All verticies are unique
    ///     All side indicies are unique
    ///     Side's have > 2 verticies
    ///
    /// Rearrange verticies into well defined order
    /// Rearrange indicies to start with smallest index
    ///
    /// Does NOT check for convexity
    /// Does NOT check for solidity
    pub fn optimizeMesh(self: *Self) !void {
        const alloc = self._alloc;
        var vmap = csg.VecMap.init(alloc);
        defer vmap.deinit();
        var new_sides = ArrayList(Side){};

        var index_map = std.AutoHashMap(u32, void).init(alloc);
        defer index_map.deinit();
        var index = ArrayList(u32){};
        defer index.deinit(alloc);

        for (self.sides.items) |*side| {
            index_map.clearRetainingCapacity();
            index.clearRetainingCapacity();
            for (side.index.items) |*ind| // ensure each vertex unique
                ind.* = try vmap.put(self.verts.items[ind.*]);

            for (side.index.items) |ind| { //ensure each index unique
                const res = try index_map.getOrPut(ind);
                if (res.found_existing) {} else {
                    try index.append(alloc, ind);
                }
            }
            if (index.items.len < 3) { //Remove degenerate sides
                side.deinit();
                continue;
            }
            side.index.clearRetainingCapacity();
            try side.index.appendSlice(alloc, index.items);

            try new_sides.append(self._alloc, side.*);
        }
        self.sides.deinit(self._alloc);
        self.sides = new_sides;
        if (vmap.verts.items.len < self.verts.items.len) {
            self.verts.shrinkAndFree(self._alloc, vmap.verts.items.len);
        }
        try self.verts.resize(self._alloc, vmap.verts.items.len);

        { //Canonical form of solid . verts have a unique order, index have a unique order
            //enables fast comparison
            const mapping = try self._alloc.alloc(usize, vmap.verts.items.len);
            defer self._alloc.free(mapping);
            const map2 = try self._alloc.alloc(usize, vmap.verts.items.len);
            defer self._alloc.free(map2);
            for (0..mapping.len) |m|
                mapping[m] = m;

            var sort = csg.VecOrder.SortCtx{ .new = vmap.verts.items, .mapping = mapping };
            std.sort.insertionContext(0, mapping.len, &sort);

            for (0..mapping.len) |mi| {
                map2[mapping[mi]] = mi;
            }

            for (self.sides.items) |*side| {
                var smallest: u32 = std.math.maxInt(u32);
                var sm_i: usize = 0;
                for (side.index.items, 0..) |*ind, ii| {
                    ind.* = @intCast(map2[ind.*]);
                    if (ind.* < smallest) {
                        smallest = ind.*;
                        sm_i = ii;
                    }
                }
                try index.resize(side._alloc, side.index.items.len);

                @memcpy(index.items, side.index.items);

                side.index.clearRetainingCapacity();
                try side.index.appendSlice(side._alloc, index.items[sm_i..]);
                try side.index.appendSlice(side._alloc, index.items[0..sm_i]);
            }
        }

        @memcpy(self.verts.items, vmap.verts.items);

        { //Check all sides are unique

            const HashCtx = struct {
                const Key = []const u32;

                pub fn hash(ctx: @This(), key: Key) u64 {
                    _ = ctx;

                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHashStrat(&hasher, key, .Deep);
                    return hasher.final();
                }

                pub fn eql(_: @This(), a: Key, b: Key) bool {
                    return std.mem.eql(u32, a, b);
                }
            };
            const MapT = std.HashMap(HashCtx.Key, void, HashCtx, std.hash_map.default_max_load_percentage);

            var to_remove: std.ArrayList(usize) = .{};
            defer to_remove.deinit(self._alloc);
            var map = MapT.init(self._alloc);
            defer map.deinit();
            for (self.sides.items, 0..) |side, i| {
                const res = try map.getOrPut(side.index.items);
                if (res.found_existing)
                    try to_remove.append(self._alloc, i);
            }

            var i = to_remove.items.len;
            while (i > 0) : (i -= 1) {
                const n = to_remove.items[i - 1];
                var old = self.sides.orderedRemove(n);
                old.deinit();
            }
            if (to_remove.items.len > 0)
                std.debug.print("Removed {d} duplicate sides\n", .{to_remove.items.len});
        }
    }

    pub fn initFromCube(alloc: std.mem.Allocator, v1: Vec3, v2: Vec3, tex_id: vpk.VpkResId) !Solid {
        var ret = init(alloc);
        const cc = util3d.cubeFromBounds(v1, v2);
        const N = Vec3.new;
        const o = cc[0];
        const e = cc[1];

        const volume = e.x() * e.y() * e.z();
        if (volume < limits.min_volume)
            return error.invalidCube;

        const verts = [8]Vec3{
            o.add(N(0, 0, 0)),
            o.add(N(e.x(), 0, 0)),
            o.add(N(e.x(), e.y(), 0)),
            o.add(N(0, e.y(), 0)),

            o.add(N(0, 0, e.z())),
            o.add(N(e.x(), 0, e.z())),
            o.add(N(e.x(), e.y(), e.z())),
            o.add(N(0, e.y(), e.z())),
        };
        const vis = [6][4]u32{
            .{ 0, 1, 2, 3 }, //-z
            .{ 7, 6, 5, 4 }, //+z
            //
            .{ 3, 7, 4, 0 }, //-x
            .{ 5, 6, 2, 1 }, //+x
            //
            .{ 4, 5, 1, 0 }, //-y
            .{ 6, 7, 3, 2 }, //+y
        };
        const Uvs = [6][2]Vec3{
            .{ N(1, 0, 0), N(0, 1, 0) },
            .{ N(1, 0, 0), N(0, -1, 0) },
            .{ N(0, -1, 0), N(0, 0, -1) },

            .{ N(0, 1, 0), N(0, 0, -1) },
            .{ N(1, 0, 0), N(0, 0, -1) },
            .{ N(-1, 0, 0), N(0, 0, -1) },
        };
        try ret.verts.appendSlice(ret._alloc, &verts);
        for (vis, 0..) |face, i| {
            var ind = ArrayList(u32){};
            //try ind.appendSlice(&.{ 1, 2, 0, 2, 3, 0 });

            try ind.appendSlice(ret._alloc, &face);
            try ret.sides.append(ret._alloc, .{
                ._alloc = ret._alloc,
                .index = ind,
                .u = .{ .axis = Uvs[i][0], .trans = 0, .scale = 0.25 },
                .v = .{ .axis = Uvs[i][1], .trans = 0, .scale = 0.25 },
                .material = "",
                .tex_id = tex_id,
            });
        }
        return ret;
    }

    pub fn roundAllVerts(self: *Self, id: EcsT.Id, ed: *Editor) !void {
        for (self.verts.items) |*vert| {
            vert.data = @round(vert.data);
        }
        try self.rebuild(id, ed);
    }

    pub fn deinit(self: *Self) void {
        for (self.sides.items) |*side|
            side.deinit();
        self.sides.deinit(self._alloc);
        self.verts.deinit(self._alloc);
    }

    pub fn recomputeBounds(self: *Self, aabb: *AABB) void {
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));
        for (self.verts.items) |s| {
            min = min.min(s);
            max = max.max(s);
        }
        aabb.a = min;
        aabb.b = max;
    }

    fn translateVertsSimple(self: *@This(), vert_i: []const u32, offset: Vec3) void {
        for (vert_i) |v_i| {
            if (v_i >= self.verts.items.len) continue;

            self.verts.items[v_i] = self.verts.items[v_i].add(offset);
        }
    }

    // TODO Update displacemnt
    pub fn translateVerts(self: *@This(), id: EcsT.Id, offset: Vec3, editor: *Editor, vert_i: []const u32, vert_offsets: ?[]const Vec3, factor: f32) !void {
        if (vert_offsets) |offs| {
            for (vert_i, 0..) |v_i, i| {
                if (v_i >= self.verts.items.len) continue;

                self.verts.items[v_i] = self.verts.items[v_i].add(offset).add(offs[i].scale(factor));
            }
        } else {
            self.translateVertsSimple(vert_i, offset);
        }

        for (self.sides.items) |*side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            batch.*.is_dirty = true;

            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = (try editor.ecs.getPtr(id, .bounding_box));
        self.recomputeBounds(bb);
        editor.draw_state.meshes_dirty = true;
    }

    //Update displacement
    pub fn translateSide(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor, side_i: usize) !void {
        if (side_i >= self.sides.items.len) return;
        for (self.sides.items[side_i].index.items) |ind| {
            self.verts.items[ind] = self.verts.items[ind].add(vec);
        }

        for (self.sides.items) |*side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            batch.*.is_dirty = true;

            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = (try editor.ecs.getPtr(id, .bounding_box));
        self.recomputeBounds(bb);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn rebuild(self: *@This(), id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |*side| {
            const batch = try editor.getOrPutMeshBatch(side.tex_id);
            batch.*.is_dirty = true;
            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = try editor.ecs.getPtr(id, .bounding_box);
        self.recomputeBounds(bb);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor, rot_origin: Vec3, rot: ?Quat) !void {
        //move all verts, recompute bounds
        //for each batchid, call rebuild

        if (rot) |quat| {
            for (self.verts.items) |*vert| {
                const v = vert.sub(rot_origin);
                const rotv = quat.rotateVec(v);

                vert.* = rotv.add(rot_origin).add(vec);
            }
        } else {
            for (self.verts.items) |*vert| {
                vert.* = vert.add(vec);
            }
        }
        var pos = rot_origin.scale(-1);
        if (pos.length() > 0.1)
            pos = Vec3.new(1, 0, 0);
        for (self.sides.items) |*side| {
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;

            if (rot) |quat| {
                const pos_r = quat.rotateVec(pos.sub(rot_origin)).add(rot_origin);

                const new_u_axis = quat.rotateVec(side.u.axis);
                const new_v_axis = quat.rotateVec(side.v.axis);

                const u_trans_r = pos.dot(side.u.axis) / side.u.scale + side.u.trans - pos_r.dot(new_u_axis) / side.u.scale;
                const v_trans_r = pos.dot(side.v.axis) / side.v.scale + side.v.trans - pos_r.dot(new_v_axis) / side.v.scale;

                side.u.trans = u_trans_r;
                side.v.trans = v_trans_r;

                side.u.axis = new_u_axis;
                side.v.axis = new_v_axis;
            }
        }
        try self.rebuild(id, editor);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            if (batch.*.contains.remove(id))
                batch.*.is_dirty = true;
        }
        editor.draw_state.meshes_dirty = true;
    }

    pub fn drawEdgeOutline(self: *Self, draw: *DrawCtx, vec: Vec3, param: struct {
        edge_size: f32 = 1,
        point_size: f32 = 1,
        edge_color: u32 = 0,
        point_color: u32 = 0,
    }) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(vec);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(vec);
                if (param.edge_color > 0)
                    draw.line3D(last, p, param.edge_color, param.edge_size);
                if (param.point_color > 0)
                    draw.point3D(p, param.point_color, param.point_size);
                last = p;
            }
        }
    }

    pub fn drawEdgeOutlineFast(self: *Self, line_batch: *graph.ImmediateDrawingContext.Line3DBatch, point_batch: *graph.ImmediateDrawingContext.Point3DBatch, offset: Vec3, edge_color: u32, point_color: u32) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(offset);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(offset);
                if (edge_color > 0)
                    graph.ImmediateDrawingContext.line3DBatch(line_batch, last, p, edge_color);
                if (point_color > 0)
                    graph.ImmediateDrawingContext.point3DBatch(point_batch, p, point_color);
                last = p;
            }
        }
    }

    pub fn getSidePtr(self: *Self, side_id: ?u32) ?*Side {
        if (side_id) |si| {
            if (si >= self.sides.items.len) return null;
            return &self.sides.items[si];
        }
        return null;
    }

    /// only_verts contains a list of vertex indices to apply offset to.
    /// If it is null, all vertices are offset
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Editor, offset: Vec3, only_verts: ?[]const u32, texture_lock: bool) !void {
        for (self.sides.items) |side| {
            if (side.omit_from_batch)
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try editor.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const ioffset = batch.vertices.items.len;
            const tw: f32 = @floatFromInt(side.tw);
            const th: f32 = @floatFromInt(side.th);
            for (side.index.items, 0..) |vi, i| {
                _ = i;
                const v = self.verts.items[vi];

                var off = offset;
                if (only_verts) |ov| {
                    if (std.mem.indexOfScalar(u32, ov, vi) == null)
                        off = Vec3.zero();
                }
                const pos = v.add(off);

                const upos = if (texture_lock) v else pos;
                batch.appendVert(.{
                    .pos = .{
                        .x = pos.x(),
                        .y = pos.y(),
                        .z = pos.z(),
                    },
                    .uv = .{
                        .x = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                        .y = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset));
            batch.appendIndex(indexs);
        }
    }

    //the vertexOffsetCb is given the vertex, the side_index, the index
    pub fn drawImmediateCustom(self: *Self, draw: *DrawCtx, ed: *Editor, user: anytype, vertOffsetCb: fn (@TypeOf(user), Vec3, u32, u32) Vec3, texture_lock: bool) !void {
        for (self.sides.items, 0..) |side, s_i| {
            if (side.omit_from_batch) //don't draw this sideit
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try ed.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const ioffset = batch.vertices.items.len;
            const tw: f32 = @floatFromInt(side.tw);
            const th: f32 = @floatFromInt(side.th);
            for (side.index.items, 0..) |vi, i| {
                const v = self.verts.items[vi];

                const off = vertOffsetCb(user, v, @intCast(s_i), @intCast(i));

                const pos = v.add(off);
                const upos = if (texture_lock) v else pos;
                batch.appendVert(.{
                    .pos = .{
                        .x = pos.x(),
                        .y = pos.y(),
                        .z = pos.z(),
                    },
                    .uv = .{
                        .x = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                        .y = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try ed.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset));
            batch.appendIndex(indexs);
        }
    }

    /// Returns the number of verticies serialized
    pub fn printObj(self: *const Self, vert_offset: usize, name: []const u8, out: anytype) usize {
        out.print("o {s}\n", .{name});
        for (self.verts.items) |v|
            out.print("v {d} {d} {d}\n", .{ v.x(), v.y(), v.z() });

        for (self.sides.items) |side| {
            const in = side.index.items;

            for (1..side.index.items.len - 1) |i| {
                std.debug.print("f {d} {d} {d}\n", .{
                    1 + in[0] + vert_offset,
                    1 + in[i + 1] + vert_offset,
                    1 + in[i] + vert_offset,
                });
            }
        }

        return self.verts.items.len;
    }
};

pub const Displacements = struct {
    const Self = @This();
    _alloc: std.mem.Allocator,
    disps: ArrayList(Displacement) = .{},

    //Solid.sides index map into disps
    sides: ArrayList(?usize) = .{},

    pub fn init(alloc: std.mem.Allocator, side_count: usize) !Self {
        var ret = Self{
            ._alloc = alloc,
        };
        try ret.sides.appendNTimes(ret._alloc, null, side_count);

        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.disps.items) |*disp|
            disp.deinit();
        self.sides.deinit(self._alloc);
        self.disps.deinit(self._alloc);
    }

    pub fn dupe(self: *Self, ecs: *EcsT, new_id: EcsT.Id) !Self {
        const ret = Self{
            ._alloc = self._alloc,
            .disps = try self.disps.clone(self._alloc),
            .sides = try self.sides.clone(self._alloc),
        };
        for (ret.disps.items) |*disp| {
            disp.* = try disp.dupe(ecs, new_id);
        }
        return ret;
    }

    pub fn rebuild(self: *Self, ent_id: EcsT.Id, ed: *Editor) !void {
        for (self.disps.items) |*disp| {
            try disp.rebuild(ent_id, ed);
        }
    }

    pub fn getDispPtrFromDispId(self: *Self, disp_id: u32) ?*Displacement {
        if (disp_id >= self.disps.items.len) return null;
        return &self.disps.items[disp_id];
    }

    pub fn getDispPtr(self: *Self, side_id: usize) ?*Displacement {
        if (side_id >= self.sides.items.len) return null;
        const index = self.sides.items[side_id] orelse return null;
        return self.getDispPtrFromDispId(@intCast(index));
    }

    pub fn put(self: *Self, disp: Displacement, side_id: usize) !void {
        if (side_id >= self.sides.items.len) {
            try self.sides.appendNTimes(self._alloc, null, side_id - self.sides.items.len);
        }
        const disp_index = self.disps.items.len;
        try self.disps.append(self._alloc, disp);
        if (self.sides.items[side_id]) |ex_disp| {
            std.debug.print("CLOBBERING A DISPLACMENT, THIS MAY BE BAD\n", .{});
            self.disps.items[ex_disp].deinit();
            self.sides.items[side_id] = null;
        }

        self.sides.items[side_id] = disp_index;
    }
};

pub const Displacement = struct {
    pub const VectorRow = ArrayList(Vec3);
    pub const ScalarRow = ArrayList(f32);
    const Self = @This();
    _alloc: std.mem.Allocator,
    _verts: ArrayList(Vec3) = .{},
    _index: ArrayList(u32) = .{},
    tex_id: vpk.VpkResId = 0,

    //DEPRECATION
    parent_side_i: usize = 0,

    vert_start_i: usize = 0,
    power: u32 = 0,

    normals: VectorRow = .{},
    offsets: VectorRow = .{},
    normal_offsets: VectorRow = .{},
    dists: ScalarRow = .{},
    alphas: ScalarRow = .{},

    //start_pos: Vec3 = Vec3.zero(),
    elevation: f32 = 0,
    //TODO do the tri_tags?

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var ret = self.*;
        ret._verts = try self._verts.clone(self._alloc);
        ret._index = try self._index.clone(self._alloc);
        ret.normals = try self.normals.clone(self._alloc);
        ret.offsets = try self.offsets.clone(self._alloc);
        ret.normal_offsets = try self.normal_offsets.clone(self._alloc);
        ret.dists = try self.dists.clone(self._alloc);
        ret.alphas = try self.alphas.clone(self._alloc);

        return ret;
    }

    fn vertsPerRow(power: u32) u32 {
        return (std.math.pow(u32, 2, power) + 1);
    }

    //TODO sanitize power, what does source support?
    pub fn init(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, parent_s: usize, power: u32, normal: Vec3) !Self {
        const vper_row = vertsPerRow(power);
        const count = vper_row * vper_row;
        var ret = @This(){
            ._alloc = alloc,
            ._verts = ArrayList(Vec3){},
            ._index = ArrayList(u32){},
            .tex_id = tex_id,
            .parent_side_i = parent_s,
            .power = power,
        };

        try ret.normals.appendNTimes(alloc, normal, count);
        try ret.offsets.appendNTimes(alloc, Vec3.zero(), count);
        try ret.normal_offsets.appendNTimes(alloc, normal, count);
        try ret.dists.appendNTimes(alloc, 0, count);
        try ret.alphas.appendNTimes(alloc, 0, count);

        return ret;
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, parent_s: usize, dispinfo: *const vmf.DispInfo) !Self {
        var ret = Displacement{
            ._alloc = alloc,
            ._verts = ArrayList(Vec3){},
            ._index = ArrayList(u32){},
            .tex_id = tex_id,
            .parent_side_i = parent_s,
            .power = @intCast(dispinfo.power),
            .elevation = dispinfo.elevation,

            .normals = try dispinfo.normals.clone(alloc),
            .offsets = try dispinfo.offsets.clone(alloc),
            .normal_offsets = try dispinfo.offset_normals.clone(alloc),

            .dists = try dispinfo.distances.clone(alloc),
            .alphas = try dispinfo.alphas.clone(alloc),
            //.tri_tags = ScalarRow.init(alloc),
        };
        const vper_row = vertsPerRow(ret.power);
        const vcount = vper_row * vper_row;
        const H = struct {
            pub fn correctCount(count: usize, array: anytype, default: anytype, _alloc: std.mem.Allocator) !void {
                if (array.items.len != count) {
                    std.debug.print("Displacment has invalid length, replacing\n", .{});
                    array.clearRetainingCapacity();
                    try array.appendNTimes(_alloc, default, count);
                }
            }
        };

        try H.correctCount(vcount, &ret.normals, Vec3.new(0, 0, 1), alloc);
        try H.correctCount(vcount, &ret.offsets, Vec3.new(0, 0, 0), alloc);
        try H.correctCount(vcount, &ret.normal_offsets, Vec3.new(0, 0, 0), alloc);
        try H.correctCount(vcount, &ret.dists, 0, alloc);
        try H.correctCount(vcount, &ret.alphas, 0, alloc);

        return ret;
    }

    pub fn getStartPos(self: *const Self, solid: *const Solid) !Vec3 {
        const si = self.vert_start_i;
        if (self.parent_side_i >= solid.sides.items.len) return error.invalidSideIndex;
        const side = &solid.sides.items[self.parent_side_i];
        if (si >= side.index.items.len) return error.invalidIndex;
        return solid.verts.items[side.index.items[si]];
    }

    fn avgVert(comptime T: type, old_items: anytype, new_items: anytype, func: fn (T, T) T, old_row_count: u32) void {
        const new_row_count = old_row_count * 2 - 1;
        for (old_items, 0..) |n, i| {
            const col_index = @divFloor(i, old_row_count);
            const row_index = @mod(i, old_row_count);
            new_items[row_index * 2 + col_index * new_row_count] = n;
        }
        for (0..old_row_count) |ri| {
            const start = ri * new_row_count;
            for (new_items[start .. start + new_row_count], 0..) |*n, i| {
                if (i % 2 != 0) {
                    const a = new_items[i - 1];
                    const b = new_items[i + 1];
                    n.* = func(a, b);
                }
            }
        }
    }

    //THIS is horribly broken
    //TODO write a catmull-clark.
    //I think it needs to work over n meshes sewn together
    pub fn subdivide(self: *Self, id: EcsT.Id, ed: *Editor) !void {
        const H = struct {
            pub fn avgVec(a: Vec3, b: Vec3) Vec3 {
                return a.add(b).scale(0.5);
            }

            pub fn avgFloat(a: f32, b: f32) f32 {
                return (a + b) / 2;
            }
        };
        const MAX_POWER = 10;
        if (self.power >= MAX_POWER) return;
        const old_v = vertsPerRow(self.power);
        self.power += 1;
        const vper_row = vertsPerRow(self.power);

        const alloc = self._alloc;
        var new_norms = VectorRow{};
        try new_norms.resize(alloc, vper_row * vper_row);
        avgVert(Vec3, self.normals.items, new_norms.items, H.avgVec, old_v);

        var new_off = VectorRow{};
        try new_off.resize(alloc, vper_row * vper_row);
        avgVert(Vec3, self.offsets.items, new_off.items, H.avgVec, old_v);

        var new_noff = VectorRow{};
        try new_noff.resize(alloc, vper_row * vper_row);
        avgVert(Vec3, self.normal_offsets.items, new_noff.items, H.avgVec, old_v);

        var new_dist = ScalarRow{};
        try new_dist.resize(alloc, vper_row * vper_row);
        avgVert(f32, self.dists.items, new_dist.items, H.avgFloat, old_v);

        var new_alpha = ScalarRow{};
        try new_alpha.resize(alloc, vper_row * vper_row);
        avgVert(f32, self.alphas.items, new_alpha.items, H.avgFloat, old_v);

        self.normals.deinit(alloc);
        self.normals = new_norms;

        self.offsets.deinit(alloc);
        self.offsets = new_off;

        self.normal_offsets.deinit(alloc);
        self.normal_offsets = new_noff;

        self.dists.deinit(alloc);
        self.dists = new_dist;

        self.alphas.deinit(alloc);
        self.alphas = new_alpha;

        try self.markForRebuild(id, ed);
    }

    pub fn deinit(self: *Self) void {
        self._verts.deinit(self._alloc);
        self._index.deinit(self._alloc);

        self.normals.deinit(self._alloc);
        self.offsets.deinit(self._alloc);
        self.normal_offsets.deinit(self._alloc);
        self.dists.deinit(self._alloc);
        self.alphas.deinit(self._alloc);
        //self.tri_tags.deinit();
    }

    pub fn setStartI(self: *Self, solid: *const Solid, ed: *Editor, start_pos: Vec3) !void {
        const ss = solid.sides.items[self.parent_side_i].index.items;
        const corners = [4]Vec3{
            solid.verts.items[ss[0]],
            solid.verts.items[ss[1]],
            solid.verts.items[ss[2]],
            solid.verts.items[ss[3]],
        };
        self.vert_start_i = try ed.csgctx.findDisplacmentStartI(&corners, start_pos);
    }

    pub fn genVerts(self: *Self, solid: *const Solid, editor: *Editor) !void {
        const ss = solid.sides.items[self.parent_side_i].index.items;
        const corners = [4]Vec3{
            solid.verts.items[ss[0]],
            solid.verts.items[ss[1]],
            solid.verts.items[ss[2]],
            solid.verts.items[ss[3]],
        };
        try editor.csgctx.genMeshDisplacement(&corners, self);
    }

    pub fn markForRebuild(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        const batch = try editor.getOrPutMeshBatch(self.tex_id);
        batch.*.is_dirty = true;
        try batch.*.contains.put(id, {});
    }

    pub fn rebuild(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        const batch = try editor.getOrPutMeshBatch(self.tex_id);
        batch.*.is_dirty = true;
        try batch.*.contains.put(id, {});

        self.tex_id = batch.tex_res_id;
        const solid = try editor.ecs.getOptPtr(id, .solid) orelse return;
        if (self.parent_side_i >= solid.sides.items.len) return;
        for (solid.sides.items) |*side| {
            side.omit_from_batch = !editor.draw_state.draw_displacment_solid;
        }
        solid.sides.items[self.parent_side_i].omit_from_batch = true;

        self._verts.clearRetainingCapacity();
        self._index.clearRetainingCapacity();
        try self.genVerts(solid, editor);

        const side = &solid.sides.items[self.parent_side_i];
        const mesh = &batch.mesh;
        try mesh.vertices.ensureUnusedCapacity(mesh.alloc, self._verts.items.len);
        try mesh.indicies.ensureUnusedCapacity(mesh.alloc, self._index.items.len);
        const si = self.vert_start_i;
        const uvs = try editor.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
            Vec3.zero(),
        );
        const vper_row = std.math.pow(u32, 2, self.power) + 1;
        const vper_rowf: f32 = @floatFromInt(vper_row);
        const t = 1.0 / (@as(f32, @floatFromInt(vper_row)) - 1);
        const offset = mesh.vertices.items.len;
        if (self._verts.items.len != vper_row * vper_row) return;
        const uv0 = uvs[si % 4];
        const uv1 = uvs[(si + 1) % 4];
        const uv2 = uvs[(si + 2) % 4];
        const uv3 = uvs[(si + 3) % 4];

        for (self._verts.items, 0..) |v, i| {
            const fi: f32 = @floatFromInt(i);
            const ri: f32 = @trunc(fi / vper_rowf);
            const ci: f32 = @trunc(@mod(fi, vper_rowf));

            const inter0 = uv0.lerp(uv1, ri * t);
            const inter1 = uv3.lerp(uv2, ri * t);
            const uv = inter0.lerp(inter1, ci * t);
            const norm = self.normals.items[i];

            try mesh.vertices.append(mesh.alloc, .{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uv.x(),
                .v = uv.y(),
                .nx = norm.x(),
                .ny = norm.y(),
                .nz = norm.z(),
                .color = 0xffffffff,
            });
        }
        for (self._index.items) |ind| {
            try mesh.indicies.append(mesh.alloc, ind + @as(u32, @intCast(offset)));
        }
    }

    pub fn rotate(self: *Self, rot: Quat) void {
        for (self.offsets.items, 0..) |*off, i| {
            off.* = rot.rotateVec(off.*);
            self.normals.items[i] = rot.rotateVec(self.normals.items[i]);
            self.normal_offsets.items[i] = rot.rotateVec(self.normal_offsets.items[i]);
            self.offsets.items[i] = rot.rotateVec(self.offsets.items[i]);
        }
    }

    //vertOffsetCb is given the vertex, index into _verts
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, ed: *Editor, self_id: EcsT.Id, user_data: anytype, vertOffsetCb: fn (@TypeOf(user_data), Vec3, u32) Vec3) !void {
        //pub fn drawImmediate(self: *Self, draw: *DrawCtx, ed: *Editor, self_id: EcsT.Id) !void {
        const solid = (ed.ecs.getOptPtr(self_id, .solid) catch return orelse return);
        const tex = try ed.getTexture(self.tex_id);
        const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
            .shader = DrawCtx.billboard_shader,
            .texture = tex.id,
            .camera = ._3d,
        } }) catch return).billboard;
        const side = &solid.sides.items[self.parent_side_i];
        const si = self.vert_start_i;
        const vper_row = vertsPerRow(self.power);
        const vper_rowf: f32 = @floatFromInt(vper_row);
        const t = 1.0 / (vper_rowf - 1);
        const uvs = try ed.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            @intCast(tex.w),
            @intCast(tex.h),
            Vec3.zero(),
        );
        if (self._verts.items.len != vper_row * vper_row) return;
        const uv0 = uvs[si % 4];
        const uv1 = uvs[(si + 1) % 4];
        const uv2 = uvs[(si + 2) % 4];
        const uv3 = uvs[(si + 3) % 4];

        const offset = batch.vertices.items.len;
        for (self._verts.items, 0..) |v, i| {
            const fi: f32 = @floatFromInt(i);
            const ri: f32 = @trunc(fi / vper_rowf);
            const ci: f32 = @trunc(@mod(fi, vper_rowf));

            const inter0 = uv0.lerp(uv1, ri * t);
            const inter1 = uv3.lerp(uv2, ri * t);
            const uv = inter0.lerp(inter1, ci * t);
            const off = vertOffsetCb(user_data, v, @intCast(i));
            const nv = off.add(v);

            batch.appendVert(.{
                .pos = .{
                    .x = nv.x(),
                    .y = nv.y(),
                    .z = nv.z(),
                },
                .uv = .{ .x = uv.x(), .y = uv.y() },
                .color = 0xffff_ffff,
            });
        }
        for (self._index.items) |ind| {
            batch.appendInd(ind + @as(u32, @intCast(offset)));
        }
    }
};

pub const Layer = struct {
    id: layer.Id = .none,

    pub fn dupe(a: *@This(), _: anytype, _: anytype) !@This() {
        return a.*;
    }
};

//TODO don't trust that passed keys are static strings, always pass them through stringstorage
pub const KeyValues = struct {
    const Strings = @import("string.zig");
    const Value = struct {
        _string: Strings.String,

        // Certain kv's "model, angles, origin" must be kept in sync with the entity component
        sync: Entity.KvSync,

        pub fn clone(self: *@This(), alloc: std.mem.Allocator) !@This() {
            var ret = self.*;
            ret._string = try self._string.clone(alloc);
            return ret;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self._string.slice();
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self._string.deinit(alloc);
        }

        pub fn getFloats(self: *const @This(), comptime count: usize) [count]f32 {
            const sl = self._string.slice();
            var it = std.mem.tokenizeScalar(u8, sl, ' ');
            var ret: [count]f32 = undefined;
            for (0..count) |i| {
                ret[i] = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
            }
            return ret;
        }

        fn initNoNotify(alloc: std.mem.Allocator, value: []const u8) !@This() {
            return @This(){
                ._string = try .init(alloc, value),
                .sync = .none,
            };
        }

        /// Create a new value, if it is a synced field get the value from the entity, otherwise set it to 'value'
        pub fn initDefault(kvs: *KeyValues, ecs: *EcsT, id: EcsT.Id, key: []const u8, value: []const u8) !@This() {
            var ret = @This(){
                ._string = .initEmpty(),
                .sync = Entity.KvSync.needsSync(key),
            };
            if (ret.sync != .none) {
                //Replace the default with whatever the entity has
                if (try ecs.getOptPtr(id, .entity)) |ent| {
                    try ent.getKvString(ret.sync, kvs, &ret);
                }
            } else {
                try ret._string.set(kvs.alloc, value);
            }
            return ret;
        }

        /// Create a new value with 'value' and notify entity if synced
        fn initValue(kvs: *KeyValues, ed: *Editor, id: EcsT.Id, key: []const u8, value: []const u8) !?@This() {
            var ret = @This(){
                ._string = try .init(kvs.alloc, value),
                .sync = Entity.KvSync.needsSync(key),
            };
            if (ret.sync != .none) {
                //Replace the default with whatever the entity has
                if (try ed.ecs.getOptPtr(id, .entity)) |ent| {
                    try ent.setKvString(ed, id, &ret);
                    ret._string.deinit(kvs.alloc);
                    return null;
                }
            }
            return ret;
        }
    };
    const Self = @This();
    const MapT = std.StringHashMap(Value);
    map: MapT,
    alloc: std.mem.Allocator,
    print_buf: std.ArrayListUnmanaged(u8) = .{},

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var ret = Self{
            .alloc = self.alloc,
            .map = try self.map.clone(),
        };
        var it = ret.map.valueIterator();
        while (it.next()) |item| {
            item.* = try item.clone(ret.alloc);
        }
        return ret;
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .map = MapT.init(alloc),
            .alloc = alloc,
        };
    }

    pub fn initFromJson(v: std.json.Value, ctx: anytype) !@This() {
        if (v != .object) return error.broken;
        var ret = init(ctx.alloc);

        var it = v.object.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.* != .string) return error.invalidKv;

            try ret.map.put(try ctx.str_store.store(item.key_ptr.*), .{
                ._string = try .init(ret.alloc, item.value_ptr.string),
                .sync = Entity.KvSync.needsSync(item.key_ptr.*),
            });
        }

        return ret;
    }

    fn printInternal(self: *Self, val: *Value, comptime fmt: []const u8, args: anytype) !void {
        self.print_buf.clearRetainingCapacity();
        try self.print_buf.writer(self.alloc).print(fmt, args);
        try val._string.set(self.alloc, self.print_buf.items);
    }

    pub fn putFloats(self: *Self, val: *Value, ed: *Editor, id: EcsT.Id, comptime count: usize, floats: [count]f32) !void {
        self.print_buf.clearRetainingCapacity();
        for (floats, 0..) |f, i| {
            self.print_buf.writer(self.alloc).print("{s}{d}", .{ if (i == 0) "" else " ", f }) catch return;
        }
        try val._string.set(self.alloc, self.print_buf.items);

        if (val.sync != .none) {
            if (try ed.ecs.getOptPtr(id, .entity)) |ent|
                try ent.setKvString(ed, id, val);
        }
    }

    pub fn serial(self: @This(), ed: *Editor, jw: anytype, id: EcsT.Id) !void {
        const eclass = blk: {
            //Not having a valid entclass should cause all kvs to be serialized.
            //We can load maps with entities we don't know about and then still serialize them correctly.
            const ent = ed.ecs.getPtr(id, .entity) catch break :blk null;
            break :blk ed.fgd_ctx.getPtr(ent.class) orelse null;
        };

        try jw.beginObject();
        {
            var it = self.map.iterator();
            while (it.next()) |item| {
                if (eclass) |entcl| {
                    if (!entcl.fields.contains(item.key_ptr.*)) //Prune fields
                        continue;
                }
                try jw.objectField(item.key_ptr.*);
                try jw.write(item.value_ptr.slice());
            }
        }
        try jw.endObject();
    }

    ///Key is not duped or freed. value is duped
    pub fn putString(self: *Self, ed: *Editor, id: EcsT.Id, key: []const u8, value: []const u8) !void {
        if (self.map.getPtr(key)) |old| {
            old.deinit(self.alloc);
            _ = self.map.remove(key);
        }
        if (try Value.initValue(self, ed, id, key, value)) |new|
            try self.map.put(key, new);
    }
    //IF initValue syncs, then there is a key put into map

    pub fn putStringNoNotify(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.map.getPtr(key)) |old|
            old.deinit(self.alloc);

        const new = try Value.initNoNotify(self.map.allocator, value);

        try self.map.put(key, new);
    }

    pub fn putStringPrintNoNotify(self: *Self, key: []const u8, comptime fmt: []const u8, args: anytype) !void {
        self.print_buf.clearRetainingCapacity();
        try self.print_buf.writer(self.alloc).print(fmt, args);
        try self.putStringNoNotify(key, self.print_buf.items);
    }

    pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
        if (self.map.get(key)) |val|
            return val.slice();
        return null;
    }

    pub fn getFloats(self: *Self, key: []const u8, comptime count: usize) ?if (count == 1) f32 else [count]f32 {
        if (self.map.get(key)) |val| {
            const flo = val.getFloats(count);
            if (count == 1)
                return flo[0];
            return flo;
        }
        return null;
    }

    pub fn getOrPutDefault(self: *Self, ecs: *EcsT, id: EcsT.Id, key: []const u8, value: []const u8) !*Value {
        const res = try self.map.getOrPut(key);
        if (!res.found_existing) {
            res.value_ptr.* = try Value.initDefault(self, ecs, id, key, value);
        }
        return res.value_ptr;
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.valueIterator();
        while (it.next()) |item|
            item.deinit(self.alloc);
        self.map.deinit();
        self.print_buf.deinit(self.alloc);
    }
};

pub const Connection = struct {
    pub const StringFmtCsv = "{[listen_event]s},{[target]s},{[input]s},{[value]s},{[delay]d},{[fire_count]d}";
    const Self = @This();
    listen_event: []const u8 = "", //Allocated by someone else (string storage)

    target: ArrayList(u8) = .{},
    input: []const u8 = "", //Allocated by strstore

    value: ArrayList(u8) = .{},
    delay: f32 = 0,
    fire_count: i32 = -1,

    _alloc: std.mem.Allocator,

    pub fn deinit(self: *Self) void {
        self.value.deinit(self._alloc);
        self.target.deinit(self._alloc);
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ ._alloc = alloc };
    }

    pub fn dupe(self: *const Self) !Self {
        return Self{
            .listen_event = self.listen_event,
            .target = try self.target.clone(self._alloc),
            .input = self.input,
            .value = try self.value.clone(self._alloc),
            .delay = self.delay,
            .fire_count = self.fire_count,
            ._alloc = self._alloc,
        };
    }

    pub fn initCsv(alloc: std.mem.Allocator, str_store: *StringStorage, csv: []const u8) !@This() {
        var it = std.mem.splitScalar(u8, csv, ',');
        const listen = it.next() orelse return error.invalid;
        const target = it.next() orelse return error.invalid;
        const input = it.next() orelse return error.invalid;
        const value = it.next() orelse return error.invalid;
        const delay = try std.fmt.parseFloat(f32, it.next() orelse return error.invalid);
        const fc = try std.fmt.parseInt(i32, it.next() orelse return error.invalid, 10);

        var ret = init(alloc);
        ret.listen_event = try str_store.store(listen);
        try ret.target.appendSlice(ret._alloc, target);
        ret.input = try str_store.store(input);
        try ret.value.appendSlice(ret._alloc, value);
        ret.delay = delay;
        ret.fire_count = fc;
        return ret;
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, con: vmf.Connection, str_store: anytype) !@This() {
        var ret = init(alloc);
        ret.listen_event = try str_store.store(con.listen_event);
        try ret.target.appendSlice(ret._alloc, con.target);
        ret.input = try str_store.store(con.input);
        try ret.value.appendSlice(ret._alloc, con.value);
        ret.delay = con.delay;
        ret.fire_count = con.fire_count;
        return ret;
    }

    pub fn initFromJson(v: std.json.Value, ctx: anytype) !@This() {
        const H = struct {
            fn getString(val: *const std.json.ObjectMap, name: []const u8) ![]const u8 {
                if (val.get(name)) |o| {
                    if (o != .string) return error.invalidTypeForConnection;
                    return o.string;
                }
                return "";
            }
            fn getNum(val: *const std.json.ObjectMap, name: []const u8, default: anytype) !@TypeOf(default) {
                switch (val.get(name) orelse return default) {
                    .integer => |i| return std.math.lossyCast(@TypeOf(default), i),
                    .float => |f| return std.math.lossyCast(@TypeOf(default), f),
                    else => return error.invalidTypeForConnection,
                }
            }
        };
        if (v != .object) return error.broken;
        var ret = init(ctx.alloc);

        ret.listen_event = try ctx.str_store.store(try H.getString(&v.object, "listen_event"));
        ret.input = try ctx.str_store.store(try H.getString(&v.object, "input"));
        try ret.target.appendSlice(ctx.alloc, try H.getString(&v.object, "target"));
        try ret.value.appendSlice(ctx.alloc, try H.getString(&v.object, "value"));

        ret.delay = try H.getNum(&v.object, "delay", ret.delay);
        ret.fire_count = try H.getNum(&v.object, "fire_count", ret.fire_count);
        return ret;
    }
};

pub const Connections = struct {
    const Self = @This();

    _alloc: std.mem.Allocator,
    list: ArrayList(Connection) = .{},

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            ._alloc = alloc,
        };
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, con: *const vmf.Connections, strstore: anytype) !Self {
        var ret = Connections{ ._alloc = alloc };
        if (!con.is_init)
            return ret;

        for (con.list.items) |co| {
            try ret.list.append(alloc, try Connection.initFromVmf(alloc, co, strstore));
        }
        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.list.items) |*item|
            item.deinit();
        self.list.deinit(self._alloc);
    }

    pub fn addEmpty(self: *Self) !void {
        try self.list.append(self._alloc, Connection.init(self._alloc));
    }

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var new = try self.list.clone(self._alloc);
        for (self.list.items, 0..) |old, i| {
            new.items[i] = .{
                ._alloc = self._alloc,
                //Explictly copy fields over to prevent bugs if alloced fields are added.
                .listen_event = old.listen_event,
                .input = old.input,
                .delay = old.delay,
                .fire_count = old.fire_count,
                .value = try old.value.clone(self._alloc),
                .target = try old.target.clone(self._alloc),
            };
        }
        return .{ .list = new, ._alloc = self._alloc };
    }
};
