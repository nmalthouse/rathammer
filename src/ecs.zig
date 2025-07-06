const std = @import("std");
const graph = @import("graph");
const profile = @import("profile.zig");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const vpk = @import("vpk.zig");
const vmf = @import("vmf.zig");
const util3d = @import("util_3d.zig");
const meshutil = graph.meshutil;
const thread_pool = @import("thread_pool.zig");
const Editor = @import("editor.zig").Context;
const DrawCtx = graph.ImmediateDrawingContext;
const VisGroups = @import("visgroup.zig");
const prim_gen = @import("primitive_gen.zig");
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
    Comp("displacement", Displacement),
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
});

/// Groups are used to group entities together. Any entities can be grouped but it is mainly used for brush entities
/// An entity can only belong to one group at a time.
///
/// The editor creates a Groups which manages the mapping between a owning entity and its groupid
pub const Groups = struct {
    const Self = @This();
    pub const GroupId = u16;
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

    group_counter: u16 = 0,

    entity_mapper: std.AutoHashMap(EcsT.Id, GroupId),
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
        if (group == 0) return null;
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

    pub fn newGroup(self: *Self, owner: ?EcsT.Id) !GroupId {
        while (true) {
            self.group_counter += 1;
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

    // TODO move the notify_vt into editor and store an id so there is risk of pointer madness
    notify_vt: thread_pool.DeferredNotifyVtable,
    // Each batch needs to keep track of:
    // needs_rebuild
    // contained_solids:ent_id

    pub fn deinit(self: *@This()) void {
        self.mesh.deinit();
        //self.tex.deinit();
        self.contains.deinit();
    }

    pub fn rebuildIfDirty(self: *Self, editor: *Editor) !void {
        if (self.is_dirty) {
            self.is_dirty = false;
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
        var it = self.contains.iterator();
        while (it.next()) |id| {
            if (editor.ecs.getOptPtr(id.key_ptr.*, .solid) catch null) |solid| {
                for (solid.sides.items) |*side| {
                    if (side.tex_id == self.tex_res_id) {
                        try side.rebuild(solid, self, editor);
                    }
                }
            }
            if (editor.ecs.getOptPtr(id.key_ptr.*, .displacement) catch null) |disp| {
                try disp.rebuild(id.key_ptr.*, editor);
            }
        }
        self.mesh.setData();
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

pub const Entity = struct {
    origin: Vec3 = Vec3.zero(),
    angle: Vec3 = Vec3.zero(),
    class: []const u8 = "",

    /// Fields with _ are not serialized
    /// These are used to draw the entity
    _model_id: ?vpk.VpkResId = null,
    _sprite: ?vpk.VpkResId = null,

    //When we duplicate a brush entity what must happen?
    //How does selection of brush entities work?
    //there needs to be a some selection flag, 'ig' mode selects solids normally,
    //when duplicated, the parent_id is valid, care must be taken to update parent_entity.solids
    //
    //other option is groups mode, duping involves duping parent entity, duping all children and updating all state.
    //
    //function dupeSelection, checks to see if ig flag is on.
    //for each selected, if parent_id, remove self from selected, add parent to selected
    //for each new_selected dupe()
    //
    //what happens with ig on and a brush entity selected, normally brush entites can't be selected, only their solids
    //
    //duping a brush entity always does full dupe
    //
    //instead of micromanaging, set a flag, and on update recalculate all parent state things

    pub fn dupe(self: *const @This(), ecs: *EcsT, new_id: EcsT.Id) anyerror!@This() {
        _ = ecs;
        _ = new_id;
        return self.*;
    }

    pub fn setAngle(self: *@This(), editor: *Editor, self_id: EcsT.Id, angle: Vec3) !void {
        self.angle = angle;
        if (try editor.ecs.getOptPtr(self_id, .key_values)) |kvs|
            try kvs.putString("angles", try editor.printScratch("{d} {d} {d}", .{ angle.x(), angle.y(), angle.z() }));
    }

    pub fn setModel(self: *@This(), editor: *Editor, self_id: EcsT.Id, model: vpk.IdOrName) !void {
        const idAndName = try editor.vpkctx.resolveId(model) orelse return;
        self._model_id = idAndName.id;
        if (try editor.ecs.getOptPtr(self_id, .key_values)) |kvs| {
            try kvs.putString("model", idAndName.name);
        }
    }

    pub fn setClass(self: *@This(), editor: *Editor, class: []const u8) !void {
        self.class = try editor.storeString(class);

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

                if (base.studio_model.len > 0) {
                    const id = try editor.loadModel(base.studio_model);
                    if (id != 0)
                        self._model_id = id;
                }
            }
        }
    }

    pub fn drawEnt(ent: *@This(), editor: *Editor, view_3d: Mat4, draw: *DrawCtx, draw_nd: *DrawCtx, param: struct {
        frame_color: u32 = 0x00ff00ff,
        draw_model_bb: bool = false,
    }) !void {
        const ENT_RENDER_DIST = 64 * 10;
        const dist = ent.origin.distance(editor.draw_state.cam3d.pos);
        if (editor.draw_state.tog.models and dist < editor.draw_state.tog.model_render_dist) {
            if (ent._model_id) |m| {
                if (editor.models.getPtr(m)) |o_mod| {
                    if (o_mod.mesh) |mod| {
                        const mat1 = Mat4.fromTranslate(ent.origin);
                        const mat3 = mat1.mul(util3d.extrinsicEulerAnglesToMat4(ent.angle));
                        mod.drawSimple(view_3d, mat3, editor.draw_state.basic_shader);
                        if (param.draw_model_bb) {
                            const rot = util3d.extrinsicEulerAnglesToMat3(ent.angle);
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
            draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), param.frame_color);
            if (ent._sprite) |spr| {
                const isp = try editor.getTexture(spr);
                draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
            }
        }
    }
};

pub const Side = struct {
    pub const UVaxis = struct {
        axis: Vec3 = Vec3.zero(),
        trans: f32 = 0,
        scale: f32 = 0.25,
    };
    displacement_id: ?EcsT.Id = null,
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

    pub fn normal(self: *@This(), solid: *const Solid) Vec3 {
        const ind = self.index.items;
        if (ind.len < 3) return Vec3.zero();
        const v = solid.verts.items;
        return util3d.trianglePlane(.{ v[ind[0]], v[ind[1]], v[ind[2]] });
    }

    pub fn rebuild(side: *@This(), solid: *Solid, batch: *MeshBatch, editor: *Editor) !void {
        if (side.displacement_id != null) //don't draw this sideit
            return;
        side.tex_id = batch.tex_res_id;
        side.tw = batch.tex.w;
        side.th = batch.tex.h;
        const mesh = &batch.mesh;

        try mesh.vertices.ensureUnusedCapacity(side.index.items.len);

        const uvs = try editor.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
        );
        const offset = mesh.vertices.items.len;
        for (side.index.items, 0..) |v_i, i| {
            const v = solid.verts.items[v_i];
            const norm = side.normal(solid);
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

    pub fn resetUv(self: *@This(), norm: Vec3) void {
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
        //0 -> 1 2
        //1 -> 0 2
        //2 -> 1 0

        const v: u8 = if (n == 2) 0 else 2;
        const u: u8 = if (n == 1) 0 else 1;

        self.u = .{ .axis = vs[u], .trans = 0, .scale = 0.25 };
        self.v = .{ .axis = vs[v], .trans = 0, .scale = 0.25 };
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

    pub fn initFromPrimitive(alloc: std.mem.Allocator, verts: []const Vec3, faces: []const std.ArrayList(u32), tex_id: vpk.VpkResId, offset: Vec3) !Solid {
        var ret = init(alloc);
        //TODO prune the verts
        for (verts) |v|
            try ret.verts.append(v.add(offset));

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
            side.resetUv(norm);
        }
        return ret;
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

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor) !void {
        //move all verts, recompute bounds
        //for each batchid, call rebuild

        for (self.verts.items) |*vert| {
            vert.* = vert.add(vec);
        }
        for (self.sides.items) |*side| {
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;
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

    pub fn drawEdgeOutline(self: *Self, draw: *DrawCtx, edge_color: u32, point_color: u32, vec: Vec3) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(vec);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(vec);
                if (edge_color > 0)
                    draw.line3D(last, p, edge_color);
                if (point_color > 0)
                    draw.point3D(p, point_color);
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

pub const Displacement = struct {
    pub const VectorRow = std.ArrayList(Vec3);
    pub const ScalarRow = std.ArrayList(f32);
    const Self = @This();
    _verts: std.ArrayList(Vec3) = undefined,
    _index: std.ArrayList(u32) = undefined,
    tex_id: vpk.VpkResId = 0,
    parent_id: EcsT.Id = 0,
    parent_side_i: usize = 0,
    vert_start_i: usize = 0,
    power: u32 = 0,

    normals: VectorRow = undefined,
    offsets: VectorRow = undefined,
    normal_offsets: VectorRow = undefined,
    dists: ScalarRow = undefined,
    alphas: ScalarRow = undefined,

    start_pos: Vec3 = Vec3.zero(),
    elevation: f32 = 0,
    //tri_tags: ScalarRow = undefined,

    //TODO duping things with parents how
    pub fn dupe(self: *Self, _: anytype, _: anytype) !Self {
        var ret = self.*;
        ret._verts = try self._verts.clone();
        ret._index = try self._index.clone();

        return ret;
    }

    pub fn init(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, parent_: EcsT.Id, parent_s: usize, dispinfo: *const vmf.DispInfo) !Self {
        return .{
            ._verts = std.ArrayList(Vec3).init(alloc),
            ._index = std.ArrayList(u32).init(alloc),
            .tex_id = tex_id,
            .parent_id = parent_,
            .parent_side_i = parent_s,
            .power = @intCast(dispinfo.power),
            .elevation = dispinfo.elevation,

            .start_pos = dispinfo.startposition.v,
            .normals = try dispinfo.normals.clone(alloc),
            .offsets = try dispinfo.offsets.clone(alloc),
            .normal_offsets = try dispinfo.offset_normals.clone(alloc),

            .dists = try dispinfo.distances.clone(alloc),
            .alphas = try dispinfo.alphas.clone(alloc),
            //.tri_tags = ScalarRow.init(alloc),
        };
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

    pub fn rebuild(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        const batch = try editor.getOrPutMeshBatch(self.tex_id);
        batch.*.is_dirty = true;
        try batch.*.contains.put(id, {});

        self.tex_id = batch.tex_res_id;
        const solid = try editor.ecs.getOptPtr(self.parent_id, .solid) orelse return;
        if (self.parent_side_i >= solid.sides.items.len) return;
        solid.sides.items[self.parent_side_i].displacement_id = id;

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

            try mesh.vertices.append(.{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uv.x(),
                .v = uv.y(),
                .nx = 0,
                .ny = 0,
                .nz = 0,
                .color = 0xffffffff,
            });
        }
        for (self._index.items) |ind| {
            try mesh.indicies.append(ind + @as(u32, @intCast(offset)));
        }
    }
};

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
        string: std.ArrayList(u8),

        pub fn clone(self: *@This()) !@This() {
            var ret = self.*;
            ret.string = try self.string.clone();
            return ret;
        }

        pub fn deinit(self: *@This()) void {
            self.string.deinit();
        }

        pub fn getFloats(self: *@This(), comptime count: usize) [count]f32 {
            var it = std.mem.splitScalar(u8, self.string.items, ' ');
            var ret: [count]f32 = undefined;
            for (0..count) |i| {
                ret[i] = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
            }
            return ret;
        }

        pub fn printFloats(self: *@This(), comptime count: usize, floats: [count]f32) void {
            self.string.clearRetainingCapacity();
            for (floats, 0..) |f, i| {
                self.string.writer().print("{s}{d}", .{ if (i == 0) "" else " ", f }) catch return;
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
            try ret.map.put(try ctx.str_store.store(item.key_ptr.*), .{ .string = new_list });
        }

        return ret;
    }

    pub fn serial(self: @This(), _: *Editor, jw: anytype) !void {
        try jw.beginObject();
        {
            var it = self.map.iterator();
            while (it.next()) |item| {
                try jw.objectField(item.key_ptr.*);
                try jw.write(item.value_ptr.string.items);
            }
        }
        try jw.endObject();
    }

    ///Key is not duped or freed. value is duped
    pub fn putString(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.map.getPtr(key)) |old|
            old.deinit();
        var new_list = std.ArrayList(u8).init(self.map.allocator);

        try new_list.appendSlice(value);

        try self.map.put(key, .{ .string = new_list });
    }

    pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
        if (self.map.get(key)) |val|
            return val.string.items;
        return null;
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
