const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const Vec3 = graph.za.Vec3;
const Mat3 = graph.za.Mat3;
const graph = @import("graph");
const std = @import("std");
const DrawCtx = graph.ImmediateDrawingContext;
const edit = @import("../editor.zig");
const Editor = edit.Context;
const guis = graph.RGui;
const RGui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const snapV3 = util3d.snapV3;
const prim_gen = @import("../primitive_gen.zig");
const toolutil = @import("../tool_common.zig");
const grid = @import("../grid.zig");
const limits = @import("../limits.zig");
const actions = @import("../actions.zig");

pub const CubeDraw = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    vt: i3DTool,

    primitive: enum {
        cube,
        arch,
        cylinder,
        stairs,
        dome,
    } = .cube,
    height_setting: enum {
        grid,
        custom,
        min_w,
        max_w,
        last,
    } = .grid,

    primitive_settings: struct {
        nsegment: f32 = 16,
        axis: prim_gen.Axis = .y,
        invert: bool = false,
        invert_x: bool = false,
        angle: f32 = 0,
        theta: f32 = 180,
        thickness: f32 = 16,
        archbox: bool = false,
    } = .{},

    stairs_setting: struct {
        front_perc: f32 = 0,
        back_perc: f32 = 0,
        rise: f32 = 8,
        run: f32 = 12,
    } = .{},

    min_volume: f32 = limits.min_volume,
    snap_height: bool = true,
    custom_height: f32 = 16,
    state: enum { start, planar, finished } = .start,
    start: Vec3 = undefined,
    end: Vec3 = undefined,
    z: f32 = 0,

    snap_new_verts: bool = false,
    snap_z: bool = false,

    plane_z: f32 = 0,
    last_height: f32 = 16,

    post_state: enum {
        reset,
        switch_to_fast_face,
        switch_to_translate,
    } = .reset,

    bb_gizmo: toolutil.AABBGizmo = .{},

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .gui_build_cb = &buildGui,
            .event_fn = &event,
        } };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("cube_draw.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn buildGui(vt: *i3DTool, inspector: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the cube draw tool
            \\Select a texture with alt-t
            \\left click to add the start point.
            \\Click again to finish cube.
            \\
            \\Change the height of the draw plane with x and z
            \\Or, hold q and aim at a entity, left click to set this as the new position.
            \\Change the grid size with 'R' and 'F'
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 7));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));

        const SSlide = Wg.StaticSlider;
        { //All the damn settings
            ly.pushCount(8);
            var tly = guis.TableLayout{ .columns = 2, .item_height = ly.item_height, .bounds = ly.getArea() orelse return };
            if (guis.label(area_vt, gui, win, tly.getArea(), "Post draw state", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.post_state, .{}));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Height mode", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.height_setting, .{}));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Custom height", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, ar, &self.custom_height, win, .{}));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Primitive", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.primitive, .{}));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Segment", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.primitive_settings.nsegment, .{
                    .min = 4,
                    .max = 48,
                    .default = 16,
                    .display_bounds_while_editing = false,
                    .display_kind = .integer,
                }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Thick", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.primitive_settings.thickness, .{
                    .min = 1,
                    .max = 256,
                    .default = 16,
                    .display_bounds_while_editing = false,
                    .slide = .{ .snap = 4 },
                    .display_kind = .integer,
                }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Axis", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.primitive_settings.axis, .{}));
            {
                var hy = guis.HorizLayout{ .bounds = tly.getArea() orelse return, .count = 2 };
                area_vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "Invert", .{ .bool_ptr = &self.primitive_settings.invert }, null));
                area_vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, hy.getArea(), "snap ", .{ .bool_ptr = &self.snap_new_verts }, null));
            }
            area_vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, tly.getArea(), "archbox", .{ .bool_ptr = &self.primitive_settings.archbox }, null));
            if (guis.label(area_vt, gui, win, tly.getArea(), "angle", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.primitive_settings.angle, .{
                    .min = 0,
                    .max = 360,
                    .default = 0,
                    .display_bounds_while_editing = false,
                    .slide = .{ .snap = 15 },
                }));

            if (guis.label(area_vt, gui, win, tly.getArea(), "stair percf", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &self.stairs_setting.front_perc, -1, 1, .{ .nudge = 0.1 }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "stair percb", .{})) |ar|
                area_vt.addChildOpt(gui, win, Wg.Slider.build(gui, ar, &self.stairs_setting.back_perc, -1, 1, .{ .nudge = 0.1 }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "theta", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.primitive_settings.theta, .{
                    .min = 0,
                    .max = 360,
                    .default = 0,
                    .display_bounds_while_editing = false,
                    .slide = .{ .snap = 15 },
                }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "rise", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.stairs_setting.rise, .{
                    .min = 1,
                    .max = 16,
                    .default = 8,
                    .display_bounds_while_editing = false,
                }));
            if (guis.label(area_vt, gui, win, tly.getArea(), "run", .{})) |ar|
                area_vt.addChildOpt(gui, win, SSlide.build(gui, ar, &self.stairs_setting.run, .{
                    .min = 1,
                    .max = 64,
                    .default = 12,
                    .display_bounds_while_editing = false,
                }));
        }
        const tex_w = area_vt.area.w / 2;
        ly.pushHeight(tex_w);
        const ar = ly.getArea() orelse return;
        inspector.selectedTextureWidget(area_vt, gui, win, ar);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        cubeDraw(self, editor, td) catch return error.fatal;
    }

    fn getHeight(self: *const @This(), ed: *Editor, p2: Vec3) f32 {
        const dim = self.start.sub(p2);
        return switch (self.height_setting) {
            .grid => ed.grid.s.z(),
            .custom => self.custom_height,
            .min_w => @min(@abs(dim.x()), @abs(dim.y())),
            .max_w => @max(@abs(dim.x()), @abs(dim.y())),
            .last => self.last_height,
        };
    }

    fn finishPrimitive(tool: *@This(), ed: *Editor, td: tools.ToolData) !void {
        const draw_nd = &ed.draw_state.ctx;
        const set = tool.primitive_settings;
        const rot = set.axis.getMat(set.invert, set.angle);
        const rc = ed.camRay(td.screen_area, td.view_3d.*);
        const snap = if (tool.snap_new_verts) ed.grid else grid.Snap.zero();
        const bounds = tool.bb_gizmo.aabbGizmo(&tool.start, &tool.end, rc, ed.edit_state.lmouse, ed.grid, draw_nd);

        {
            var tp = td.text_param;
            tp.background_rect = 0xff;
            toolutil.drawBBDimensions(
                bounds[0],
                bounds[1],
                draw_nd,
                tp,
                td.screen_area,
                td.view_3d.*,
            );
        }
        const bb = util3d.cubeFromBounds(bounds[0], bounds[1]);
        const x_basis = rot.mulByVec3(Vec3.new(1, 0, 0));
        const y_basis = rot.mulByVec3(Vec3.new(0, 1, 0));
        const z_basis = rot.mulByVec3(Vec3.new(0, 0, 1));
        const center = bb[0].add(bb[1].scale(0.5));

        const rb = Vec3.new(
            @abs(x_basis.dot(bb[1])),
            @abs(y_basis.dot(bb[1])),
            @abs(z_basis.dot(bb[1])),
        );

        if (ed.edit_state.lmouse == .falling) {
            //tool.start = bounds[0];
            //tool.end = bounds[1];
        }
        const nsegment: u32 = @intFromFloat(std.math.clamp(tool.primitive_settings.nsegment, 2, 128));
        const prim: struct {
            prim_gen.Primitive,
            bool,
        } = switch (tool.primitive) {
            .cylinder => .{ try prim_gen.cylinder(ed.frame_arena.allocator(), .{
                .a = rb.x() / 2,
                .b = rb.y() / 2,
                .z = rb.z(),
                .num_segment = nsegment,
                .grid = snap,
            }), false },
            .arch => .{ try prim_gen.arch(ed.frame_arena.allocator(), .{
                .thick = tool.primitive_settings.thickness,
                .a = rb.x() / 2,
                .b = rb.y() / 2,
                .z = rb.z(),
                .num_segment = nsegment,
                .theta_deg = tool.primitive_settings.theta,
                .snap_to_box = tool.primitive_settings.archbox,
                .grid = snap,
            }), true },
            .dome => .{ try prim_gen.uvSphere(ed.frame_arena.allocator(), .{
                .a = rb.x() / 2,
                .b = rb.y() / 2,
                .z = rb.z() / 2,
                .phi = tool.primitive_settings.theta,
                .phi_seg = nsegment,
                .theta_seg = nsegment,
                .grid = snap,
                .thick = tool.primitive_settings.thickness,
            }), true },
            .stairs => .{ try prim_gen.stairs(ed.frame_arena.allocator(), .{
                .width = rb.x(),
                .height = rb.y(),
                .z = rb.z(),

                .rise = tool.stairs_setting.rise,
                .run = tool.stairs_setting.run,

                .front_perc = tool.stairs_setting.front_perc,
                .back_perc = tool.stairs_setting.back_perc,
                .grid = snap,
            }), true },
            .cube => .{ try prim_gen.cube(ed.frame_arena.allocator(), .{
                .size = rb.scale(0.5),
            }), false },
        };
        prim[0].draw(td.draw, center, rot);
        if (ed.edit_state.rmouse != .rising) return;
        tool.state = .start;
        try tool.commitPrimitive(ed, center, &prim[0], .{ .rot = rot, .select = prim[1] });
    }

    fn commitPrimitive(self: *@This(), ed: *Editor, center: Vec3, prim: *const prim_gen.Primitive, opts: struct { select: bool = false, rot: Mat3 }) !void {
        const vpk_id = ed.asset_browser.selected_mat_vpk_id orelse 0;
        self.last_height = @abs(self.start.z() - self.end.z());
        const new_ids = try actions.createSolid(ed, prim, vpk_id, center, opts.rot, opts.select);
        if (new_ids.len > 0) {
            const new = new_ids[0];
            switch (self.post_state) {
                .reset => self.state = .start,
                .switch_to_fast_face => {
                    const tid = try ed.tools.getId(tools.FastFaceManip);
                    ed.setTool(tid);
                    try ed.selection.setToSingle(new, ed);
                },
                .switch_to_translate => {
                    const tid = try ed.tools.getId(tools.Translate);
                    ed.setTool(tid); //Be carefull with this, it will call into self!
                    try ed.selection.setToSingle(new, ed);
                },
            }
        }
    }

    pub fn event(vt: *i3DTool, ev: tools.ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus, .reFocus => {
                self.state = .start;
            },
            else => {},
        }
    }

    pub fn cubeDraw(tool: *@This(), self: *Editor, td: tools.ToolData) !void {
        const draw = td.draw;
        const snap = self.grid;
        const ray = self.camRay(td.screen_area, td.view_3d.*);
        switch (tool.state) {
            .start => {
                const plane_up = self.isBindState(self.config.keys.cube_draw_plane_up.b, .rising);
                const plane_down = self.isBindState(self.config.keys.cube_draw_plane_down.b, .rising);
                const send_raycast = self.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high);
                if (plane_up)
                    tool.plane_z += snap.s.z();
                if (plane_down)
                    tool.plane_z -= snap.s.z();
                if (send_raycast) {
                    const pot = self.screenRay(td.screen_area, td.view_3d.*);
                    if (pot.len > 0) {
                        const inter = pot[0].point;
                        const cc = self.grid.snapV3(inter);
                        grid.drawGridZ(inter, cc.z(), draw, snap, 11);
                        if (self.edit_state.lmouse == .rising) {
                            tool.plane_z = cc.z();
                        }
                    }
                } else if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    //user has a xy plane
                    //can reposition using keys or doing a raycast into world
                    grid.drawGridZ(inter, tool.plane_z, draw, snap, 11);

                    const cc = if (tool.snap_z) self.grid.snapV3(inter) else self.grid.swiz(inter, "xy");
                    draw.point3D(cc, 0xff0000ee, self.config.dot_size);

                    if (self.edit_state.lmouse == .rising) {
                        tool.start = cc;
                        tool.state = .planar;
                    }
                }
            },
            .planar => {
                if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    grid.drawGridZ(inter, tool.plane_z, draw, snap, 11);
                    const in = if (tool.snap_z) snap.snapV3(inter) else snap.swiz(inter, "xy");
                    const height = tool.getHeight(self, in);
                    const cc = util3d.cubeFromBounds(tool.start, in.add(Vec3.new(0, 0, height)));
                    draw.cube(cc[0], cc[1], 0xffffff88);
                    const ext = cc[1];
                    const volume = ext.x() * ext.y() * ext.z();

                    {
                        const pos = cc[0].add(Vec3.new(ext.x() / 2, 0, height + td.text_param.px_size * 2));
                        if (util3d.worldToScreenSpace(td.screen_area, td.view_3d.*, pos)) |ss| {
                            self.draw_state.ctx.textFmt(ss, "{d}", .{ext.x()}, .{
                                .color = 0xffff_ffff,
                                .px_size = td.text_param.px_size,
                                .font = td.text_param.font,
                                .background_rect = 0x0000_00_aa,
                            });
                            draw.line3D(pos.add(Vec3.new(0, 0, -td.text_param.px_size)), cc[0].add(Vec3.new(ext.x() / 2, 0, 0)), 0xffff_00ff, 4);
                        }
                    }
                    {
                        const pos = cc[0].add(Vec3.new(0, ext.y() / 2, height + td.text_param.px_size * 2));
                        if (util3d.worldToScreenSpace(td.screen_area, td.view_3d.*, pos)) |ss| {
                            self.draw_state.ctx.textFmt(ss, "{d}", .{ext.y()}, .{
                                .color = 0xffff_ffff,
                                .px_size = td.text_param.px_size,
                                .font = td.text_param.font,
                                .background_rect = 0x0000_00_aa,
                            });
                            draw.line3D(pos.add(Vec3.new(0, 0, -td.text_param.px_size)), cc[0].add(Vec3.new(0, ext.y() / 2, 0)), 0xffff_00ff, 4);
                        }
                    }

                    if (self.edit_state.lmouse == .rising and volume > tool.min_volume) {
                        tool.end = in;
                        tool.end.data[2] += height;
                        tool.state = .finished;
                        tool.bb_gizmo.active = false;
                        //Put it into the
                    }
                }
            },
            .finished => {
                try tool.finishPrimitive(self, td);
            },
        }
    }
};
