const std = @import("std");
const edit = @import("editor.zig");
const graph = @import("graph");
const Editor = edit.Context;
const util3d = graph.util_3d;
const Vec3 = graph.za.Vec3;
const cubeFromBounds = util3d.cubeFromBounds;
const vpk = @import("vpk.zig");
const raycast = @import("raycast_solid.zig");
const undo = @import("undo.zig");
const L = @import("locale.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const Gui = graph.Gui;
const Os9Gui = graph.gui_app.Os9Gui;
const Gizmo = @import("gizmo.zig").Gizmo;
const ecs = @import("ecs.zig");
const VtableReg = @import("vtable_reg.zig").VtableReg;
const guis = graph.RGui;
const RGui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const gridutil = @import("grid.zig");
const toolutil = @import("tool_common.zig");
const action = @import("actions.zig");
const colors = @import("colors.zig").colors;

pub const CubeDraw = @import("tools/cube_draw.zig").CubeDraw;
pub const TextureTool = @import("tools/texture.zig").TextureTool;
pub const Translate = @import("tools/translate.zig").Translate;
pub const Clipping = @import("tools/clipping.zig").Clipping;
pub const VertexTranslate = @import("tools/vertex.zig").VertexTranslate;

pub const Inspector = @import("windows/inspector.zig").InspectorWindow;
pub const ToolRegistry = VtableReg(i3DTool);
pub const ToolReg = ToolRegistry.TableReg;
pub const initToolReg = ToolRegistry.initTableReg;

/// Tools are singleton.
/// When a tool is switched to a focus event is sent to the tool.
/// Switching to the same tool -> reFocus
/// switching to a different tool -> unFocus
///
/// The runTool and runTool2D functions may get called more than once per frame,
/// If a tool is active in one view and the user moves to a different view a view_changed event is sent
pub const i3DTool = struct {
    deinit_fn: *const fn (*@This(), std.mem.Allocator) void,

    runTool_fn: *const fn (*@This(), ToolData, *Editor) ToolError!void,
    tool_icon_fn: *const fn (*@This(), *DrawCtx, *Editor, graph.Rect) void,

    runTool_2d_fn: ?*const fn (*@This(), ToolData, *Editor) ToolError!void = null,
    gui_build_cb: ?*const fn (*@This(), *Inspector, *iArea, *RGui, *iWindow) void = null,
    event_fn: ?*const fn (*@This(), ToolEvent, *Editor) void = null,

    selected_solid_edge_color: u32 = 0xff00ff,
    selected_solid_point_color: u32 = 0,
    selected_bb_color: u32 = 0xff00ff,

    pub fn drawSelectedOutline(self: *@This(), ed: *Editor, draw: *graph.ImmediateDrawingContext, selected: []const ecs.EcsT.Id, edge_size: f32, point_size: f32, offset: Vec3) void {
        draw.ensurePoint3DBatch(point_size) catch return;
        draw.ensureLine3DBatch(edge_size) catch return;
        const line_batch = draw.getLine3DBatch(edge_size) orelse return;
        const point_batch = draw.getPoint3DBatch(point_size) orelse return;

        for (selected) |sel| {
            if (ed.getComponent(sel, .solid)) |solid| {
                solid.drawEdgeOutlineFast(
                    line_batch,
                    point_batch,
                    offset,
                    self.selected_solid_edge_color,
                    self.selected_solid_point_color,
                );
            }
        }
    }
};

pub const ToolEvent = enum {
    focus,
    reFocus,
    view_changed,
    unFocus,
};

pub const ToolError = error{
    fatal,
    nonfatal,
};

/// Everything required to be a tool:
const ExampleTool = struct {
    /// This field gets set when calling ToolRegistry.register(ExampleTool);
    /// Allows code to reference tools by type at runtime.
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    /// Called when ToolRegistry.register(@This()) is called
    pub fn create(_: std.mem.Allocator) *i3DTool {}
    //implement functions to fill out all non optional fields of i3DTool
};

pub const ToolData = struct {
    view_3d: *const graph.za.Mat4,
    cam2d: ?*const graph.Camera2D = null,
    screen_area: graph.Rect,
    draw: *DrawCtx,
    text_param: graph.ImmediateDrawingContext.TextParam,
};

//TODO How do tools register keybindings?

pub const FastFaceManip = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;

    vt: i3DTool,

    state: enum {
        start,
        active,
    } = .start,
    face_id: i32 = -1,
    start: Vec3 = Vec3.zero(),
    right: bool = false,
    main_id: ?ecs.EcsT.Id = null,

    draw_grid: bool = false,
    draw_text: bool = true,

    selected: std.ArrayListUnmanaged(action.SelectedSide) = .{},
    alloc: std.mem.Allocator,

    fn reset(self: *@This()) void {
        self.face_id = -1;
        self.state = .start;
        self.right = false;
        self.selected.clearRetainingCapacity();
    }

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .event_fn = &event,
                .gui_build_cb = &buildGui,
                .selected_solid_edge_color = 0xf7_a94a_af,
                .selected_solid_point_color = 0xff0000ff,
            },
            .alloc = alloc,
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("fast_face_manip.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.selected.deinit(self.alloc);
        alloc.destroy(self);
    }
    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runToolErr(td, editor) catch return error.fatal;
    }

    pub fn event(vt: *i3DTool, ev: ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus => {
                self.reset();
            },
            else => {},
        }
    }

    pub fn runToolErr(self: *@This(), td: ToolData, editor: *Editor) !void {
        const draw_nd = &editor.draw_state.ctx;
        const selected_slice = editor.getSelected();

        const rm = editor.edit_state.rmouse;
        const lm = editor.edit_state.lmouse;
        switch (self.state) {
            .start => {
                if (rm == .rising or lm == .rising) {
                    self.right = rm == .rising;
                    const rc = editor.camRay(td.screen_area, td.view_3d.*);
                    editor.rayctx.reset();
                    for (selected_slice) |s_id| {
                        try editor.rayctx.addPotentialSolid(&editor.ecs, rc[0], rc[1], &editor.csgctx, s_id);
                    }
                    const pot = editor.rayctx.sortFine();
                    if (pot.len > 0) {
                        const rci = if (editor.edit_state.rmouse == .rising) @min(1, pot.len - 1) else 0;
                        const p = pot[rci];
                        const solid = editor.getComponent(p.id, .solid) orelse return;
                        self.main_id = p.id;
                        self.face_id = @intCast(p.side_id orelse return);
                        self.state = .active;
                        self.start = p.point;
                        const norm = solid.sides.items[@intCast(self.face_id)].normal(solid);
                        const NORM_THRESH = 0.99;
                        for (selected_slice) |other| {
                            if (editor.getComponent(other, .solid)) |o_solid| {
                                for (o_solid.sides.items, 0..) |*side, fi| {
                                    if (norm.dot(side.normal(o_solid)) > NORM_THRESH) {
                                        //if (init_plane.eql(side.normal(o_solid))) {
                                        try self.selected.append(self.alloc, .{ .id = other, .side_i = @intCast(fi) });
                                        try o_solid.removeFromMeshMap(other, editor);
                                        break; //Only one side per solid can be coplanar
                                    }
                                }
                            }
                        }
                    }
                } else {
                    for (selected_slice) |sel| {
                        if (!editor.hasComponent(sel, .solid)) continue;
                        if (editor.getComponent(sel, .bounding_box)) |bb| {
                            toolutil.drawBBDimensions(
                                bb.a,
                                bb.b,
                                &editor.draw_state.screen_space_text_ctx,
                                td.text_param,
                                td.screen_area,
                                td.view_3d.*,
                            );
                        }
                    }
                }
            },
            .active => {
                //for (self.selected.items) |id| {
                if (self.main_id) |id| {
                    if (editor.getComponent(id, .solid)) |solid| {
                        if (self.face_id >= 0 and self.face_id < solid.sides.items.len) {
                            const s_i: usize = @intCast(self.face_id);
                            const side = &solid.sides.items[s_i];
                            //if (self.face_id == s_i) {
                            //Side_normal
                            //self.start
                            if (side.index.items.len < 3) return;
                            const ind = side.index.items;
                            const ver = solid.verts.items;

                            //The projection of a vector u onto a plane with normal n is given by:
                            //v_proj = u - n.scale(u dot n), assuming n is normalized
                            const plane_norm = util3d.trianglePlane([3]Vec3{ ver[ind[0]], ver[ind[1]], ver[ind[2]] });
                            const ray = editor.camRay(td.screen_area, td.view_3d.*);
                            //const u = ray[1];
                            //const v_proj = u.sub(plane_norm.scale(u.dot(plane_norm)));

                            // By projecting the cam_norm onto the side's plane,
                            // we can use the resulting vector as a normal for a plane to raycast against
                            // The resulting plane's normal is as colinear with the cameras normal as we can get
                            // while still having the side's normal perpendicular (in the raycast plane)
                            //
                            // If cam_norm and side_norm are colinear the projection is near zero, in the future discard vectors below a threshold as they cause explosions

                            if (util3d.planeNormalGizmo(self.start, plane_norm, ray)) |inter_| {
                                _, const pos = inter_;
                                const dist = editor.grid.snapV3(pos);

                                //Get current bounds of each solid and display delta
                                if (self.draw_text) {
                                    if (editor.getComponent(id, .bounding_box)) |bb| {
                                        {
                                            const aa = editor.frame_arena.allocator();
                                            var vert_cpy = try aa.dupe(Vec3, ver);
                                            defer aa.free(vert_cpy);
                                            for (ind) |index|
                                                vert_cpy[index] = vert_cpy[index].add(dist);
                                            var bcpy = bb;
                                            bcpy.a = .set(std.math.floatMax(f32));
                                            bcpy.b = .set(-std.math.floatMax(f32));
                                            for (vert_cpy) |v| {
                                                bcpy.a = bcpy.a.min(v);
                                                bcpy.b = bcpy.b.max(v);
                                            }
                                            toolutil.drawBBDimensions(
                                                bcpy.a,
                                                bcpy.b,
                                                &editor.draw_state.screen_space_text_ctx,
                                                td.text_param,
                                                td.screen_area,
                                                td.view_3d.*,
                                            );
                                        }

                                        toolutil.drawText3D(
                                            self.start.add(dist),
                                            &editor.draw_state.screen_space_text_ctx,
                                            td.text_param,
                                            td.screen_area,
                                            td.view_3d.*,
                                            "[{d} {d} {d}]",
                                            .{
                                                dist.x(),
                                                dist.y(),
                                                dist.z(),
                                            },
                                        );
                                    }
                                    //toolutil.drawDistance(
                                    //    self.start,
                                    //    dist,
                                    //    &editor.draw_state.screen_space_text_ctx,
                                    //    td.text_param,
                                    //    td.screen_area,
                                    //    td.view_3d.*,
                                    //);
                                }

                                if (self.draw_grid) {
                                    const counts = editor.grid.countV3(dist);
                                    const absd = Vec3{ .data = @abs(dist.data) };
                                    const width = @max(10, util3d.maxComp(absd));
                                    gridutil.drawGridAxis(
                                        self.start,
                                        counts,
                                        td.draw,
                                        editor.grid,
                                        Vec3.set(width),
                                    );
                                }
                                //if (util3d.doesRayIntersectPlane(ray[0], ray[1], self.start, v_proj)) |inter| {
                                //const dist_n = inter.sub(self.start); //How much of our movement lies along the normal
                                //const acc = dist_n.dot(plane_norm);

                                for (self.selected.items) |sel| {
                                    const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                    if (sel.side_i >= solid_o.sides.items.len) continue;
                                    const s_io: usize = @intCast(sel.side_i);
                                    const side_o = &solid_o.sides.items[s_io];
                                    solid_o.drawImmediate(td.draw, editor, dist, side_o.index.items, false) catch return;
                                    draw_nd.convexPolyIndexed(side_o.index.items, solid_o.verts.items, colors.fast_face_plane, .{ .offset = dist });
                                }

                                const commit_btn = if (self.right) rm else lm;
                                if (commit_btn == .falling and dist.length() > 0.1) {
                                    try action.translateFace(editor, self.selected.items, dist);
                                }
                            } else {
                                draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, colors.fast_face_plane, .{});
                            }
                        }

                        if (rm != .high and lm != .high) {
                            for (self.selected.items) |sel| {
                                const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                try solid_o.markDirty(sel.id, editor);
                            }
                            self.reset();
                        }
                    }
                }
            },
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the Fast Face tool.
            \\Select objects with 'E'.
            \\Left click selects the near face, right click selects the far face
            \\Click and drag and click the opposite mouse button to commit changes
            \\If in multi select mode, faces with a common normal will be manipulated
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });
        const CB = Wg.Checkbox.build;
        _ = CB(area_vt, ly.getArea(), "Draw Grid", .{ .bool_ptr = &self.draw_grid }, null);
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const hl = os9gui.style.config.text_h;
        vl.pushHeight(hl * 10);
        if (os9gui.textView(hl, 0xff)) |tvc| {
            var tv = tvc;
            tv.text("This is the Fast Face tool", .{});
            tv.text("Left click selects the near face, right click selects the far face.", .{});
            tv.text("Click and drag and click the opposite mouse button to commit changes", .{});
            tv.text("", .{});
            tv.text("If in multi select mode, faces with a common normal will be manipulated", .{});
            //tv.text("", .{});
        }
        _ = editor;
    }
};

