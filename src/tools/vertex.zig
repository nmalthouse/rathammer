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
const util3d = graph.util_3d;
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const L = @import("../locale.zig");
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const DrawCtx = graph.ImmediateDrawingContext;
const graph = @import("graph");
const edit = @import("../editor.zig");
const Editor = edit.Context;
const toolutil = @import("../tool_common.zig");
pub const VertexTranslate = struct {
    const Self = @This();
    const Btn = enum {
        snap_selected,
    };
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    const Sel = std.MultiArrayList(struct {
        vert: Vec3,
        index: u32,
        disp_i: ?u32 = null,
    });

    //How will the vertex translation work?
    //Selection works like normal selection, but uses mouse clicks or whatever.
    //only verticies of selected objects can be selected
    //if vert_sel > 0, a translate gizmo is active
    //This tool can easily create invalid geometry, maybe warn user?
    //
    //How do we determine if we have intersected a vertex.
    //perpendicalr distance from line to point is easy to find?
    //distance we want to accept depends on our distance from vertex

    vt: i3DTool,
    selected: std.AutoHashMap(ecs.EcsT.Id, Sel),

    cbhandle: guis.CbHandle = .{},

    /// The perpendicular distance between a vertex and the mouse's ray must be smaller than the distance from vertex to camera multiplied by this factor to be a
    /// candidate for selection.
    ray_vertex_scale_factor: f32 = 0.04,

    selection_mode: enum {
        /// Add or remove all candidate verticies.
        many,
        /// Add or remove the first vertex encountered.
        /// This a cheap way to let users fix overlapping verticies within a solid.
        one,
    } = .many,

    do_displacements: bool = true,

    gizmo: Gizmo = .{},
    gizmo_position: Vec3 = Vec3.zero(),
    ed: *Editor,
    bounds_min: Vec3 = Vec3.zero(),
    bounds_max: Vec3 = Vec3.zero(),

    dist: Vec3 = Vec3.zero(),

    snap_absolute: bool = true,
    state_2d: struct {
        marquee_start: Vec3 = Vec3.zero(),
        marquee_end: Vec3 = Vec3.zero(),
        move_start: ?Vec3 = null,
    } = .{},

    pub fn create(alloc: std.mem.Allocator, ed: *Editor) !*i3DTool {
        var self = try alloc.create(@This());
        self.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .tool_icon_fn = &drawIcon,
                .runTool_fn = &runTool,
                .runTool_2d_fn = &runTool2d,
                .gui_build_cb = &buildGui,
                .event_fn = &event,
            },
            .ed = ed,
            .selected = std.AutoHashMap(ecs.EcsT.Id, Sel).init(alloc),
        };
        self.vt.key_ctx_mask.setValue(ed.conf.binds.vertex.context_id, true);
        return &self.vt;
    }

    fn raycastVert(self: *Self, ray: [2]Vec3, vert: Vec3, draw: *DrawCtx, ed: *Editor) bool {
        const POT_VERT_COLOR = 0x66CDAAff;
        const proj = util3d.projectPointOntoRay(ray[0], ray[1], vert);
        const cam_dist = ray[0].distance(vert);
        const distance = proj.distance(vert);
        if (cam_dist > 0 and distance < (cam_dist * self.ray_vertex_scale_factor)) {
            draw.point3D(vert, POT_VERT_COLOR, ed.config.dot_size);
            return true;
        }
        return false;
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.reset();
        //self.selected_verts.deinit();
        self.selected.deinit();
        alloc.destroy(self);
    }

    fn reset(self: *Self) void {
        //self.selected_verts.clearRetainingCapacity();
        self.gizmo_position = Vec3.zero();
        var it = self.selected.valueIterator();
        while (it.next()) |item|
            item.deinit(self.selected.allocator);
        self.selected.clearRetainingCapacity();
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("vertex.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, ed: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runVertex(td, ed) catch return error.fatal;
    }

    pub fn runTool2d(vt: *i3DTool, td: tools.ToolData, ed: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.tool2d(td, ed) catch return error.fatal;
    }

    pub fn event(vt: *i3DTool, ev: tools.ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus, .reFocus => {
                self.reset();
            },
            else => {},
        }
    }

    fn tool2d(self: *Self, td: tools.ToolData, ed: *Editor) !void {
        const cam = td.cam2d orelse return;
        const new_pos = ed.win.mouse.pos.sub(cam.screen_area.pos());
        const r = util3d.screenSpaceRay(
            td.screen_area.dim(),
            new_pos,
            td.view_3d.*,
        );
        const draw_nd = &ed.draw_state.ctx;
        const do_marquee = !ed.isBindState(ed.conf.binds.vertex.do_marquee, .high);
        const had_selection = try self.updateSelection(td, ed, do_marquee, draw_nd, r);
        if (self.dist.length() > 0) {
            var it = self.selected.iterator();
            while (it.next()) |item| {
                for (item.value_ptr.items(.vert)) |vert| {
                    draw_nd.point3D(vert.add(self.dist), 0xff0000ff, ed.config.dot_size);
                }
            }
        }
        //TODO put this with the drawn stuff.
        const z_scale = 100_000;

        var st = &self.state_2d;
        const lmouse = ed.edit_state.lmouse;
        const mpos = ed.edit_state.mpos;
        if (do_marquee) {
            switch (lmouse) {
                else => {},
                .rising => {
                    if (td.screen_area.containsPoint(mpos)) {
                        st.marquee_start = r[0];
                    }
                },
                .high => {
                    const end = r[0].add(r[1]);
                    st.marquee_end = end;
                    const cc = util3d.cubeFromBounds(st.marquee_start, end);
                    draw_nd.cubeFrame(cc[0], cc[1], 0xff0000ff);
                },
                .falling => {
                    const cc = util3d.cubeFromBounds(st.marquee_start.add(r[1].scale(-z_scale)), st.marquee_end.add(r[1].scale(z_scale)));
                    const min = cc[0];
                    const max = min.add(cc[1]);
                    const selected_slice = ed.getSelected();
                    for (selected_slice) |sel| {
                        const disps_o = if (self.do_displacements) ed.getComponent(sel, .displacements) else null;
                        if (disps_o) |disps| {
                            for (disps.disps.items, 0..) |disp, disp_i| {
                                for (disp._verts.items, 0..) |vert, v_i| {
                                    if (util3d.doesBBContainPoint(min, max, vert)) {
                                        try self.addOrRemoveVert(sel, @intCast(v_i), vert, @intCast(disp_i));
                                    }
                                }
                            }
                        } else if (ed.getComponent(sel, .solid)) |solid| {
                            for (solid.verts.items, 0..) |vert, v_i| {
                                if (util3d.doesBBContainPoint(min, max, vert)) {
                                    try self.addOrRemoveVert(sel, @intCast(v_i), vert, null);
                                }
                            }
                        }
                    }
                    self.setGizmoPositionToMean();
                },
            }
        } else if (!had_selection) {
            var delta = Vec3.zero();
            switch (lmouse) {
                .rising => {
                    st.move_start = r[0];
                },
                .high, .rising_repeat => {
                    if (st.move_start) |start| {
                        delta = r[0].sub(start);
                    }
                    self.dist = ed.grid.snapV3(delta);
                    if (self.selected.count() == 1) {
                        var it = self.selected.iterator();
                        const item = it.next() orelse return;
                        if (item.value_ptr.items(.vert).len == 1) {
                            self.dist = self.snapVertDist(item.value_ptr.items(.vert)[0], delta, &ed.grid);
                        }
                    }

                    if (ed.edit_state.rmouse == .rising) {
                        try self.commitDist(self.dist, ed);
                    }
                },
                .falling, .low => {
                    if (lmouse == .falling)
                        self.dist = Vec3.zero();
                    st.move_start = null;
                },
            }
            {
                const cc1 = util3d.cubeFromBounds(self.bounds_min, self.bounds_max.add(r[1]));
                const dist = ed.grid.snapV3(delta);
                draw_nd.cube(cc1[0].add(dist), cc1[1], 0xffffff88);
            }
        }
    }

    fn commitDist(self: *Self, dist: Vec3, ed: *Editor) !void {
        const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.vertex_translate});
        for (ed.getSelected()) |id| {
            const manip_verts = self.selected.getPtr(id) orelse continue;
            if (manip_verts.items(.index).len == 0) continue;

            const disps_o = if (self.do_displacements) ed.getComponent(id, .displacements) else null;
            if (disps_o) |_| {
                const ar = ed.frame_arena.allocator();
                var present = std.AutoHashMap(u32, void).init(ar);
                var offsets: std.ArrayList(Vec3) = .{};
                var offset_index: std.ArrayList(u32) = .{};

                for (manip_verts.items(.disp_i)) |did| {
                    if (did) |d|
                        try present.put(d, {});
                }

                var it = present.keyIterator();
                while (it.next()) |disp_id| {
                    offsets.clearRetainingCapacity();
                    offset_index.clearRetainingCapacity();
                    for (manip_verts.items(.disp_i), 0..) |did, ind| {
                        if (did orelse continue == disp_id.*) {
                            try offsets.append(ar, dist);
                            try offset_index.append(ar, manip_verts.items(.index)[ind]);
                        }
                    }
                    try ustack.append(.{ .disp_modify = try .create(
                        ed.undoctx.alloc,
                        id,
                        disp_id.*,
                        offsets.items,
                        offset_index.items,
                    ) });
                }
                // Determine which disp sides are present in manip_verts
                // for each put a dispmodify
            } else {
                try ustack.append(.{ .vertex_translate = try .create(
                    ed.undoctx.alloc,
                    id,
                    dist,
                    manip_verts.items(.index),
                    null,
                ) });
            }
        }
        ustack.apply(ed);

        var it = self.selected.iterator();
        while (it.next()) |item| {
            for (item.value_ptr.items(.vert)) |*vert| {
                vert.* = vert.add(dist);
            }
        }
    }

    fn updateSelection(self: *Self, td: tools.ToolData, ed: *Editor, do_selection: bool, draw_nd: *DrawCtx, ray: [2]Vec3) !bool {
        const ar = ed.frame_arena.allocator();
        // every frame, stick all selected into here and then use it to prune unselected;
        var id_mapper = std.AutoHashMap(ecs.EcsT.Id, void).init(ar);
        const selected_slice = ed.getSelected();

        const lm = ed.edit_state.lmouse;
        //const r = ed.camRay(td.screen_area, td.view_3d.*);
        var this_frame_had_selection = false;
        solid_loop: for (selected_slice) |sel| {
            const disps_o = if (self.do_displacements) ed.getComponent(sel, .displacements) else null;
            if (disps_o) |disps| {
                try id_mapper.put(sel, {});

                for (disps.disps.items, 0..) |disp, disp_i| {
                    if (disp._index.items.len % 3 == 0) {
                        var i: usize = 0;
                        while (i < disp._index.items.len) : (i += 6) {
                            // The index are layed out such that the first and last vertices don't need to be linked
                            // 0 3 2    0 1 3
                            // t1       t2
                            // line (i, i+1) -> this covers all lines once with above order
                            // that is why we end at 5 and omit the %
                            for (0..5) |aug| {
                                const v1 = disp._verts.items[disp._index.items[i + aug]];
                                const v2 = disp._verts.items[disp._index.items[(aug + 1) + i]];
                                draw_nd.line3D(v1, v2, 0xffff00ff, 2);
                            }
                        }
                    }
                    for (disp._verts.items, 0..) |vert, v_i| {
                        td.draw.point3D(vert, 0xff0000ff, 12);

                        if ((this_frame_had_selection and self.selection_mode == .one) or !do_selection)
                            continue; //skip raycast code but still draw the points so no flashing

                        if (self.raycastVert(ray, vert, draw_nd, ed)) {
                            if (lm == .rising) {
                                this_frame_had_selection = true;
                                try self.addOrRemoveVert(sel, @intCast(v_i), vert, @intCast(disp_i));
                            }
                        }
                    }
                }
            } else if (ed.getComponent(sel, .solid)) |solid| {
                solid.drawEdgeOutline(td.draw, Vec3.zero(), .{
                    .point_color = 0xff_0000_77,
                    .point_size = ed.config.dot_size,
                });
                try id_mapper.put(sel, {});

                if (!do_selection)
                    continue; //Gizmo has priority over vert selection
                for (solid.verts.items, 0..) |vert, v_i| {
                    if (this_frame_had_selection and self.selection_mode == .one)
                        continue :solid_loop;
                    if (self.raycastVert(ray, vert, draw_nd, ed)) {
                        if (lm == .rising) {
                            this_frame_had_selection = true;
                            try self.addOrRemoveVert(sel, @intCast(v_i), vert, null);
                        }
                    }
                }
            }
        }
        if (this_frame_had_selection) {
            self.setGizmoPositionToMean();
        }
        const SEL_VERT_COLOR = 0xBA55D3ff;
        {
            var it = self.selected.iterator();
            var to_remove = std.ArrayList(ecs.EcsT.Id){};
            while (it.next()) |item| {
                //Remove any verts that don't belong to a globally selected solid
                if (!id_mapper.contains(item.key_ptr.*)) {
                    try to_remove.append(ar, item.key_ptr.*);

                    //We deinit here so we can quickly remove after loop
                    item.value_ptr.deinit(self.selected.allocator);
                    continue; //Don't draw, memory has been freed
                }
                const verts = item.value_ptr.items(.vert);
                for (verts) |v|
                    draw_nd.point3D(v, SEL_VERT_COLOR, ed.config.dot_size);
            }
            for (to_remove.items) |rem| {
                _ = self.selected.remove(rem);
            }
        }
        return this_frame_had_selection;
    }

    fn addOrRemoveVert(self: *Self, id: ecs.EcsT.Id, vert_index: u16, vert: Vec3, disp_i: ?u32) !void {
        const res = try self.selected.getOrPut(id);
        if (!res.found_existing) {
            res.value_ptr.* = .{};
        }

        for (res.value_ptr.items(.index), 0..) |item, vi| {
            if (item == vert_index and res.value_ptr.items(.disp_i)[vi] == disp_i) {
                _ = res.value_ptr.swapRemove(vi);
                return;
            }
        }
        try res.value_ptr.append(self.selected.allocator, .{
            .vert = vert,
            .index = vert_index,
            .disp_i = disp_i,
        });
    }

    fn snapVertDist(self: *Self, v: Vec3, dist: Vec3, grid: anytype) Vec3 {
        if (self.snap_absolute) {
            const new = grid.snapV3(v.add(dist));
            return new.sub(v);
        }
        return dist;
    }

    fn setGizmoPositionToMean(self: *Self) void {
        self.gizmo_position = Vec3.zero();
        var bounds_min = Vec3.set(std.math.floatMax(f32));
        var bounds_max = bounds_min.scale(-1);
        var count: usize = 0;

        var it = self.selected.valueIterator();
        while (it.next()) |sel| {
            const verts = sel.items(.vert);
            count += verts.len;
            for (verts) |v| {
                self.gizmo_position = self.gizmo_position.add(v);
                bounds_min.data = @min(bounds_min.data, v.data);
                bounds_max.data = @max(bounds_max.data, v.data);
            }
        }
        self.bounds_min = bounds_min;
        self.bounds_max = bounds_max;
        if (count == 0) //prevent div by zero
            return;

        self.gizmo_position = self.gizmo_position.scale(1 / @as(f32, @floatFromInt(count)));
    }

    //TODO Make this suck less
    pub fn runVertex(self: *Self, td: tools.ToolData, ed: *Editor) !void {
        const draw_nd = &ed.draw_state.ctx;
        const selected_slice = ed.getSelected();
        //const lm = ed.edit_state.lmouse;
        //const r = ed.camRay(td.screen_area, td.view_3d.*);
        //const POT_VERT_COLOR = 0x66CDAAff;

        var is_active = false;
        if (self.selected.count() > 0) {
            const origin = self.gizmo_position;
            var origin_mut = origin;
            const giz_active = self.gizmo.handle(
                origin,
                &origin_mut,
                ed.draw_state.cam3d.pos,
                ed.edit_state.lmouse,
                draw_nd,
                td.screen_area,
                td.view_3d.*,
                ed,
            );
            is_active = !(giz_active == .low);

            const commit = ed.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;

            const dist = ed.grid.snapV3(origin_mut.sub(origin));
            if (giz_active == .falling)
                self.dist = Vec3.zero();
            if (giz_active == .high) {
                toolutil.drawDistance(origin, dist, &ed.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
                self.dist = dist;
            }
            for (selected_slice) |id| {
                const manip_verts = self.selected.getPtr(id) orelse continue;

                const disps_o = if (self.do_displacements) ed.getComponent(id, .displacements) else null;
                if (disps_o) |disps| {
                    switch (giz_active) {
                        else => {},
                        .rising => {
                            if (ed.getComponent(id, .solid)) |solid| {
                                try solid.removeFromMeshMap(id, ed);
                            }
                        },
                        .falling => {
                            for (disps.disps.items) |*disp| {
                                try disp.markForRebuild(id, ed);
                            }
                            if (ed.getComponent(id, .solid)) |solid| {
                                //Dummy to put it bake in the mesh batch
                                try solid.translate(id, Vec3.zero(), ed, Vec3.zero(), null);
                            }
                        },
                        .high => {
                            const Help = struct {
                                dist: Vec3,

                                verts: []const u32,
                                disp_i: []const ?u32,
                                disp_index: u32,

                                fn offset(h: @This(), _: Vec3, index: u32) Vec3 {
                                    for (h.verts, 0..) |v, vi| {
                                        if (v == index and h.disp_i[vi] == h.disp_index)
                                            return h.dist;
                                    }
                                    return Vec3.zero();
                                }
                            };
                            for (disps.disps.items, 0..) |*disp, disp_index| {
                                const h = Help{
                                    .dist = dist,
                                    .verts = manip_verts.items(.index),
                                    .disp_i = manip_verts.items(.disp_i),
                                    .disp_index = @intCast(disp_index),
                                };
                                try disp.drawImmediate(td.draw, ed, id, h, Help.offset);
                            }
                        },
                    }
                } else if (ed.getComponent(id, .solid)) |solid| {
                    switch (giz_active) {
                        .low => {},
                        .rising => {
                            try solid.removeFromMeshMap(id, ed);
                        },
                        .falling => {
                            try solid.translate(id, Vec3.zero(), ed, Vec3.zero(), null); //Dummy to put it bake in the mesh batch

                            //Draw it here too so we it doesn't flash for a single frame
                            try solid.drawImmediate(td.draw, ed, dist, null, false);
                        },

                        .high, .rising_repeat => {
                            try solid.drawImmediate(td.draw, ed, dist, manip_verts.items(.index), false);
                        },
                    }
                }
            }
            if (real_commit)
                try self.commitDist(dist, ed);
        }

        const r = ed.camRay(td.screen_area, td.view_3d.*);
        _ = try self.updateSelection(td, ed, !is_active, draw_nd, r);
    }

    pub fn buildGui(vt: *i3DTool, _: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the vertex translate tool.
            \\Select a solid with 'E'
            \\Mouse over the verticies and left click to add the vertex
        ;
        var ly = gui.dstate.vlayout(area_vt.area);
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });

        if (guis.label(area_vt, ly.getArea(), "{s}", .{L.lang.tool.vtx_selection_mode})) |ar|
            _ = Wg.Combo.build(area_vt, ar, &self.selection_mode, .{});
        _ = Wg.Checkbox.build(area_vt, ly.getArea(), L.lang.checkbox.modify_displacement, .{ .bool_ptr = &self.do_displacements }, null);
        _ = Wg.Button.build(area_vt, ly.getArea(), L.lang.btn.snap_selected_to_int, .{
            .cb_vt = &self.cbhandle,
            .cb_fn = &btn_cb,
            .id = @intFromEnum(Btn.snap_selected),
        });
    }

    pub fn btn_cb(vt: *guis.CbHandle, id: usize, dat: guis.MouseCbState, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cbhandle", vt));
        self.btn_cbErr(id, dat.gui, win) catch return;
    }
    pub fn btn_cbErr(self: *@This(), id: usize, _: *RGui, _: *guis.iWindow) !void {
        const btn_k = @as(Btn, @enumFromInt(id));
        switch (btn_k) {
            .snap_selected => {
                var it = self.selected.iterator();
                while (it.next()) |item| {
                    if (self.ed.getComponent(item.key_ptr.*, .solid)) |solid| {
                        const disps_o = self.ed.getComponent(item.key_ptr.*, .displacements);
                        const sl = item.value_ptr.*;
                        for (sl.items(.index), 0..) |ind, i| {
                            if (sl.items(.disp_i)[i]) |di| {
                                if (disps_o) |disps| {
                                    const disp = disps.getDispPtrFromDispId(di) orelse continue;
                                    const old_vert = disp._verts.items[ind];

                                    const new_vert = util3d.snapV3(old_vert, 1);
                                    disp.offsets.items[ind] = disp.offsets.items[ind].add(new_vert.sub(old_vert));
                                }
                            } else {
                                solid.verts.items[ind] = util3d.snapV3(solid.verts.items[ind], 1);
                            }
                        }
                    }
                }
            },
        }
    }
};
