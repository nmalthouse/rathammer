/// This file is where all the core data types are for those interested
const std = @import("std");
const graph = @import("graph");
const profile = @import("profile.zig");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const Quat = graph.za.Quat;
const vpk = @import("vpk.zig");
const vmf = @import("vmf.zig");
const util3d = @import("util_3d.zig");
const meshutil = graph.meshutil;
const thread_pool = @import("thread_pool.zig");
const Editor = @import("editor.zig").Context;
const DrawCtx = graph.ImmediateDrawingContext;
const VisGroups = @import("visgroup.zig");
const prim_gen = @import("primitive_gen.zig");
const csg = @import("csg.zig");
pub const SparseSet = graph.SparseSet;
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
pub const EcsT = graph.Ecs.Registry(&.{
    Comp("group", Groups.Group),
    Comp("bounding_box", AABB),
    Comp("solid", Solid),
    Comp("entity", Entity),
    Comp("displacements", Displacements),
    Comp("key_values", KeyValues),
    Comp("invisible", struct {
        pub const ECS_NO_SERIAL = void;
        pub fn dupe(_: *@This(), _: anytype, _: anytype) !@This() {
            return .{};
        }
    }),
    Comp("editor_info", EditorInfo),
    Comp("deleted", struct {
        pub const ECS_NO_SERIAL = void;
        pub fn dupe(_: *@This(), _: anytype, _: anytype) !@This() {
            return .{};
        }
    }),
    Comp("connections", Connections),
    //TODO is this shit even used. delete
    Comp("ladder_translate_hull", struct {
        //For the ladder entity.
        //We need to put two bb's that are far from the actual entity
        //Just need one bb that exists as bb
        ladder_ent: ?EcsT.Id = null,
        pub const ECS_NO_SERIAL = void;
        pub fn dupe(_: *@This(), _: anytype, _: anytype) !@This() {
            return .{};
        }
    }),
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

        pub fn serial(self: @This(), _: anytype, jw: anytype) !void {
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
    lines_index: std.ArrayList(u32),

    pub fn init(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, tex: graph.Texture) Self {
        var ret = MeshBatch{
            .mesh = meshutil.Mesh.init(alloc, tex.id),
            .tex_res_id = tex_id,
            .tex = tex,
            .contains = std.AutoHashMap(EcsT.Id, void).init(alloc),
            .notify_vt = .{ .notify_fn = &notify },
            .lines_vao = 0,
            .lines_ebo = 0,
            .lines_index = std.ArrayList(u32).init(alloc),
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

        pub fn needsSync(key: []const u8) @This() {
            return std.meta.stringToEnum(@This(), key) orelse .none;
        }
    };

    origin: Vec3 = Vec3.zero(),
    angle: Vec3 = Vec3.zero(),
    class: []const u8 = "",

    /// Fields with _ are not serialized
    /// These are used to draw the entity
    _model_id: ?vpk.VpkResId = null,
    _sprite: ?vpk.VpkResId = null,

    //CRAP FOr the FUCKING LADDERS. THE ONLY FUCKING THING THAT REQUIRES TWO HULLS AND ONLY fucking HALF LIFE 2
    //has the fucking FUNC_USABLE LADDERS GODDAMMIT.
    _multi_bb_index: bool = false,

    pub fn dupe(self: *const @This(), ecs: *EcsT, new_id: EcsT.Id) anyerror!@This() {
        _ = ecs;
        _ = new_id;
        return self.*;
    }

    pub fn getKvString(self: *@This(), kind: KvSync, val: *KeyValues.Value) !void {
        switch (kind) {
            .none => {}, //no op
            .origin => try val.printInternal("{d} {d} {d}", .{ self.origin.x(), self.origin.y(), self.origin.z() }),
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
            .none => {},
        }
    }

    pub fn setOrigin(self: *@This(), ed: *Editor, self_id: EcsT.Id, origin: Vec3) !void {
        self.origin = origin;
        const bb = try ed.ecs.getPtr(self_id, .bounding_box);
        bb.setFromOrigin(origin);
        if (try ed.ecs.getOptPtr(self_id, .key_values)) |kvs| {
            try kvs.putStringNoNotify("origin", try ed.printScratch("{d} {d} {d}", .{ origin.x(), origin.y(), origin.z() }));
            //If we are a ladder, update that
            if (self._multi_bb_index) {
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
                try kvs.putStringNoNotify("pitch", try editor.printScratch("{d}", .{-angle.x()}));
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
        self._multi_bb_index = false;

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
                    self._multi_bb_index = true;
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
    }) !void {
        //if(ent._multi_bb_index != null) {
        //    draw.cube(ent.origin)
        //}
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

    index: std.ArrayList(u32) = undefined,
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
    pub fn deinit(self: @This()) void {
        self.index.deinit();
    }

    pub fn dupe(self: *@This()) !@This() {
        var ret = self.*;
        ret.index = try self.index.clone();
        return ret;
    }

    pub fn flipNormal(self: *@This()) void {
        std.mem.reverse(u32, self.index.items);
    }

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .index = std.ArrayList(u32).init(alloc),
        };
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

        try mesh.vertices.ensureUnusedCapacity(side.index.items.len);

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
            try mesh.vertices.append(.{
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
        try mesh.indicies.appendSlice(indexs);
    }

    pub fn serial(self: @This(), editor: *Editor, jw: anytype) !void {
        try jw.beginObject();
        {
            try jw.objectField("index");
            try jw.beginArray();
            var last = self.index.getLastOrNull() orelse return error.invalidSide;
            // verticies should never be the same as a neighbor.
            // This exists because of some bug in csg, which very occasionally generates an extra index
            for (self.index.items) |id| {
                if (id == last)
                    continue;
                try jw.write(id);
                last = id;
            }
            try jw.endArray();
            try jw.objectField("u");
            try editor.writeComponentToJson(jw, self.u);
            try jw.objectField("v");
            try editor.writeComponentToJson(jw, self.v);
            try jw.objectField("tex_id");
            try editor.writeComponentToJson(jw, self.tex_id);
            try jw.objectField("lightmapscale");
            try editor.writeComponentToJson(jw, self.lightmapscale);
            try jw.objectField("smoothing_groups");
            try editor.writeComponentToJson(jw, self.smoothing_groups);
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
    sides: std.ArrayList(Side) = undefined,
    verts: std.ArrayList(Vec3) = undefined,

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    pub fn init(alloc: std.mem.Allocator) Solid {
        return .{ .sides = std.ArrayList(Side).init(alloc), .verts = std.ArrayList(Vec3).init(alloc) };
    }

    //pub fn initFromJson(v: std.json.Value, editor: *Context) !@This() {
    //    //var ret = init(editor.alloc);
    //    return editor.readComponentFromJson(v, Self);
    //}

    pub fn dupe(self: *const Self, _: anytype, _: anytype) !Self {
        const ret_sides = try self.sides.clone();
        for (ret_sides.items) |*side| {
            const ind = try side.index.clone();
            side.index = ind;
        }
        return .{
            .sides = ret_sides,
            .verts = try self.verts.clone(),
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

    pub fn initFromPrimitive(alloc: std.mem.Allocator, verts: []const Vec3, faces: []const std.ArrayList(u32), tex_id: vpk.VpkResId, offset: Vec3, rot: graph.za.Mat3) !Solid {
        var ret = init(alloc);
        //TODO prune the verts
        for (verts) |v|
            try ret.verts.append(rot.mulByVec3(v).add(offset));

        for (faces) |face| {
            var ind = std.ArrayList(u32).init(alloc);
            try ind.appendSlice(face.items);

            try ret.sides.append(.{
                .index = ind,
                .u = .{},
                .v = .{},
                .material = "",
                .tex_id = tex_id,
            });
            const side = &ret.sides.items[ret.sides.items.len - 1];
            const norm = side.normal(&ret);
            side.resetUv(norm, true);
        }
        try ret.optimizeMesh();
        return ret;
    }

    //Prune duplicate verticies and reindex
    pub fn optimizeMesh(self: *Self) !void {
        var vmap = csg.VecMap.init(self.sides.allocator);
        defer vmap.deinit();

        for (self.sides.items) |side| {
            for (side.index.items) |*ind|
                ind.* = try vmap.put(self.verts.items[ind.*]);
        }
        if (vmap.verts.items.len < self.verts.items.len) {
            std.debug.print("OPTIMIZED {d} {d} \n", .{
                self.verts.items.len - vmap.verts.items.len,
                vmap.verts.items.len / self.verts.items.len * 100,
            });
            self.verts.shrinkAndFree(vmap.verts.items.len);
        }
        try self.verts.resize(vmap.verts.items.len);
        @memcpy(self.verts.items, vmap.verts.items);
        //TODO
    }

    pub fn initFromCube(alloc: std.mem.Allocator, v1: Vec3, v2: Vec3, tex_id: vpk.VpkResId) !Solid {
        const MIN_VALID_VOLUME = 1;
        var ret = init(alloc);
        //const Va = std.ArrayList(Vec3);
        //const Ia = std.ArrayList(u32);
        const cc = util3d.cubeFromBounds(v1, v2);
        const N = Vec3.new;
        const o = cc[0];
        const e = cc[1];

        const volume = e.x() * e.y() * e.z();
        if (volume < MIN_VALID_VOLUME)
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
        try ret.verts.appendSlice(&verts);
        for (vis, 0..) |face, i| {
            var ind = std.ArrayList(u32).init(alloc);
            //try ind.appendSlice(&.{ 1, 2, 0, 2, 3, 0 });

            try ind.appendSlice(&face);
            try ret.sides.append(.{
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
        for (self.sides.items) |side|
            side.deinit();
        self.sides.deinit();
        self.verts.deinit();
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
        for (self.sides.items) |*side| {
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;

            if (rot) |quat| {
                side.u.axis = quat.rotateVec(side.u.axis);
                side.v.axis = quat.rotateVec(side.v.axis);
            }
        }
        try self.rebuild(id, editor);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            batch.*.is_dirty = true;
            _ = batch.*.contains.remove(id);
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

    pub fn getSidePtr(self: *Self, side_id: ?u32) ?*Side {
        if (side_id) |si| {
            if (si >= self.sides.items.len) return null;
            return &self.sides.items[si];
        }
        return null;
    }

    /// only_verts contains a list of vertex indices to apply offset to.
    /// If it is null, all vertices are offset
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Editor, offset: Vec3, only_verts: ?[]const u32) !void {
        for (self.sides.items) |side| {
            if (side.omit_from_batch)
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try editor.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const uvs = try editor.csgctx.calcUVCoordsIndexed(
                self.verts.items,
                side.index.items,
                side,
                @intCast(side.tw),
                @intCast(side.th),
                Vec3.zero(),
            );
            const ioffset = batch.vertices.items.len;
            for (side.index.items, 0..) |vi, i| {
                const v = self.verts.items[vi];

                var off = offset;
                if (only_verts) |ov| {
                    if (std.mem.indexOfScalar(u32, ov, vi) == null)
                        off = Vec3.zero();
                }

                try batch.vertices.append(.{
                    .pos = .{
                        .x = v.x() + off.x(),
                        .y = v.y() + off.y(),
                        .z = v.z() + off.z(),
                    },
                    .uv = .{
                        .x = uvs[i].x(),
                        .y = uvs[i].y(),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset));
            try batch.indicies.appendSlice(indexs);
        }
    }

    //the vertexOffsetCb is given the vertex, the side_index, the index
    pub fn drawImmediateCustom(self: *Self, draw: *DrawCtx, ed: *Editor, user: anytype, vertOffsetCb: fn (@TypeOf(user), Vec3, u32, u32) Vec3) !void {
        for (self.sides.items, 0..) |side, s_i| {
            if (side.omit_from_batch) //don't draw this sideit
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try ed.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const uvs = try ed.csgctx.calcUVCoordsIndexed(
                self.verts.items,
                side.index.items,
                side,
                @intCast(side.tw),
                @intCast(side.th),
                Vec3.zero(),
            );
            const ioffset = batch.vertices.items.len;
            for (side.index.items, 0..) |vi, i| {
                const v = self.verts.items[vi];

                const off = vertOffsetCb(user, v, @intCast(s_i), @intCast(i));

                try batch.vertices.append(.{
                    .pos = .{
                        .x = v.x() + off.x(),
                        .y = v.y() + off.y(),
                        .z = v.z() + off.z(),
                    },
                    .uv = .{
                        .x = uvs[i].x(),
                        .y = uvs[i].y(),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try ed.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset));
            try batch.indicies.appendSlice(indexs);
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
    disps: std.ArrayList(Displacement) = undefined,

    //Solid.sides index map into disps
    sides: std.ArrayList(?usize) = undefined,

    pub fn init(alloc: std.mem.Allocator, side_count: usize) !Self {
        var ret = Self{
            .disps = std.ArrayList(Displacement).init(alloc),
            .sides = std.ArrayList(?usize).init(alloc),
        };
        try ret.sides.appendNTimes(null, side_count);

        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.disps.items) |*disp|
            disp.deinit();
        self.sides.deinit();
        self.disps.deinit();
    }

    pub fn dupe(self: *Self, ecs: *EcsT, new_id: EcsT.Id) !Self {
        const ret = Self{
            .disps = try self.disps.clone(),
            .sides = try self.sides.clone(),
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
            try self.sides.appendNTimes(null, side_id - self.sides.items.len);
        }
        const disp_index = self.disps.items.len;
        try self.disps.append(disp);
        if (self.sides.items[side_id]) |ex_disp| {
            std.debug.print("CLOBBERING A DISPLACMENT, THIS MAY BE BAD\n", .{});
            self.disps.items[ex_disp].deinit();
            self.sides.items[side_id] = null;
        }

        self.sides.items[side_id] = disp_index;
    }
};

//TRANSLATE the startposition too
//TODO make the displacment component an array of Displacment rather than making a seperate entity
pub const Displacement = struct {
    pub const VectorRow = std.ArrayList(Vec3);
    pub const ScalarRow = std.ArrayList(f32);
    const Self = @This();
    _verts: std.ArrayList(Vec3) = undefined,
    _index: std.ArrayList(u32) = undefined,
    tex_id: vpk.VpkResId = 0,

    //DEPRECATION
    parent_side_i: usize = 0,

    vert_start_i: usize = 0,
    power: u32 = 0,

    normals: VectorRow = undefined,
    offsets: VectorRow = undefined,
    normal_offsets: VectorRow = undefined,
    dists: ScalarRow = undefined,
    alphas: ScalarRow = undefined,

    //start_pos: Vec3 = Vec3.zero(),
    elevation: f32 = 0,
    //TODO do the tri_tags?
    //tri_tags: ScalarRow = undefined,

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var ret = self.*;
        ret._verts = try self._verts.clone();
        ret._index = try self._index.clone();
        ret.normals = try self.normals.clone();
        ret.offsets = try self.offsets.clone();
        ret.normal_offsets = try self.normal_offsets.clone();
        ret.dists = try self.dists.clone();
        ret.alphas = try self.alphas.clone();

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
            ._verts = std.ArrayList(Vec3).init(alloc),
            ._index = std.ArrayList(u32).init(alloc),
            .tex_id = tex_id,
            .parent_side_i = parent_s,
            .power = power,
            .normals = VectorRow.init(alloc),
            .offsets = VectorRow.init(alloc),
            .normal_offsets = VectorRow.init(alloc),

            .dists = ScalarRow.init(alloc),
            .alphas = ScalarRow.init(alloc),
        };

        try ret.normals.appendNTimes(normal, count);
        try ret.offsets.appendNTimes(Vec3.zero(), count);
        try ret.normal_offsets.appendNTimes(normal, count);
        try ret.dists.appendNTimes(0, count);
        try ret.alphas.appendNTimes(0, count);

        return ret;
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, parent_s: usize, dispinfo: *const vmf.DispInfo) !Self {
        return .{
            ._verts = std.ArrayList(Vec3).init(alloc),
            ._index = std.ArrayList(u32).init(alloc),
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

        var new_norms = VectorRow.init(self.normals.allocator);
        try new_norms.resize(vper_row * vper_row);
        avgVert(Vec3, self.normals.items, new_norms.items, H.avgVec, old_v);

        var new_off = VectorRow.init(self.normals.allocator);
        try new_off.resize(vper_row * vper_row);
        avgVert(Vec3, self.offsets.items, new_off.items, H.avgVec, old_v);

        var new_noff = VectorRow.init(self.normals.allocator);
        try new_noff.resize(vper_row * vper_row);
        avgVert(Vec3, self.normal_offsets.items, new_noff.items, H.avgVec, old_v);

        var new_dist = ScalarRow.init(self.normals.allocator);
        try new_dist.resize(vper_row * vper_row);
        avgVert(f32, self.dists.items, new_dist.items, H.avgFloat, old_v);

        var new_alpha = ScalarRow.init(self.normals.allocator);
        try new_alpha.resize(vper_row * vper_row);
        avgVert(f32, self.alphas.items, new_alpha.items, H.avgFloat, old_v);

        self.normals.deinit();
        self.normals = new_norms;

        self.offsets.deinit();
        self.offsets = new_off;

        self.normal_offsets.deinit();
        self.normal_offsets = new_noff;

        self.dists.deinit();
        self.dists = new_dist;

        self.alphas.deinit();
        self.alphas = new_alpha;

        try self.markForRebuild(id, ed);
    }

    pub fn deinit(self: *Self) void {
        self._verts.deinit();
        self._index.deinit();

        self.normals.deinit();
        self.offsets.deinit();
        self.normal_offsets.deinit();
        self.dists.deinit();
        self.alphas.deinit();
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
        try mesh.vertices.ensureUnusedCapacity(self._verts.items.len);
        try mesh.indicies.ensureUnusedCapacity(self._index.items.len);
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

            try mesh.vertices.append(.{
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
            try mesh.indicies.append(ind + @as(u32, @intCast(offset)));
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

            try batch.vertices.append(.{
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
            try batch.indicies.append(ind + @as(u32, @intCast(offset)));
        }
    }
};

/// An explination of how visgroups work in RatHammer.
/// entities can optionally have a EditorInfo component attached.
/// This vis_mask is a bitmask which indexes into the Editor.visgroups masks.
///
/// When the active visgroups change the editor iterates all editor_info components and attached an "invisible" component.
/// Care must be taken to access components by editor.getComponent rather than the registery methods as
/// getComponent returns null for invisible entites.
/// The exact same mechanism is used for deletion of entities, a "deleted" component is attached and removed, rather than actually deleting things.
pub const EditorInfo = struct {
    //pub const ECS_NO_SERIAL = void;
    vis_mask: VisGroups.BitSetT = VisGroups.BitSetT.initEmpty(),

    pub fn dupe(a: *@This(), _: anytype, _: anytype) !@This() {
        return a.*;
    }

    pub fn initFromJson(v: std.json.Value, _: anytype) !@This() {
        if (v != .string) return error.invalidEditorInfo;

        const str = v.string;
        if (std.mem.indexOfScalar(u8, str, '_')) |ind| {
            var bits = @This(){ .vis_mask = VisGroups.BitSetT.initEmpty() };
            const first = try std.fmt.parseInt(VisGroups.BitSetT.MaskInt, str[0..ind], 16);
            const second = try std.fmt.parseInt(VisGroups.BitSetT.MaskInt, str[ind + 1 ..], 16);
            bits.vis_mask.masks[0] = first;
            bits.vis_mask.masks[1] = second;
            return bits;
        }

        return error.invalidEditorInfo;
    }
    pub fn serial(self: @This(), _: *Editor, jw: anytype) !void {
        const mask_count = self.vis_mask.masks.len;
        if (mask_count != 2)
            @compileError("fix this lol");
        try jw.print("\"{x}_{x}\"", .{ self.vis_mask.masks[0], self.vis_mask.masks[1] });
    }
};

//TODO Storing the damn strings
//having hundreds of arraylists is probably slow.,
//most kvs are small < 16bytes
//on x64 an array list is 40bytes
//for now just use array list
//
// Storing everything as a string keeps storage simple and makes direct copy and paste possible.
// Manipulating strings as arrays of numbers is annoying however.
// we need to make the gui have some keyboard input stuff.
// selecting a widget using keyboard.
// pasting into a widget
//
// user selects kv "_light"
// a red box is drawn around widget to indicate focus.
// user press ctrl-v with the string "255 255 255 800" in clipboard.
// the relevant get filled out.
pub const KeyValues = struct {
    const Value = struct {
        _string: std.ArrayList(u8),

        // Certain kv's "model, angles, origin" must be kept in sync with the entity component
        sync: Entity.KvSync,

        pub fn clone(self: *@This()) !@This() {
            var ret = self.*;
            ret._string = try self._string.clone();
            return ret;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self._string.items;
        }

        pub fn deinit(self: *@This()) void {
            self._string.deinit();
        }

        pub fn getFloats(self: *const @This(), comptime count: usize) [count]f32 {
            var it = std.mem.tokenizeScalar(u8, self._string.items, ' ');
            var ret: [count]f32 = undefined;
            for (0..count) |i| {
                ret[i] = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
            }
            return ret;
        }

        fn initNoNotify(alloc: std.mem.Allocator, value: []const u8) !@This() {
            var ret = @This(){
                ._string = std.ArrayList(u8).init(alloc),
                .sync = .none,
            };
            try ret._string.appendSlice(value);
            return ret;
        }

        /// Create a new value, if it is a synced field get the value from the entity, otherwise set it to 'value'
        pub fn initDefault(alloc: std.mem.Allocator, ecs: *EcsT, id: EcsT.Id, key: []const u8, value: []const u8) !@This() {
            var ret = @This(){
                ._string = std.ArrayList(u8).init(alloc),
                .sync = Entity.KvSync.needsSync(key),
            };
            if (ret.sync != .none) {
                //Replace the default with whatever the entity has
                if (try ecs.getOptPtr(id, .entity)) |ent| {
                    try ent.getKvString(ret.sync, &ret);
                }
            } else {
                try ret._string.appendSlice(value);
            }
            return ret;
        }

        /// Create a new value with 'value' and notify entity if synced
        fn initValue(alloc: std.mem.Allocator, ed: *Editor, id: EcsT.Id, key: []const u8, value: []const u8) !?@This() {
            var ret = @This(){
                ._string = std.ArrayList(u8).init(alloc),
                .sync = Entity.KvSync.needsSync(key),
            };
            try ret._string.appendSlice(value);
            if (ret.sync != .none) {
                //Replace the default with whatever the entity has
                if (try ed.ecs.getOptPtr(id, .entity)) |ent| {
                    try ent.setKvString(ed, id, &ret);
                    ret._string.deinit();
                    return null;
                }
            }
            return ret;
        }

        fn printInternal(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            self._string.clearRetainingCapacity();
            try self._string.writer().print(fmt, args);
        }

        pub fn printFloats(self: *@This(), ed: *Editor, id: EcsT.Id, comptime count: usize, floats: [count]f32) !void {
            self._string.clearRetainingCapacity();
            for (floats, 0..) |f, i| {
                self._string.writer().print("{s}{d}", .{ if (i == 0) "" else " ", f }) catch return;
            }
            if (self.sync != .none) {
                if (try ed.ecs.getOptPtr(id, .entity)) |ent|
                    try ent.setKvString(ed, id, self);
            }
        }
    };
    const Self = @This();
    const MapT = std.StringHashMap(Value);
    map: MapT,

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var ret = Self{
            .map = try self.map.clone(),
        };
        var it = ret.map.valueIterator();
        while (it.next()) |item| {
            item.* = try item.clone();
        }
        return ret;
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .map = MapT.init(alloc),
        };
    }

    pub fn initFromJson(v: std.json.Value, ctx: anytype) !@This() {
        if (v != .object) return error.broken;
        var ret = init(ctx.alloc);

        var it = v.object.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.* != .string) return error.invalidKv;
            var new_list = std.ArrayList(u8).init(ctx.alloc);
            try new_list.appendSlice(item.value_ptr.string);
            try ret.map.put(try ctx.str_store.store(item.key_ptr.*), .{
                ._string = new_list,
                .sync = Entity.KvSync.needsSync(item.key_ptr.*),
            });
        }

        return ret;
    }

    pub fn serial(self: @This(), _: *Editor, jw: anytype) !void {
        //Pruning fields,
        //we need ent class
        try jw.beginObject();
        {
            var it = self.map.iterator();
            while (it.next()) |item| {
                try jw.objectField(item.key_ptr.*);
                try jw.write(item.value_ptr.slice());
            }
        }
        try jw.endObject();
    }

    ///Key is not duped or freed. value is duped
    pub fn putString(self: *Self, ed: *Editor, id: EcsT.Id, key: []const u8, value: []const u8) !void {
        if (self.map.getPtr(key)) |old| {
            old.deinit();
            _ = self.map.remove(key);
        }
        if (try Value.initValue(self.map.allocator, ed, id, key, value)) |new|
            try self.map.put(key, new);
    }
    //IF initValue syncs, then there is a key put into map

    pub fn putStringNoNotify(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.map.getPtr(key)) |old|
            old.deinit();

        const new = try Value.initNoNotify(self.map.allocator, value);

        try self.map.put(key, new);
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
            res.value_ptr.* = try Value.initDefault(self.map.allocator, ecs, id, key, value);
        }
        return res.value_ptr;
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.valueIterator();
        while (it.next()) |item|
            item.deinit();
        self.map.deinit();
    }
};

pub const Connection = struct {
    const Self = @This();
    listen_event: []const u8, //Allocated by someone else (string storage)

    target: std.ArrayList(u8),
    input: []const u8, //Allocated by strstore

    value: std.ArrayList(u8),
    delay: f32,
    fire_count: i32,

    pub fn deinit(self: *Self) void {
        self.value.deinit();
        self.target.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .target = std.ArrayList(u8).init(alloc),
            .value = std.ArrayList(u8).init(alloc),
            .listen_event = "",
            .input = "",
            .delay = 0,
            .fire_count = -1,
        };
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, con: vmf.Connection, str_store: anytype) !@This() {
        var ret = init(alloc);
        ret.listen_event = try str_store.store(con.listen_event);
        try ret.target.appendSlice(con.target);
        ret.input = try str_store.store(con.input);
        try ret.value.appendSlice(con.value);
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
        try ret.target.appendSlice(try H.getString(&v.object, "target"));
        try ret.value.appendSlice(try H.getString(&v.object, "value"));

        ret.delay = try H.getNum(&v.object, "delay", ret.delay);
        ret.fire_count = try H.getNum(&v.object, "fire_count", ret.fire_count);
        return ret;
    }
};

pub const Connections = struct {
    const Self = @This();

    list: std.ArrayList(Connection) = undefined,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .list = std.ArrayList(Connection).init(alloc),
        };
    }

    pub fn initFromVmf(alloc: std.mem.Allocator, con: *const vmf.Connections, strstore: anytype) !Self {
        var ret = @This(){ .list = std.ArrayList(Connection).init(alloc) };
        if (!con.is_init)
            return ret;

        for (con.list.items) |co| {
            try ret.list.append(try Connection.initFromVmf(alloc, co, strstore));
        }
        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.list.items) |*item|
            item.deinit();
        self.list.deinit();
    }

    pub fn addEmpty(self: *Self) !void {
        try self.list.append(Connection.init(self.list.allocator));
    }

    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var new = try self.list.clone();
        for (self.list.items, 0..) |old, i| {
            new.items[i] = .{
                //Explictly copy fields over to prevent bugs if alloced fields are added.
                .listen_event = old.listen_event,
                .input = old.input,
                .delay = old.delay,
                .fire_count = old.fire_count,
                .value = try old.value.clone(),
                .target = try old.target.clone(),
            };
        }
        return .{ .list = new };
    }
};
