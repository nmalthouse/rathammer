const tools = @import("../tools.zig");
const util3d = @import("../util_3d.zig");
const edit = @import("../editor.zig");
const Editor = edit.Context;
const std = @import("std");
const graph = @import("graph");
const raycast = @import("../raycast_solid.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const undo = @import("../undo.zig");
const Vec3 = graph.za.Vec3;
const toolutil = @import("../tool_common.zig");
const action = @import("../actions.zig");

pub const Clipping = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    //How will this work.
    //Clipping works by defining a plane
    //if the first two points lie on the same face we can infer the desired plane's normal, this is a good default
    //
    //I think hammer only allows planes with a normal perpendicular to cardinal axis
    //In hammer the clip line can start or end outside the solid
    //Select a plane in world, put lines on that

    vt: tools.i3DTool,
    plane_norm: Vec3 = Vec3.zero(),
    plane_p0: Vec3 = Vec3.zero(),
    selected_side: ?raycast.RcastItem = null,
    ray_vertex_distance_max: f32 = 5,

    points: [3]Vec3,
    state: enum {
        init,
        point0,
        point1,
        done,
    } = .init,

    grabbed: ?struct { ptr: *Vec3, init: Vec3, plane: Vec3, p0: Vec3 } = null,

    pub fn create(alloc: std.mem.Allocator) !*tools.i3DTool {
        var clip = try alloc.create(@This());
        clip.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .tool_icon_fn = &drawIcon,
                .runTool_fn = &runTool,
                .runTool_2d_fn = &runTool2d,
                .event_fn = &event,
            },
            .points = undefined,
        };
        return &clip.vt;
    }

    pub fn deinit(vt: *tools.i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    fn reset(self: *@This()) void {
        self.state = .init;
        self.selected_side = null;
        self.grabbed = null;
    }

    pub fn event(vt: *tools.i3DTool, ev: tools.ToolEvent, _: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (ev) {
            .focus, .reFocus => {
                self.reset();
            },
            else => {},
        }
    }

    pub fn drawIcon(vt: *tools.i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("clipping.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn runTool(vt: *tools.i3DTool, td: tools.ToolData, ed: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runToolErr(td, ed) catch return error.nonfatal;
    }

    pub fn runTool2d(vt: *tools.i3DTool, td: tools.ToolData, ed: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runTool2dErr(td, ed) catch return error.nonfatal;
    }

    fn commitGrab(self: *@This()) void {
        if (self.grabbed) |*g| {
            g.init = g.ptr.*;
        }
    }

    fn cancelGrab(self: *@This()) void {
        if (self.grabbed) |g| {
            g.ptr.* = g.init;
        }
        self.grabbed = null;
    }

    pub fn runTool2dErr(self: *@This(), td: tools.ToolData, ed: *Editor) !void {
        _ = td;
        _ = ed;
        _ = self;
    }

    pub fn runToolErr(self: *@This(), td: tools.ToolData, ed: *Editor) !void {
        const draw_nd = &ed.draw_state.ctx;

        const rc = ed.camRay(td.screen_area, td.view_3d.*);
        const lm = ed.edit_state.lmouse;
        switch (self.state) {
            .init => {
                const sel = ed.getSelected();
                ed.rayctx.reset();

                for (sel) |s_id| {
                    try ed.rayctx.addPotentialSolid(&ed.ecs, rc[0], rc[1], &ed.csgctx, s_id);
                }
                const pot = ed.rayctx.sortFine();
                if (pot.len > 0) {
                    const inter = pot[0];
                    const solid = try ed.ecs.getPtr(inter.id, .solid);
                    const snapped = ed.grid.snapV3(inter.point);
                    draw_nd.point3D(snapped, 0xff_0000_ff, ed.config.dot_size);
                    if (lm != .rising) return;
                    const side_id = inter.side_id orelse return;
                    if (side_id >= solid.sides.items.len) return;
                    self.plane_p0 = snapped;
                    self.plane_norm = solid.sides.items[side_id].normal(solid);
                    self.selected_side = inter;
                    self.state = .point1;
                    self.points[0] = snapped;
                }
            },
            .point0, .point1 => {
                const sel_side = self.selected_side orelse {
                    self.reset();
                    return;
                };
                const solid = try ed.ecs.getPtr(sel_side.id, .solid);
                const side_o = solid.getSidePtr(sel_side.side_id) orelse return;
                draw_nd.convexPolyIndexed(side_o.index.items, solid.verts.items, 0xffff_88, .{});
                if (self.state == .point1)
                    draw_nd.point3D(self.points[0], 0xff_0000_ff, ed.config.dot_size);
                if (util3d.doesRayIntersectPlane(rc[0], rc[1], self.plane_p0, self.plane_norm)) |inter| {
                    const snapped = ed.grid.snapV3(inter);
                    draw_nd.point3D(snapped, 0xff_0000_ff, ed.config.dot_size);
                    if (lm != .rising) return;
                    self.points[if (self.state == .point0) 0 else 1] = snapped;
                    switch (self.state) {
                        else => {
                            self.reset();
                            return;
                        },
                        .point0 => self.state = .point1,
                        .point1 => {
                            const dist = self.points[0].distance(self.points[1]);
                            if (dist > 0) {
                                self.state = .done;
                                // We use point 0 so that the plane_p0 can be used for all points
                                self.points[2] = self.points[0].add(self.plane_norm.scale(-dist));
                            }
                        },
                    }
                }
            },
            .done => {
                grab_blk: {
                    const grab = &(self.grabbed orelse break :grab_blk);
                    if (util3d.doesRayIntersectPlane(rc[0], rc[1], grab.p0, grab.plane)) |inter|
                        grab.ptr.* = ed.grid.snapV3(inter);
                    if (lm == .falling) {
                        self.commitGrab();
                        self.cancelGrab();
                    }
                }

                const p0 = self.points[0];
                const p1 = self.points[1];
                const p2 = self.points[2];
                const diff = p0.sub(p1);
                const dist = diff.length();
                const dir = diff.norm();
                draw_nd.line3D(p0.add(dir.scale(-dist)), p0.add(dir.scale(dist)), 0xffff_ffff, 2);
                const point_color = [self.points.len]u32{
                    0x00_0000_ff,
                    0xff_0000_ff,
                    0x00_00ff_ff,
                };
                const hover_point = 0xffff00_ff;
                for (self.points, 0..) |p, i| {
                    const proj = util3d.projectPointOntoRay(rc[0], rc[1], p);
                    const distance = proj.distance(p);
                    if (self.grabbed == null and distance < self.ray_vertex_distance_max and i != 0) {
                        draw_nd.point3D(p, hover_point, ed.config.dot_size);
                        if (lm == .rising) {
                            const norm = switch (i) {
                                else => self.plane_norm,
                                //Special for the third pointt
                                2 => self.points[0].sub(self.points[1]).norm(),
                            };
                            self.grabbed = .{
                                .ptr = &self.points[i],
                                .init = p,
                                .plane = norm,
                                .p0 = self.plane_p0,
                            };
                        }
                    } else {
                        draw_nd.point3D(p, point_color[i], ed.config.dot_size);
                    }
                }
                { // Draw the numbers
                    toolutil.drawPoint(p0, &ed.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
                    toolutil.drawPoint(p1, &ed.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
                    toolutil.drawPoint(p2, &ed.draw_state.screen_space_text_ctx, td.text_param, td.screen_area, td.view_3d.*);
                }

                const pnorm = util3d.trianglePlane(.{ p0, p1, p2 }).norm();
                { //Draw the clip plane
                    const cut_dir = p2.sub(p0).norm();
                    const r0 = p0.add(cut_dir.scale(100));
                    const r1 = p0.add(cut_dir.scale(-100));
                    const r2 = p1.add(cut_dir.scale(-100));
                    const r3 = p1.add(cut_dir.scale(100));

                    td.draw.convexPoly(&.{ r0, r1, r2, r3 }, 0xff000088);
                    draw_nd.convexPoly(&.{ r0, r1, r2, r3 }, 0xff000044);
                }
                { //Draw the third point plane
                    const r0 = p0.add(pnorm.scale(50));
                    const r1 = p0.add(pnorm.scale(-50));
                    const r2 = p2.add(pnorm.scale(-50));
                    const r3 = p2.add(pnorm.scale(50));
                    td.draw.convexPoly(&.{ r0, r1, r2, r3 }, 0xff88);
                    draw_nd.convexPoly(&.{ r0, r1, r2, r3 }, 0xff44);
                }
                const rm = ed.edit_state.rmouse;
                if (rm == .rising)
                    try self.tryCommitClip(ed);
            },
        }
    }

    fn tryCommitClip(self: *@This(), ed: *Editor) !void {
        const r1 = self.points[0].sub(self.points[1]);
        const r2 = self.points[0].sub(self.points[2]);
        if (r1.length() < 0.001 or r2.length() < 0.001)
            return;
        self.state = .init;
        try action.clipSelected(ed, self.points);
    }
};
