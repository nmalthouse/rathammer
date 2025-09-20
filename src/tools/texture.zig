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
const Gui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const snapV3 = util3d.snapV3;

//TODO when selection changes, change the gui

// doing the justify buttns
// idk, annoying
pub const TextureTool = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    const GuiBtnEnum = enum {
        reset_world,
        reset_norm,
        j_left,
        j_fit,
        j_right,

        j_top,
        j_bottom,
        j_center,

        u_flip,
        v_flip,
        swap,

        make_disp,
        subdivide,

        apply_selection,
    };
    const GuiTextEnum = enum {
        uscale,
        vscale,
        utrans,
        vtrans,
        lightmap,

        un_x,
        un_y,
        un_z,

        vn_x,
        vn_y,
        vn_z,
    };
    vt: i3DTool,
    id: ?ecs.EcsT.Id = null,
    face_index: ?u32 = 0,

    state: enum { pick, apply } = .apply,
    ed: *Editor,

    // Only used for a pointer
    // todo, fix the gui stuff
    cb_vt: iArea = undefined,
    win_ptr: ?*iWindow = null,
    stupid_start: f32 = 0,

    line_thickness: f32 = 5,

    show_disp_normal: bool = false,

    //Left click to select a face,
    //right click to apply texture to any face
    pub fn create(alloc: std.mem.Allocator, ed: *Editor) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .gui_build_cb = &buildGui,
                .selected_solid_edge_color = 0xff00aa,
            },
            .ed = ed,
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("texture_tool.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.run(td, editor) catch return error.fatal;
    }

    pub fn buildGui(vt: *i3DTool, inspector: *tools.Inspector, area_vt: *iArea, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.win_ptr = win;
        const doc =
            \\This is the Texture tool.
            \\Right click applies the selected texture
            \\Holding q and right clicking picks the texture
            \\Hold z and right click to wrap the texture
        ;
        const H = struct {
            fn param(s: *TextureTool, id: GuiTextEnum) Wg.TextboxOptions {
                return .{
                    .commit_cb = &TextureTool.textbox_cb,
                    .commit_vt = &s.cb_vt,
                    .user_id = @intFromEnum(id),
                };
            }

            fn slide(s: *TextureTool, id: GuiTextEnum, snap: f32, min: f32, max: f32, def: f32) Wg.StaticSliderOpts {
                return .{
                    .commit_vt = &s.cb_vt,
                    .display_bounds_while_editing = false,
                    .slide_cb = TextureTool.slideCb,
                    .commit_cb = TextureTool.slideCommit,
                    .user_id = @intFromEnum(id),
                    .min = min,
                    .max = max,
                    .default = def,
                    .slide = .{ .snap = snap },
                };
            }

            fn btn(s: *TextureTool, id: GuiBtnEnum) Wg.Button.Opts {
                return .{
                    .cb_vt = &s.cb_vt,
                    .cb_fn = &TextureTool.btn_cb,
                    .id = @intFromEnum(id),
                };
            }
        };
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{ .mode = .split_on_space }));
        {
            var hy = guis.HorizLayout{ .bounds = ly.getArea() orelse return, .count = 3 };
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "Reset face world", H.btn(self, .reset_world)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "Reset face norm", H.btn(self, .reset_norm)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "Apply to selection", H.btn(self, .apply_selection)));
        }
        const tex_w = area_vt.area.w / 2;
        ly.pushHeight(tex_w);
        const t_ar = ly.getArea() orelse return;
        inspector.selectedTextureWidget(area_vt, gui, win, t_ar);

        //Begin all selected face stuff
        const e_id = self.id orelse return;
        const f_id = self.face_index orelse return;
        const solid = (self.ed.getComponent(e_id, .solid)) orelse return;
        if (f_id >= solid.sides.items.len) return;
        const side = &solid.sides.items[f_id];

        var has_disp = false;
        if (self.ed.getComponent(e_id, .displacements)) |disp| {
            has_disp = disp.getDispPtr(f_id) != null;
        }

        if (!has_disp) {
            if (side.index.items.len == 4)
                area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Make displacment", H.btn(self, .make_disp)));
        }

        {
            const Tb = Wg.TextboxNumber.build;
            const St = Wg.StaticSlider;
            ly.pushCount(6);
            var tly = guis.TableLayout{ .columns = 2, .item_height = ly.item_height, .bounds = ly.getArea() orelse return };
            area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), "X", null));
            area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), "Y", null));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Scale", .{})) |ar|
                //area_vt.addChildOpt(gui, win, Tb(gui, ar, side.u.scale, win, H.param(self, .uscale)));
                area_vt.addChildOpt(gui, win, St.build(gui, ar, null, H.slide(self, .uscale, 0, 0.125 / 2.0, 1, side.u.scale)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Scale ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.v.scale, win, H.param(self, .vscale)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Trans ", .{})) |ar|
                area_vt.addChildOpt(gui, win, St.build(gui, ar, null, H.slide(self, .utrans, 1, 0, 512, side.u.trans)));
            //area_vt.addChildOpt(gui, win, Tb(gui, ar, side.u.trans, win, H.param(self, .utrans)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Trans ", .{})) |ar|
                area_vt.addChildOpt(gui, win, St.build(gui, ar, null, H.slide(self, .vtrans, 1, 0, 512, side.v.trans)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Axis ", .{})) |ar| {
                var hy = guis.HorizLayout{ .bounds = ar, .count = 3 };
                const a = side.u.axis;
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.x(), win, H.param(self, .un_x)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.y(), win, H.param(self, .un_y)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.z(), win, H.param(self, .un_z)));
            }
            if (guis.label(area_vt, gui, win, tly.getArea(), "Axis ", .{})) |ar| {
                var hy = guis.HorizLayout{ .bounds = ar, .count = 3 };
                const a = side.v.axis;
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.x(), win, H.param(self, .vn_x)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.y(), win, H.param(self, .vn_y)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.z(), win, H.param(self, .vn_z)));
            }
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, tly.getArea(), "flip", H.btn(self, .u_flip)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, tly.getArea(), "flip", H.btn(self, .v_flip)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "lux scale (hu / luxel): ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.lightmapscale, win, H.param(self, .lightmap)));
        }
        if (guis.label(area_vt, gui, win, ly.getArea(), "Justify: ", .{})) |ar| {
            var hy = guis.HorizLayout{ .bounds = ar, .count = 6 };
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "left", H.btn(self, .j_left)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "right", H.btn(self, .j_right)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "fit", H.btn(self, .j_fit)));

            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "top", H.btn(self, .j_top)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "bot", H.btn(self, .j_bottom)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "cent", H.btn(self, .j_center)));
        }
        area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "swap axis", H.btn(self, .swap)));

        if (has_disp) {
            area_vt.addChildOpt(gui, win, Wg.Checkbox.build(gui, ly.getArea(), "Draw normals", .{ .bool_ptr = &self.show_disp_normal }, null));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Subdivide", H.btn(self, .subdivide)));
        }
    }

    fn textbox_cb(vt: *iArea, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));

        const num = std.fmt.parseFloat(f32, string) catch return;
        self.textboxErr(num, id) catch return;
    }

    fn textboxErr(self: *@This(), num: f32, id: usize) !void {
        const sel = (self.getCurrentlySelected(self.ed) catch null) orelse return;
        const side = sel.side;
        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
        var new = old;
        switch (@as(GuiTextEnum, @enumFromInt(id))) {
            .uscale => new.u.scale = num,
            .vscale => new.v.scale = num,
            .utrans => new.u.trans = num,
            .vtrans => new.v.trans = num,
            .lightmap => {
                if (num < 1) return;
                new.lightmapscale = @intFromFloat(num);
            },
            .un_x => new.u.axis.xMut().* = num,
            .un_y => new.u.axis.yMut().* = num,
            .un_z => new.u.axis.zMut().* = num,
            .vn_x => new.v.axis.xMut().* = num,
            .vn_y => new.v.axis.yMut().* = num,
            .vn_z => new.v.axis.zMut().* = num,
        }
        if (!old.eql(new)) {
            if (self.win_ptr) |win|
                win.needs_rebuild = true;
            const ustack = try self.ed.undoctx.pushNewFmt("texture manip", .{});
            try ustack.append(try undo.UndoTextureManip.create(
                self.ed.undoctx.alloc,
                old,
                new,
                self.id orelse return,
                self.face_index orelse return,
            ));
            undo.applyRedo(ustack.items, self.ed);
        }
    }

    fn slideCb(vt: *iArea, _: *Gui, num: f32, id: usize, state: Wg.StaticSliderOpts.State) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        const text_k = @as(GuiTextEnum, @enumFromInt(id));
        const sel = (self.getCurrentlySelected(self.ed) catch null) orelse return;
        var nn = num;
        const ptr = switch (text_k) {
            else => return,
            .utrans => &sel.side.u.trans,
            .vtrans => &sel.side.v.trans,
            .uscale => &sel.side.u.scale,
            .vscale => &sel.side.v.scale,
        };
        switch (state) {
            .rising => {
                std.debug.print("SET STUPID {d}\n", .{num});
                self.stupid_start = ptr.*;
            },
            .falling => nn = self.stupid_start,
            else => {},
        }
        ptr.* = nn;
        sel.solid.translate(self.id orelse return, Vec3.zero(), self.ed, Vec3.zero(), null) catch return;
    }

    fn slideCommit(vt: *iArea, _: *Gui, num: f32, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        std.debug.print("SLIDE COMMIT\n", .{});
        self.textboxErr(num, id) catch return;
    }

    pub fn btn_cb(vt: *iArea, id: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        self.btn_cbErr(id, gui, win) catch return;
    }
    pub fn btn_cbErr(self: *@This(), id: usize, _: *Gui, _: *guis.iWindow) !void {
        const btn_k = @as(GuiBtnEnum, @enumFromInt(id));
        switch (btn_k) {
            else => {},
            .apply_selection => {
                const selection = self.ed.getSelected();
                std.debug.print("Start apply\n", .{});
                const selected_mat = (self.ed.asset_browser.selected_mat_vpk_id) orelse return;

                const ustack = try self.ed.undoctx.pushNewFmt("texture apply", .{});
                for (selection) |sel_id| {
                    if (self.ed.getComponent(sel_id, .solid)) |solid| {
                        for (solid.sides.items, 0..) |*sp, side_id| {
                            const old_s = undo.UndoTextureManip.State{ .u = sp.u, .v = sp.v, .tex_id = sp.tex_id, .lightmapscale = sp.lightmapscale };
                            var new_s = old_s;
                            new_s.tex_id = selected_mat;
                            try ustack.append(try undo.UndoTextureManip.create(self.ed.undoctx.alloc, old_s, new_s, sel_id, @intCast(side_id)));
                        }
                    }
                }
                std.debug.print("Applyied {d}\n", .{ustack.items.len});
                undo.applyRedo(ustack.items, self.ed);
            },
        }
        const sel = (self.getCurrentlySelected(self.ed) catch null) orelse return;
        const side = sel.side;
        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
        var new = old;
        switch (btn_k) {
            .apply_selection => {},
            .j_fit, .j_left, .j_right, .j_top, .j_bottom, .j_center => {
                const res = side.justify(sel.solid.verts.items, switch (btn_k) {
                    .j_fit => .fit,
                    .j_left => .left,
                    .j_right => .right,
                    .j_top => .top,
                    .j_bottom => .bottom,
                    .j_center => .center,
                    else => unreachable,
                });
                new.u = res.u;
                new.v = res.v;
            },
            .u_flip => new.u.axis = new.u.axis.scale(-1),
            .v_flip => new.v.axis = new.v.axis.scale(-1),
            .swap => std.mem.swap(Vec3, &new.u.axis, &new.v.axis),
            .reset_world, .reset_norm => {
                const norm = side.normal(sel.solid);
                side.resetUv(norm, btn_k == .reset_norm);
                //TODO put this into the undo stack
                sel.solid.rebuild(self.id orelse return, self.ed) catch return;
                self.ed.draw_state.meshes_dirty = true;
            },
            .make_disp => {
                const sel_id = self.id orelse return;
                const face_id = self.face_index orelse return;
                if (self.ed.getComponent(sel_id, .displacements) == null) {
                    const disp = try ecs.Displacements.init(self.ed.alloc, sel.solid.sides.items.len);
                    try self.ed.ecs.attach(sel_id, .displacements, disp);
                }
                if (self.ed.getComponent(sel_id, .displacements)) |disp| {
                    if (disp.getDispPtr(face_id) == null) {
                        const normal = side.normal(sel.solid);
                        var new_disp = try ecs.Displacement.init(self.ed.alloc, side.tex_id, face_id, 2, normal.scale(-1));
                        try new_disp.genVerts(sel.solid, self.ed);
                        try disp.put(new_disp, face_id);
                    }
                }
                if (self.win_ptr) |win|
                    win.needs_rebuild = true;
            },
            .subdivide => {
                const sel_id = self.id orelse return;
                const face_id = self.face_index orelse return;
                if (self.ed.getComponent(sel_id, .displacements)) |disp| {
                    if (disp.getDispPtr(face_id)) |dface| {
                        try dface.subdivide(sel_id, self.ed);
                    }
                }
            },
        }
        if (!old.eql(new)) {
            if (self.win_ptr) |win|
                win.needs_rebuild = true;
            const ustack = try self.ed.undoctx.pushNewFmt("texture manip", .{});
            try ustack.append(try undo.UndoTextureManip.create(
                self.ed.undoctx.alloc,
                old,
                new,
                self.id orelse return,
                self.face_index orelse return,
            ));
            undo.applyRedo(ustack.items, self.ed);
        }
    }

    fn getCurrentlySelected(self: *TextureTool, editor: *Editor) !?struct { solid: *ecs.Solid, side: *ecs.Side } {
        const id = self.id orelse return null;
        const solid = editor.getComponent(id, .solid) orelse return null;
        if (self.face_index == null or self.face_index.? >= solid.sides.items.len) return null;

        return .{ .solid = solid, .side = &solid.sides.items[self.face_index.?] };
    }

    fn run(self: *TextureTool, td: tools.ToolData, editor: *Editor) !void {
        if (editor.edit_state.lmouse == .rising) {
            const pot = editor.screenRay(td.screen_area, td.view_3d.*);
            if (pot.len > 0) {
                self.id = pot[0].id;
                self.face_index = pot[0].side_id;
            }
            if (self.win_ptr) |win|
                win.needs_rebuild = true;
        }
        blk: {
            if (editor.edit_state.rmouse == .rising) {
                if (self.win_ptr) |win|
                    win.needs_rebuild = true;
                const dupe = editor.isBindState(editor.config.keys.texture_wrap.b, .high);
                const pick = editor.isBindState(editor.config.keys.texture_eyedrop.b, .high);

                const pot = editor.screenRay(td.screen_area, td.view_3d.*);
                if (pot.len == 0) break :blk;
                const solid = editor.getComponent(pot[0].id, .solid) orelse break :blk;
                if (pot[0].side_id == null or pot[0].side_id.? >= solid.sides.items.len) break :blk;
                const side = &solid.sides.items[pot[0].side_id.?];
                self.state = if (pick) .pick else .apply;
                switch (self.state) {
                    .apply => {
                        const currently_selected = (editor.asset_browser.selected_mat_vpk_id) orelse break :blk;
                        const source = src: {
                            if (dupe) {
                                if (try self.getCurrentlySelected(editor)) |f| {
                                    var duped = side.*;
                                    duped.u.trans = f.side.u.trans;
                                    duped.u.scale = f.side.u.scale;
                                    duped.v.trans = f.side.v.trans;
                                    duped.v.scale = f.side.v.scale;

                                    {
                                        const v2 = duped.normal(solid);
                                        const v1 = f.side.normal(f.solid);
                                        const dot = v1.dot(v2);
                                        const ang = std.math.radiansToDegrees(
                                            std.math.acos(dot),
                                        );
                                        const mat = graph.za.Mat3.fromRotation(ang, v1.cross(v2));
                                        duped.u.axis = mat.mulByVec3(f.side.u.axis);
                                        duped.v.axis = mat.mulByVec3(f.side.v.axis);

                                        const rstart = f.solid.verts.items[f.side.index.items[0]];
                                        const p0 = pot[0].point;
                                        const pn = v2;
                                        if (util3d.doesRayIntersectPlane(rstart, f.side.u.axis, p0, pn)) |I| {
                                            const tw: f32 = @floatFromInt(duped.tw);
                                            const sc = duped.u.scale;

                                            duped.u.trans += @mod((I.dot(f.side.u.axis) - I.dot(duped.u.axis)) / sc, tw);
                                        }
                                        if (util3d.doesRayIntersectPlane(rstart, f.side.v.axis, p0, pn)) |I| {
                                            const th: f32 = @floatFromInt(duped.th);
                                            const sc = duped.v.scale;
                                            duped.v.trans += @mod((I.dot(f.side.v.axis) - I.dot(duped.v.axis)) / sc, th);
                                        }
                                    }

                                    break :src duped;
                                }
                            }
                            break :src side.*;
                        };

                        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
                        const new = undo.UndoTextureManip.State{ .u = source.u, .v = source.v, .tex_id = currently_selected, .lightmapscale = side.lightmapscale };

                        const ustack = try editor.undoctx.pushNewFmt("texture manip", .{});
                        try ustack.append(try undo.UndoTextureManip.create(editor.undoctx.alloc, old, new, pot[0].id, pot[0].side_id.?));
                        undo.applyRedo(ustack.items, editor);
                    },
                    .pick => {
                        if (side.tex_id == edit.missingTexture().id) return; //Missing texture
                        try editor.asset_browser.recent_mats.put(side.tex_id);
                        editor.asset_browser.selected_mat_vpk_id = side.tex_id;
                    },
                }
            }
        }

        //Draw a red outline around the face
        //And other draw stuff, too
        if (try self.getCurrentlySelected(editor)) |sel| {
            const v = sel.solid.verts.items;
            const ind = sel.side.index.items;
            if (ind.len > 0) {
                var last = v[ind[ind.len - 1]];
                for (0..ind.len) |ti| {
                    const p = v[ind[ti]];
                    editor.draw_state.ctx.line3D(last, p, 0xff0000ff, self.line_thickness);
                    last = p;
                }
            }
            if (self.show_disp_normal) {
                if (editor.getComponent(self.id orelse return, .displacements)) |disps| {
                    for (disps.disps.items) |disp| {
                        for (disp._verts.items, 0..) |vert, i| {
                            const norm = disp.normals.items[i];
                            editor.draw_state.ctx.line3D(vert, vert.add(norm.scale(8)), 0x66CDAAff, self.line_thickness);
                        }
                    }
                }
            }
        }
    }
};
