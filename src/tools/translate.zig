const std = @import("std");
const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const guis = graph.RGui;
const RGui = guis.Gui;
const Wg = guis.Widget;
const gizmo2 = @import("../gizmo2.zig");
const Gizmo = @import("../gizmo.zig").Gizmo;
const Vec3 = graph.za.Vec3;
const snapV3 = util3d.snapV3;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const DrawCtx = graph.ImmediateDrawingContext;
const graph = @import("graph");
const edit = @import("../editor.zig");
const Editor = edit.Context;
const toolcom = @import("../tool_common.zig");
const action = @import("../actions.zig");

pub const Translate = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    pub const DrawCustomCtx = struct {
        verts: []const Vec3,
        quat: graph.za.Quat,
        origin: Vec3,

        pub fn vertOffset(s: @This(), vec: Vec3, side_index: u32, vert_index: u32) Vec3 {
            _ = side_index;
            _ = vert_index;
            const v = vec.sub(s.origin);
            const rot = s.quat.rotateVec(v);

            const world = rot.add(s.origin).sub(vec);
            return world;
        }
    };
    vt: i3DTool,

    gizmo_rotation: gizmo2.Gizmo,
    gizmo_translate: Gizmo,
    mode: enum {
        marquee,
        translate,
        rotate,
        pub fn next(self: *@This()) void {
            self.* = switch (self.*) {
                .translate => .rotate,
                .rotate => .translate,
                .marquee => .marquee,
            };
        }
    } = .translate,
    angle_snap: f32 = 15,
    ed: *Editor,

    //TODO support this
    origin_mode: enum {
        mean,
        last_selected,
    } = .last_selected,
    cbhandle: guis.CbHandle = .{},
    win_ptr: ?*iWindow = null,

    /// Clicking anywhere will move in xy plane
    enable_fast_move: bool = true,
    fast_move: struct {
        start: Vec3 = Vec3.zero(),
        norm: ?Vec3 = null,
    } = .{},

    cube_draw: toolcom.DrawBoundingVolume = .{},
    bb_gizmo: toolcom.AABBGizmo = .{},

    _delta: Vec3 = Vec3.zero(),

    pub fn create(alloc: std.mem.Allocator, ed: *Editor) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .runTool_2d_fn = &runTool2D,
                .tool_icon_fn = &@This().drawIcon,
                .gui_build_cb = &buildGui,
                .event_fn = &event,
            },
            .ed = ed,
            .gizmo_rotation = .{},
            .gizmo_translate = .{},
            .mode = .translate,
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("translate.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool2D(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runTool2DErr(td, editor) catch return error.fatal;
    }

    fn runTool2DErr(self: *@This(), td: tools.ToolData, ed: *Editor) !void {
        const selected = ed.getSelected();
        const draw = td.draw;
        for (selected) |id| {
            if (ed.getComponent(id, .solid)) |solid| {
                solid.drawEdgeOutline(draw, self._delta, .{
                    .point_color = 0x0,
                    .edge_color = 0xff00ff,
                    .edge_size = 2,
                    .point_size = ed.config.dot_size,
                });
            }
        }
    }

    pub fn event(vt: *i3DTool, ev: tools.ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus, .reFocus => {
                self.gizmo_rotation.reset();
                self.cube_draw.reset();
                if (self.mode == .marquee)
                    self.mode = .translate;
            },
            else => {},
        }
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.isBindState(editor.config.keys.marquee.b, .rising)) {
            self.mode = .marquee;
            self.cube_draw.reset();
        }

        switch (self.mode) {
            .translate => translate(self, editor, td) catch return error.fatal,
            .rotate => rotate(self, editor, td) catch return error.fatal,
            .marquee => {
                //TODO draw the selected still!
                switch (self.cube_draw.state) {
                    else => self.cube_draw.run(.{
                        .z_up = editor.isBindState(editor.config.keys.cube_draw_plane_up.b, .rising),
                        .z_down = editor.isBindState(editor.config.keys.cube_draw_plane_down.b, .rising),
                        .z_raycast = editor.isBindState(editor.config.keys.cube_draw_plane_raycast.b, .high),
                    }, editor, td.screen_area, td.view_3d.*, td.draw),
                    .finished => {
                        const rc = editor.camRay(td.screen_area, td.view_3d.*);
                        const draw_nd = &editor.draw_state.ctx;
                        const bounds = self.bb_gizmo.aabbGizmo(&self.cube_draw.start, &self.cube_draw.end, rc, editor.edit_state.lmouse, editor.grid, draw_nd);
                        const cc = util3d.cubeFromBounds(bounds[0], bounds[1]);
                        td.draw.cube(cc[0], cc[1], 0x2222_22dd);
                        if (editor.edit_state.rmouse == .rising)
                            action.selectInBounds(editor, bounds) catch return error.fatal;
                    },
                }
            },
        }
    }

    fn getOrigin(self: *Translate, ed: *Editor) ?Vec3 {
        switch (self.origin_mode) {
            .mean => {},
            .last_selected => {
                const last_id = ed.selection.list.getLast() orelse return null;
                const last_bb = ed.getComponent(last_id, .bounding_box) orelse return null;
                if (ed.getComponent(last_id, .solid)) |solid| { //check Solid before Entity
                    _ = solid;
                    return last_bb.a.add(last_bb.b).scale(0.5);
                } else if (ed.getComponent(last_id, .entity)) |ent| {
                    return ent.origin;
                }
            },
        }
        return null;
    }

    pub fn rotate(tool: *Translate, self: *Editor, td: tools.ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        const draw = td.draw;
        const dupe = self.isBindState(self.config.keys.duplicate.b, .high);
        const COLOR_MOVE = 0xe8a130_ee;
        const COLOR_DUPE = 0xfc35ac_ee;
        const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;

        var angle: Vec3 = Vec3.zero();
        var angle_delta = Vec3.zero();
        const giz_origin = tool.getOrigin(self);
        if (giz_origin) |origin| {
            // Care must be taken if selection is changed while gizmo is active, as solids are removed from meshmaps
            const giz_active = tool.gizmo_rotation.drawGizmo(
                origin,
                &(angle),
                self.draw_state.cam3d.pos,
                self.edit_state.lmouse,
                draw_nd,

                self.camRay(td.screen_area, td.view_3d.*),
                //td.screen_area.dim(),
                //td.view_3d.*,
                //self.edit_state.mpos,
            );
            if (giz_active == .high) {
                var tt = td.text_param;
                tt.background_rect = 0xaa;
                const sn = snapV3(angle, tool.angle_snap);
                if (util3d.worldToScreenSpace(td.screen_area, td.view_3d.*, origin)) |ss| {
                    self.draw_state.screen_space_text_ctx.textFmt(ss, "{d} {d} {d}", .{ sn.x(), sn.y(), sn.z() }, tt);
                }
            }
            tool.modeSwitchCube(self, origin, giz_active == .high, draw_nd, td);
            const commit = self.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;
            const selected = self.getSelected();
            for (selected) |id| {
                if (self.getComponent(id, .solid)) |solid| {
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self, Vec3.zero(), null); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        //try solid.drawImmediate(draw, self, dist, null);
                    }
                    const ctx = DrawCustomCtx{
                        .verts = solid.verts.items,
                        .origin = origin,
                        .quat = util3d.extEulerToQuat(snapV3(angle, tool.angle_snap)),
                    };
                    angle_delta = snapV3(angle, tool.angle_snap);

                    if (giz_active == .high) {
                        try solid.drawImmediateCustom(draw, self, ctx, DrawCustomCtx.vertOffset, true);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null, true);
                        }
                        //if (draw_verts)
                        //solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
                    }
                }
                if (self.getComponent(id, .entity)) |ent| {
                    const bb = self.getComponent(id, .bounding_box) orelse continue;
                    const del = Vec3.set(1); //Pad the frame so in doesn't get drawn over by ent frame
                    const coo = bb.a.sub(del);
                    draw_nd.cubeFrame(coo, bb.b.sub(coo).add(del), color);
                    if (giz_active == .high) {
                        var copy_ent = ent.*;
                        const old_rot = util3d.extEulerToQuat(copy_ent.angle);
                        const new_rot = util3d.extEulerToQuat(angle);
                        const ang = new_rot.mul(old_rot).extractEulerAngles();
                        copy_ent.angle = snapV3(Vec3.new(ang.y(), ang.z(), ang.x()), tool.angle_snap);

                        const pos_v = copy_ent.origin.sub(origin);
                        const quat = util3d.extEulerToQuat(snapV3(angle, tool.angle_snap));
                        copy_ent.origin = quat.rotateVec(pos_v).add(origin);

                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true, .screen_area = td.screen_area });

                        if (commit) {
                            angle_delta = copy_ent.angle.sub(ent.angle);
                        }
                    }
                }
            }
            if (real_commit) {
                try action.rotateTranslateSelected(self, dupe, angle_delta, origin, Vec3.zero());
            }
        }
    }

    fn modeSwitchCube(tool: *Translate, ed: *Editor, origin: Vec3, active: bool, draw: *DrawCtx, td: tools.ToolData) void {
        const switcher_sz = origin.distance(ed.draw_state.cam3d.pos) / 64 * 5;
        const orr = origin.add(Vec3.new(0, 0, switcher_sz * 5));
        const co = orr.sub(Vec3.set(switcher_sz / 2));
        const ce = Vec3.set(switcher_sz);
        draw.cube(co, ce, 0xffffff88);
        if (active) {} else {
            const rc = ed.camRay(td.screen_area, td.view_3d.*);
            if (ed.edit_state.lmouse == .rising) {
                if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(ce))) |_| {
                    tool.mode.next();
                }
            }
        }
    }

    pub fn translate(tool: *Translate, self: *Editor, td: tools.ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        const draw = td.draw;
        const dupe = self.isBindState(self.config.keys.duplicate.b, .high);
        const COLOR_MOVE = 0xe8a130_ee;
        const COLOR_DUPE = 0xfc35ac_ee;
        const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;

        const giz_origin = tool.getOrigin(self);
        if (giz_origin) |origin| {
            // Care must be taken if selection is changed while gizmo is active, as solids are removed from meshmaps
            var origin_mut = origin;
            const giz_active_pre = tool.gizmo_translate.handle(
                origin,
                &origin_mut,
                self.draw_state.cam3d.pos,
                self.edit_state.lmouse,
                draw_nd,
                td.screen_area,
                td.view_3d.*,
                //self.edit_state.mpos,
                self,
            );

            var text_pos = origin;
            var giz_active = giz_active_pre;
            const selected = self.getSelected();
            if (tool.enable_fast_move) {
                const rc = self.camRay(td.screen_area, td.view_3d.*);
                if (self.edit_state.lmouse == .rising and giz_active_pre == .low) {
                    self.rayctx.reset();
                    for (selected) |sel| {
                        try self.rayctx.addPotentialSolid(&self.ecs, rc[0], rc[1], &self.csgctx, sel);
                    }
                    const pot = self.rayctx.sortFine();
                    if (pot.len > 0) {
                        const NORM_THRESH = 0.45;
                        const p = pot[0];
                        tool.fast_move.start = p.point;
                        const plane_norm = Vec3.new(0, 0, 1); // We start with an xy plane
                        if (@abs(rc[1].dot(plane_norm)) < NORM_THRESH) {
                            const solid = self.getComponent(p.id, .solid) orelse return;
                            const norm = solid.sides.items[p.side_id orelse return].normal(solid);
                            tool.fast_move.norm = norm;
                            // use the face as a plane
                        } else {
                            tool.fast_move.norm = plane_norm;
                        }
                    }
                }
                if (self.edit_state.lmouse == .high and giz_active_pre == .low and tool.fast_move.norm != null) {
                    const norm = tool.fast_move.norm orelse Vec3.new(0, 0, 1);
                    if (util3d.doesRayIntersectPlane(rc[0], rc[1], tool.fast_move.start, norm)) |inter| {
                        const dist = inter.sub(tool.fast_move.start);
                        origin_mut = origin.add(dist);
                        text_pos = tool.fast_move.start;
                    }
                }
                if (giz_active_pre == .low)
                    giz_active = self.edit_state.lmouse;
                if (self.edit_state.lmouse == .low)
                    tool.fast_move.norm = null;
            }

            tool.modeSwitchCube(self, origin, giz_active == .high, draw_nd, td);
            const commit = self.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;
            const dist = self.grid.snapV3(origin_mut.sub(origin));
            const MAX_DRAWN_VERTS = 500;
            const draw_verts = selected.len < MAX_DRAWN_VERTS;
            switch (giz_active) {
                .low, .rising => {},
                .high => tool._delta = dist,
                .falling => tool._delta = Vec3.zero(),
            }
            if (giz_active == .high) {
                toolcom.drawDistance(text_pos, dist, &self.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
            }
            // on giz -> rising, dupe selected and use that until giz_active -> low
            // on event -> unFocus, if we have a selection, put it back
            //
            for (selected) |id| {
                if (self.getComponent(id, .solid)) |solid| {
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self, Vec3.zero(), null); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        try solid.drawImmediate(draw, self, dist, null, true);
                    }
                    if (giz_active == .high) {
                        try solid.drawImmediate(draw, self, dist, null, true);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null, true);
                        }
                        if (draw_verts)
                            solid.drawEdgeOutline(draw_nd, dist, .{
                                .point_color = 0xff0000ff,
                                .edge_color = color,
                                .edge_size = 2,
                                .point_size = self.config.dot_size,
                            });
                    }
                }
                if (self.getComponent(id, .displacements)) |disps| {
                    const Help = struct {
                        dist: Vec3,

                        fn offset(h: @This(), _: Vec3, _: u32) Vec3 {
                            return h.dist;
                        }
                    };

                    if (giz_active == .high) {
                        const h = Help{ .dist = dist };
                        for (disps.disps.items) |*disp| {
                            try disp.drawImmediate(draw, self, id, h, Help.offset);
                        }
                    }
                }
                if (self.getComponent(id, .entity)) |ent| {
                    const bb = self.getComponent(id, .bounding_box) orelse continue;
                    const del = Vec3.set(1); //Pad the frame so in doesn't get drawn over by ent frame
                    const coo = bb.a.sub(del);
                    draw_nd.cubeFrame(coo, bb.b.sub(coo).add(del), color);
                    if (giz_active == .high) {
                        var copy_ent = ent.*;
                        copy_ent.origin = ent.origin.add(dist);
                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true, .screen_area = td.screen_area });
                    }
                }
            }
            if (real_commit) {
                try action.rotateTranslateSelected(self, dupe, null, origin, dist);
            }
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.win_ptr = win;
        const doc =
            \\This is the translate tool.
            \\Select objects with 'E'.
            \\Left Click and drag the gizmo.
            \\Right click to commit the translation.
            \\Hold 'Shift' to uncapture the mouse.
            \\Click the white cube to toggle rotation.
            \\Clicking on the solid will do a 'smart translate' where: 
            \\If the mouse raycast is > 30 degrees from the horizon, the solid is moved in the xy plane.
            \\Otherwise, the solid is moved in the plane you clicked on.
        ;
        var ly = gui.dstate.vLayout(area_vt.area);
        _ = Wg.Text.buildStatic(area_vt, ly.getArea(), "translate tool", null);
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });
        const St = Wg.StaticSlider;
        if (guis.label(area_vt, ly.getArea(), "Angle snap", .{})) |ar|
            _ = St.build(area_vt, ar, &self.angle_snap, .{
                .display_bounds_while_editing = false,
                .min = 0,
                .max = 360,
                .default = 15,
                .unit = "degrees",
                .slide = .{ .snap = 5 },
            });

        const com_o = Wg.StaticSliderOpts{
            .slide = .{ .snap = 1 },
            .min = 0,
            .max = 256,
            .default = 16,
            .unit = "hu",
            .display_bounds_while_editing = false,
        };
        if (guis.label(area_vt, ly.getArea(), "Grid", .{})) |ar| {
            var hy = guis.HorizLayout{ .bounds = ar, .count = 3 };
            _ = St.build(area_vt, hy.getArea(), self.ed.grid.s.xMut(), com_o);
            _ = St.build(area_vt, hy.getArea(), self.ed.grid.s.yMut(), com_o);
            _ = St.build(area_vt, hy.getArea(), self.ed.grid.s.zMut(), com_o);
        }
        if (guis.label(area_vt, ly.getArea(), "Set grid", .{})) |ar|
            _ = Wg.Textbox.buildOpts(area_vt, ar, .{
                .commit_cb = &@This().textbox_cb,
                .commit_vt = &self.cbhandle,
                .clear_on_commit = true,
            });
        const Btn = Wg.Button.build;
        _ = Btn(area_vt, ly.getArea(), "Reset Grid", .{ .cb_fn = &btnCb, .id = 0, .cb_vt = &self.cbhandle });

        const CB = Wg.Checkbox.build;
        {
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 6 };

            _ = Wg.Text.build(area_vt, hy.getArea(), "Select Mask", .{});
            const sl = &self.ed.selection.options;
            _ = CB(area_vt, hy.getArea(), "brush", .{ .bool_ptr = &sl.brushes }, null);
            _ = CB(area_vt, hy.getArea(), "prop", .{ .bool_ptr = &sl.props }, null);
            _ = CB(area_vt, hy.getArea(), "ent", .{ .bool_ptr = &sl.entity }, null);

            _ = CB(area_vt, hy.getArea(), "func", .{ .bool_ptr = &sl.func }, null);
            _ = CB(area_vt, hy.getArea(), "disp", .{ .bool_ptr = &sl.disp }, null);
        }
        {
            const sl = &self.ed.selection.options;
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 2 };
            _ = CB(area_vt, hy.getArea(), "Select nearby", .{ .bool_ptr = &sl.select_nearby }, null);
            if (guis.label(area_vt, hy.getArea(), "dist threshold", .{})) |ar|
                _ = Wg.StaticSlider.build(area_vt, ar, &sl.nearby_distance, .{
                    .min = 0,
                    .max = 16,
                    .default = 0,
                    .display_bounds_while_editing = false,
                    .clamp_edits = false,
                });
            //area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &sl.nearby_distance, 0, 256, .{}));
        }
    }

    fn btnCb(vt: *guis.CbHandle, _: usize, _: guis.MouseCbState, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", vt));

        self.ed.grid.setAll(16);
        if (self.win_ptr) |wp|
            wp.needs_rebuild = true;
    }

    fn textbox_cb(vt: *guis.CbHandle, _: *RGui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", vt));
        self.textboxErr(string, id) catch return;
        if (self.win_ptr) |wp|
            wp.needs_rebuild = true;
    }

    fn textboxErr(self: *@This(), string: []const u8, id: usize) !void {
        _ = id;

        const num = try std.fmt.parseFloat(f32, string);
        self.ed.grid.setAll(num);
    }
};