//TODO change this to PlaceEntity
pub const PlaceEntity = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    ent_class: enum {
        prop_static,
        prop_dynamic,
        prop_physics, //TODO load mdl metadata and set this field Automatically
    } = .prop_static,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .gui_build_cb = &buildGui,
            .tool_icon_fn = &@This().drawIcon,
        } };
        return &obj.vt;
    }

    pub fn doGui(vt: *i3DTool, os9gui: *Os9Gui, _: *Editor, _: *Gui.VerticalLayout) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        os9gui.enumCombo("New class: {s}", .{@tagName(self.ent_class)}, &self.ent_class) catch return;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("place_model.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.modelPlace(editor, td) catch return error.fatal;
    }

    pub fn buildGui(vt: *i3DTool, _: *Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const doc =
            \\This is the Place Entitytool.
            \\Click in the world to place an entity. Thats it.
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });
    }

    pub fn modelPlace(tool: *@This(), self: *Editor, td: ToolData) !void {
        const pot = self.screenRay(td.screen_area, td.view_3d.*);
        if (pot.len > 0) {
            const p = pot[0];
            const point = self.grid.snapV3(p.point);
            const mat1 = graph.za.Mat4.fromTranslate(point);
            const model_id = self.edit_state.selected_model_vpk_id;
            //TODO only draw the model if default entity class has a model
            const mod = blk: {
                const omod = self.models.get(model_id orelse break :blk null);
                if (omod != null and omod.?.mesh != null) {
                    const mod = omod.?.mesh.?;
                    break :blk mod;
                }
                break :blk null;
            };
            //zyx
            //const mat3 = mat1.mul(y1.mul(x1.mul(z)));
            if (mod) |m|
                m.drawSimple(td.view_3d.*, mat1, self.renderer.shader.forward);
            //Draw the model at
            var bb = ecs.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
            if (mod) |m| {
                bb.a = m.hull_min;
                bb.b = m.hull_max;
                bb.origin_offset = m.hull_min.scale(-1);
            }
            bb.setFromOrigin(point);
            const COLOR_FRAME = 0xe8a130_ee;
            self.draw_state.ctx.cubeFrame(bb.a, bb.b.sub(bb.a), COLOR_FRAME);
            if (self.edit_state.lmouse == .rising) {
                const new = try self.ecs.createEntity();
                try self.ecs.attach(new, .entity, .{
                    .origin = point,
                    .angle = Vec3.zero(),
                    .class = try self.storeString(@tagName(tool.ent_class)),
                    ._model_id = model_id,
                    ._sprite = null,
                });
                try self.ecs.attach(new, .bounding_box, bb);
                try self.ecs.attach(new, .layer, .{ .id = self.edit_state.selected_layer });

                var kvs = ecs.KeyValues.init(self.alloc);
                if (model_id) |mid| {
                    if (self.vpkctx.namesFromId(mid)) |names| {
                        try kvs.putStringPrintNoNotify("model", "{s}/{s}.{s}", .{ names.path, names.name, names.ext });
                    }
                }

                try self.ecs.attach(new, .key_values, kvs);

                try action.createEntity(self, new);
            }
        }
    }
};

