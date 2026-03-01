const NORM_THRESH = 0.99;
pub const FastFaceManip = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;

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

    pub fn create(alloc: std.mem.Allocator, ed: *Editor) !*i3DTool {
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
        obj.vt.key_ctx_mask.setValue(ed.conf.binds.fast_face.context_id, true);
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
    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) tools.ToolError!void {
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
                                const dist = editor.grid.snapDelta(pos);

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

                                        const dist_rounded = toolutil.roundForDrawing(dist);
                                        toolutil.drawText3D(
                                            self.start.add(dist),
                                            &editor.draw_state.screen_space_text_ctx,
                                            td.text_param,
                                            td.screen_area,
                                            td.view_3d.*,
                                            "[{d} {d} {d}]",
                                            .{
                                                dist_rounded.x(),
                                                dist_rounded.y(),
                                                dist_rounded.z(),
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

                                for (self.selected.items) |*sel| {
                                    sel.invert_norm = false;
                                    const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                    if (sel.side_i >= solid_o.sides.items.len) continue;
                                    const s_io: usize = @intCast(sel.side_i);
                                    const side_o = &solid_o.sides.items[s_io];
                                    const inv = canInvertNormals(solid_o, sel.side_i, dist);
                                    sel.invert_norm = inv == .invert;
                                    solid_o.drawImmediate(td.draw, editor, dist, side_o.index.items, .{ .texture_lock = false, .invert_normal = inv == .invert }) catch return;
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
        var ly = guis.VerticalLayout{ .item_height = gui.dstate.nstyle.item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        _ = Wg.TextView.build(area_vt, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        });
        const CB = Wg.Checkbox.build;
        _ = CB(area_vt, ly.getArea(), "Draw Grid", .{ .bool_ptr = &self.draw_grid }, null);
    }
};

/// If there exists a face with the opposite normal and all other faces share an edge with both the moved and opposite side
/// then the side can be pulled through the opposite and normals inverted
fn canInvertNormals(solid: *const ecs.Solid, side_i: u32, dist: Vec3) enum {
    not_invertible,
    not_inverted,
    invert,
} {
    const d = dist.length();
    if (d == 0) return .not_inverted;

    const side_norm = solid.sides.items[side_i].normal(solid);

    const opp_side = blk: {
        for (solid.sides.items, 0..) |*side, s_i| {
            if (s_i == side_i) continue;
            const norm = side.normal(solid);

            if (norm.dot(side_norm) <= -NORM_THRESH) {
                break :blk s_i;
            }
        }
        return .not_invertible;
    };

    const other_v = solid.sides.items[opp_side].getP0(solid) orelse return .not_inverted;
    const this_v = solid.sides.items[side_i].getP0(solid) orelse return .not_inverted;

    const opp_dist = other_v.sub(this_v.add(dist));

    const opp_n = opp_dist.dot(side_norm);

    // We haven't reached the opposite side yet
    if (opp_n >= 0) return .not_inverted;

    const side = &solid.sides.items[side_i];
    const opp = &solid.sides.items[opp_side];

    for (solid.sides.items, 0..) |*o_side, s_i| {
        if (s_i == opp_side or s_i == side_i) continue;

        //Each vertex of every other side must belong to either side or opp
        for (o_side.index.items) |ind| {
            if (std.mem.indexOfScalar(u32, side.index.items, ind) == null and
                std.mem.indexOfScalar(u32, opp.index.items, ind) == null) return .not_invertible;
        }
    }
    return .invert;
}

const std = @import("std");
const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const Vec3 = graph.za.Vec3;
const ecs = @import("../ecs.zig");
const graph = @import("graph");
const action = @import("../actions.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const ToolData = tools.ToolData;
const ToolEvent = tools.ToolEvent;
const Editor = edit.Context;
const toolutil = @import("../tool_common.zig");
const util3d = graph.util_3d;
const gridutil = @import("../grid.zig");
const colors = @import("../colors.zig").colors;
pub const Inspector = @import("../windows/inspector.zig").InspectorWindow;
const iArea = guis.iArea;
const guis = graph.RGui;
const RGui = guis.Gui;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const edit = @import("../editor.zig");
