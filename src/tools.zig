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
const keybinding = graph.keybinding;

pub const CubeDraw = @import("tools/cube_draw.zig").CubeDraw;
pub const TextureTool = @import("tools/texture.zig").TextureTool;
pub const Translate = @import("tools/translate.zig").Translate;
pub const Clipping = @import("tools/clipping.zig").Clipping;
pub const VertexTranslate = @import("tools/vertex.zig").VertexTranslate;
pub const FastFaceManip = @import("tools/fast_face.zig").FastFaceManip;

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

    key_ctx_mask: keybinding.ContextMask = .empty,
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
    screen_space_text_ctx: *graph.ImmediateDrawingContext,

    pub fn text3d(td: *const @This(), pos: Vec3, comptime fmt: []const u8, args: anytype) void {
        toolutil.drawText3D(
            pos,
            td.screen_space_text_ctx,
            td.text_param,
            td.screen_area,
            td.view_3d.*,
            fmt,
            args,
        );
    }
};

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
            .event_fn = event,
        } };
        return &obj.vt;
    }

    pub fn event(vt: *i3DTool, ev: ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        switch (ev) {
            .focus => {},
            else => {},
        }
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
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.nstyle.item_h, .bounds = area_vt.area };
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
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.nstyle.item_h, .bounds = area_vt.area };
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
                        try solid.drawImmediate(td.draw, self, dist, side.index.items, .{ .texture_lock = false });
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