const Proportional = struct {
    const TranslateCtx = struct {
        norm: Vec3,
        froze: Vec3,
        t: f32,
        tl: f32,

        pub fn vertexOffset(s: *const @This(), v: Vec3, _: u32, _: u32) Vec3 {
            const dist = (v.sub(s.froze)).dot(s.norm) / -s.tl;

            //TODO put opt to disable hard grid snap
            return .{ .data = @round(s.norm.scale(dist * s.t).data) };
        }
    };
    const Self = @This();
    // when the selection changes, we need to recalculate the bb
    sel_map: std.AutoHashMap(ecs.EcsT.Id, void),
    bb_min: Vec3 = Vec3.zero(),
    bb_max: Vec3 = Vec3.zero(),

    state: enum { init, active } = .init,
    start: Vec3 = Vec3.zero(),
    start_n: Vec3 = Vec3.zero(),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .sel_map = std.AutoHashMap(ecs.EcsT.Id, void).init(alloc),
        };
    }

    pub fn reset(self: *Self) void {
        self.sel_map.clearRetainingCapacity();
        self.state = .init;
    }

    pub fn deinit(self: *Self) void {
        self.sel_map.deinit();
    }

    fn rebuildBB(self: *Self, ed: *Editor) !void {
        const sel = ed.getSelected();
        self.sel_map.clearRetainingCapacity();
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));

        for (sel) |s| {
            if (!ed.hasComponent(s, .solid)) continue;
            if (ed.getComponent(s, .bounding_box)) |b| {
                min = min.min(b.a);
                max = max.max(b.b);
            }
            try self.sel_map.put(s, {});
        }

        self.bb_min = min;
        self.bb_max = max;
    }

    fn needsRebuild(self: *Self, ed: *Editor) bool {
        const sel = ed.getSelected();
        if (sel.len != self.sel_map.count()) return true;

        for (sel) |s| {
            if (!self.sel_map.contains(s)) return true;
        }
        return false;
    }

    fn addOrRemoveSelFromMeshMap(ed: *Editor, add: bool) !void {
        const sel = ed.getSelected();
        for (sel) |id| {
            if (ed.getComponent(id, .solid)) |solid| {
                if (!add) try solid.removeFromMeshMap(id, ed) else try solid.translate(id, Vec3.zero(), ed, Vec3.zero(), null);
            }
        }
    }

    fn commit(self: *Self, ed: *Editor, ctx: TranslateCtx) !void {
        const selection = ed.getSelected();
        const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.scale});
        for (selection) |id| {
            const solid = ed.getComponent(id, .solid) orelse continue;
            const temp_verts = try ed.frame_arena.allocator().alloc(Vec3, solid.verts.items.len);
            const index = try ed.frame_arena.allocator().alloc(u32, solid.verts.items.len);
            for (solid.verts.items, 0..) |v, i| {
                temp_verts[i] = ctx.vertexOffset(v, 0, 0);
                index[i] = @intCast(i);
            }

            try ustack.append(.{ .vertex_translate = try .create(
                ed.undoctx.alloc,
                id,
                Vec3.zero(),
                index,
                temp_verts,
            ) });
        }
        ustack.apply(ed);
        self.reset();
    }

    pub fn runProp(self: *Self, ed: *Editor, td: ToolData) !void {
        if (self.needsRebuild(ed))
            try self.rebuildBB(ed);
        const draw_nd = &ed.draw_state.ctx;

        //draw.cube(cc[0], cc[1], 0xffffff88);
        const selected = ed.getSelected();
        if (selected.len == 0) return;
        draw_nd.point3D(self.start, 0xffff_00ff, ed.config.dot_size);
        const lm = ed.edit_state.lmouse;
        const rm = ed.edit_state.rmouse;
        const rc = ed.camRay(td.screen_area, td.view_3d.*);
        switch (self.state) {
            .init => {
                const cc = cubeFromBounds(self.bb_min, self.bb_max);
                draw_nd.cubeFrame(cc[0], cc[1], 0xff0000ff);
                if (lm == .rising) {
                    if (util3d.doesRayIntersectBBZ(rc[0], rc[1], self.bb_min, self.bb_max)) |inter| {
                        self.start = inter;
                        if (util3d.pointBBIntersectionNormal(self.bb_min, self.bb_max, inter)) |norm| {
                            self.start_n = norm;
                            self.state = .active;
                            try addOrRemoveSelFromMeshMap(ed, false);
                        }
                    }
                }
            },
            .active => {
                if (lm != .high) {
                    self.state = .init;
                    try addOrRemoveSelFromMeshMap(ed, true);
                    return;
                }
                if (util3d.planeNormalGizmo(self.start, self.start_n, rc)) |inter| {
                    //const dist_n =

                    const sign = self.start_n.dot(Vec3.set(1));
                    _, const p_unsnapped = inter;
                    const p = ed.grid.snapV3(p_unsnapped);
                    const bmin = if (sign > 0) self.bb_min else self.bb_min.add(p);
                    const bmax = if (sign < 0) self.bb_max else self.bb_max.add(p);
                    const fr0zen = if (sign > 0) self.bb_min else self.bb_max;

                    const total_len = (self.bb_min.sub(self.bb_max).dot(self.start_n));

                    const cc = cubeFromBounds(bmin, bmax);
                    draw_nd.line3D(self.start, self.start.add(p), 0x00ffffff, 2);
                    draw_nd.cubeFrame(cc[0], cc[1], 0xff0000ff);

                    const ctx_ = TranslateCtx{
                        .froze = fr0zen,
                        .norm = self.start_n,
                        .t = p.dot(Vec3.set(1)),
                        .tl = total_len,
                    };
                    if (rm == .rising) {
                        try self.commit(ed, ctx_);
                    }
                    for (selected) |id| {
                        const solid = ed.getComponent(id, .solid) orelse continue;
                        solid.drawImmediateCustom(td.draw, ed, &ctx_, TranslateCtx.vertexOffset, false) catch return;
                    }
                }
            },
        }
    }
};

