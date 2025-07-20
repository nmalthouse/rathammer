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

pub const Translate = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
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
    cb_vt: iArea = undefined,

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
        const selected = ed.selection.getSlice();
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
                        if (editor.edit_state.rmouse == .rising) {
                            var it = editor.ecs.iterator(.bounding_box);
                            while (it.next()) |item| {
                                if (util3d.doesBBOverlapExclusive(bounds[0], bounds[1], item.a, item.b)) {
                                    _ = editor.selection.put(it.i, editor) catch return;
                                }
                            }
                        }
                    },
                }
            },
        }
    }

    fn getOrigin(self: *Translate, ed: *Editor) ?Vec3 {
        switch (self.origin_mode) {
            .mean => {},
            .last_selected => {
                const last_id = ed.selection.getLast() orelse return null;
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
            tool.modeSwitchCube(self, origin, giz_active == .high, draw_nd, td);
            const commit = self.edit_state.lmouse == .rising;
            const real_commit = giz_active == .high and commit;
            const selected = self.selection.getSlice();
            const MAX_DRAWN_VERTS = 500;
            const draw_verts = selected.len < MAX_DRAWN_VERTS;
            for (selected) |id| {
                if (self.getComponent(id, .solid)) |solid| {
                    solid.drawEdgeOutline(draw_nd, Vec3.zero(), .{
                        .point_color = if (draw_verts) 0xff0000ff else 0,
                        .edge_color = 0xff00ff,
                        .edge_size = 2,
                        .point_size = self.config.dot_size,
                    });
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
                        try solid.drawImmediateCustom(draw, self, ctx, DrawCustomCtx.vertOffset);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null);
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
                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });

                        if (commit) {
                            angle_delta = copy_ent.angle.sub(ent.angle);
                        }
                    }
                }
            }
            if (real_commit) {
                try commit_(self, dupe, angle_delta, origin, Vec3.zero());
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
            const giz_active = tool.gizmo_translate.handle(
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

            tool.modeSwitchCube(self, origin, giz_active == .high, draw_nd, td);
            const commit = self.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;
            const dist = self.grid.snapV3(origin_mut.sub(origin));
            const selected = self.selection.getSlice();
            const MAX_DRAWN_VERTS = 500;
            const draw_verts = selected.len < MAX_DRAWN_VERTS;
            switch (giz_active) {
                .low, .rising => {},
                .high => tool._delta = dist,
                .falling => tool._delta = Vec3.zero(),
            }
            // on giz -> rising, dupe selected and use that until giz_active -> low
            // on event -> unFocus, if we have a selection, put it back
            //
            for (selected) |id| {
                if (self.getComponent(id, .solid)) |solid| {
                    solid.drawEdgeOutline(draw_nd, Vec3.zero(), .{
                        .point_color = if (draw_verts) 0xff0000ff else 0,
                        .edge_color = 0xff00ff,
                        .edge_size = 2,
                        .point_size = self.config.dot_size,
                    });
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self, Vec3.zero(), null); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        try solid.drawImmediate(draw, self, dist, null);
                    }
                    if (giz_active == .high) {
                        try solid.drawImmediate(draw, self, dist, null);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null);
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
                if (self.getComponent(id, .entity)) |ent| {
                    const bb = self.getComponent(id, .bounding_box) orelse continue;
                    const del = Vec3.set(1); //Pad the frame so in doesn't get drawn over by ent frame
                    const coo = bb.a.sub(del);
                    draw_nd.cubeFrame(coo, bb.b.sub(coo).add(del), color);
                    if (giz_active == .high) {
                        var copy_ent = ent.*;
                        copy_ent.origin = ent.origin.add(dist);
                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });
                    }
                }
            }
            if (real_commit) {
                try commit_(self, dupe, null, origin, dist);
            }
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the translate tool.
            \\Select objects with 'E'.
            \\Left Click and drag the gizmo.
            \\Right click to commit the translation.
            \\Hold 'Shift' to uncapture the mouse.
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, ly.getArea(), "translate tool", null));
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Angle snap", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &self.angle_snap, 0, 360, .{
                .nudge = 1,
                .snap_mod = 15,
                .snap_thresh = 3,
            }));

        const com_o = Wg.SliderOptions{ .nudge = 1, .snap_mod = 1, .snap_thresh = 0.5 };
        if (guis.label(area_vt, gui, win, ly.getArea(), "Grid x", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, self.ed.grid.s.xMut(), 0, 1024, com_o));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Grid y", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, self.ed.grid.s.yMut(), 0, 1024, com_o));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Grid z", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, self.ed.grid.s.zMut(), 0, 1024, com_o));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Set grid", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Textbox.buildOpts(gui, ar, .{
                .commit_cb = &@This().textbox_cb,
                .commit_vt = &self.cb_vt,
                .clear_on_commit = true,
            }));
        const Btn = Wg.Button.build;
        area_vt.addChildOpt(gui, win, Btn(gui, ly.getArea(), "Reset Grid", .{ .cb_fn = &btnCb, .id = 0, .cb_vt = &self.cb_vt }));

        const CB = Wg.Checkbox.build;
        {
            //var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 4 };
            ly.pushCount(2);
            var hy = guis.TableLayout{ .columns = 4, .item_height = ly.item_height, .bounds = ly.getArea() orelse return };
            const sl = &self.ed.selection.options;
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select brush", .{ .bool_ptr = &sl.brushes }, null));
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select prop", .{ .bool_ptr = &sl.props }, null));
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select ent", .{ .bool_ptr = &sl.entity }, null));
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select func", .{ .bool_ptr = &sl.func }, null));
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select disp", .{ .bool_ptr = &sl.disp }, null));
        }
        {
            const sl = &self.ed.selection.options;
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 2 };
            area_vt.addChildOpt(gui, win, CB(gui, hy.getArea(), "Select nearby", .{ .bool_ptr = &sl.select_nearby }, null));
            if (guis.label(area_vt, gui, win, hy.getArea(), "dist threshold", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &sl.nearby_distance, 0, 256, .{}));
        }
    }

    fn commit_(self: *Editor, dupe: bool, angle_delta: ?Vec3, origin: Vec3, dist: Vec3) !void {
        const selected = self.selection.getSlice();
        var new_ent_list = std.ArrayList(ecs.EcsT.Id).init(self.frame_arena.allocator());
        //Map old groups to duped groups
        var group_mapper = std.AutoHashMap(ecs.Groups.GroupId, ecs.Groups.GroupId).init(self.frame_arena.allocator());

        const ustack = try self.undoctx.pushNewFmt("{s} of {d} entities", .{ if (dupe) "Dupe" else "Translation", selected.len });
        for (selected) |id| {
            if (dupe) {
                const duped = try self.dupeEntity(id);

                try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, duped, .create));
                try ustack.append(try undo.UndoTranslate.create(
                    self.undoctx.alloc,
                    dist,
                    angle_delta,
                    duped,
                    origin,
                ));
                if (!self.selection.ignore_groups) {
                    if (try self.ecs.getOpt(duped, .group)) |group| {
                        if (group.id != ecs.Groups.NO_GROUP) {
                            if (!group_mapper.contains(group.id)) {
                                try group_mapper.put(group.id, try self.groups.newGroup(null));
                            }
                            try new_ent_list.append(duped);
                        }
                    }
                }
            } else {
                try ustack.append(try undo.UndoTranslate.create(
                    self.undoctx.alloc,
                    dist,
                    angle_delta,
                    id,
                    origin,
                ));
            }
        }
        if (dupe) {
            var it = group_mapper.iterator();
            while (it.next()) |item| {
                if (self.groups.getOwner(item.key_ptr.*)) |owner| {
                    const duped = try self.dupeEntity(owner);

                    try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, duped, .create));
                    try self.groups.setOwner(item.value_ptr.*, duped);
                    //TODO set the group owner with undo stack
                }
            }
            for (new_ent_list.items) |new_ent| {
                const old_group = try self.ecs.get(new_ent, .group);
                const new_group = group_mapper.get(old_group.id) orelse continue;
                try ustack.append(
                    try undo.UndoChangeGroup.create(self.undoctx.alloc, old_group.id, new_group, new_ent),
                );
            }
            //now iterate the new_ent_list and update the group mapping
        }
        undo.applyRedo(ustack.items, self);
    }

    fn btnCb(vt: *iArea, _: usize, _: *RGui, _: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));

        self.ed.grid.setAll(16);
    }

    fn textbox_cb(vt: *iArea, _: *RGui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        self.textboxErr(string, id) catch return;
    }

    fn textboxErr(self: *@This(), string: []const u8, id: usize) !void {
        _ = id;

        const num = try std.fmt.parseFloat(f32, string);
        self.ed.grid.setAll(num);
    }
};