pub const TranslateFace = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;

    vt: i3DTool,
    gizmo: Gizmo,
    face_id: ?usize = null,
    face_origin: Vec3 = Vec3.zero(),

    //When there are more than 1 solids selected, do proportional editing instead
    prop: Proportional,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .gui_build_cb = &buildGui,
                .event_fn = &event,
            },
            .gizmo = .{},
            .prop = Proportional.init(alloc),
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("face_translate.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.prop.deinit();
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.selection.getExclusive()) |id| {
            faceTranslate(self, editor, id, td) catch return error.fatal;
        } else {
            self.prop.runProp(editor, td) catch return error.fatal;
        }
    }

    pub fn event(vt: *i3DTool, ev: ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus => {
                self.prop.reset();
            },
            else => {},
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const doc =
            \\This is the face translate tool.
            \\Select a solid with E
            \\left click selects the near face
            \\right click selects the far face
            \\Once you drag the gizmo, press right click to commit the change
            \\If you have more than one entity selected, it will do proportional editing instead.
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });
    }

    pub fn faceTranslate(tool: *@This(), self: *Editor, id: ecs.EcsT.Id, td: ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        if (self.getComponent(id, .solid)) |solid| {
            var gizmo_is_active = false;
            for (solid.sides.items, 0..) |side, s_i| {
                if (tool.face_id == s_i) {
                    draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, 0xff000088, .{});
                    const origin_i = tool.face_origin;
                    var origin = origin_i;
                    const giz_active = tool.gizmo.handle(
                        origin,
                        &origin,
                        self.draw_state.cam3d.pos,
                        self.edit_state.lmouse,
                        draw_nd,
                        td.screen_area,
                        td.view_3d.*,
                        //self.edit_state.mpos,
                        self,
                    );
                    gizmo_is_active = giz_active != .low;
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self, Vec3.zero(), null); //Dummy to put it bake in the mesh batch
                        tool.face_origin = origin;
                    }

                    if (giz_active == .high) {
                        const dist = self.grid.snapV3(origin.sub(origin_i));
                        toolutil.drawDistance(origin_i, dist, &self.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
                        try solid.drawImmediate(td.draw, self, dist, side.index.items, false);
                        if (self.edit_state.rmouse == .rising) {
                            //try solid.translateSide(id, dist, self, s_i);
                            try action.translateFace(self, &.{.{ .id = id, .side_i = @intCast(s_i) }}, dist);
                            tool.face_origin = origin;
                            tool.gizmo.start = origin;
                            //Commit the changes
                        }
                    }
                }
            }
            if (!gizmo_is_active and (self.edit_state.lmouse == .rising or self.edit_state.rmouse == .rising)) {
                const r = self.camRay(td.screen_area, td.view_3d.*);
                //Find the face it intersects with
                const rc = (try raycast.doesRayIntersectSolid(
                    r[0],
                    r[1],
                    solid,
                    &self.csgctx,
                ));
                if (rc.len > 0) {
                    const rci = if (self.edit_state.rmouse == .rising) @min(1, rc.len) else 0;
                    tool.face_id = rc[rci].side_index;
                    tool.face_origin = rc[rci].point;
                }
            }
        }
    }
};
