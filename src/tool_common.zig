const std = @import("std");
const graph = @import("graph");
const BtnState = graph.SDL.ButtonState;
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");
const Editor = @import("editor.zig").Context;
const grid = @import("grid.zig");
const DrawCtx = graph.ImmediateDrawingContext;

pub const AABBGizmo = struct {
    start_point: Vec3 = Vec3.zero(),
    start_norm: Vec3 = Vec3.zero(),
    active: bool = false,

    pub fn aabbGizmo(self: *@This(), min_: *Vec3, max_: *Vec3, rc: [2]Vec3, btn: BtnState, snap: grid.Snap, draw: *graph.ImmediateDrawingContext) [2]Vec3 {
        const cube1 = util3d.cubeFromBounds(min_.*, max_.*);
        const min = cube1[0];
        const max = cube1[0].add(cube1[1]);
        var ret = [2]Vec3{ min, max };
        switch (btn) {
            .low => {
                self.active = false;
            },
            .rising => {
                if (util3d.doesRayIntersectBBZ(rc[0], rc[1], min, max)) |inter| {
                    self.start_point = inter;
                    if (util3d.pointBBIntersectionNormal(min, max, inter)) |norm| {
                        self.start_norm = norm;
                        self.active = true;
                    }
                }
            },
            .high, .falling => {
                if (self.active) {
                    if (util3d.planeNormalGizmo(self.start_point, self.start_norm, rc)) |inter| {
                        const sign = self.start_norm.dot(Vec3.set(1));
                        _, const p_unsnapped = inter;
                        const p = snap.snapV3(p_unsnapped);
                        ret[0] = if (sign > 0) min else min.add(p);
                        ret[1] = if (sign < 0) max else max.add(p);

                        draw.line3D(self.start_point, self.start_point.add(p), 0x00ffffff);
                    }
                    if (btn == .falling) {
                        min_.* = ret[0];
                        max_.* = ret[1];
                    }
                }
                if (btn == .falling)
                    self.active = false;
            },
        }
        const cc = util3d.cubeFromBounds(ret[0], ret[1]);
        draw.cubeFrame(cc[0], cc[1], 0xff0000ff);
        return ret;
    }
};

pub const DrawBoundingVolume = struct {
    start: Vec3 = Vec3.zero(),
    end: Vec3 = Vec3.zero(),
    snap_z: bool = false,
    plane_z: f32 = 0,
    min_volume: f32 = 1,

    state: enum { start, planar, finished } = .start,

    custom_height: f32 = 1,
    height_setting: enum {
        grid,
        custom,
        min_w,
        max_w,
    } = .grid,

    pub fn reset(self: *@This()) void {
        self.state = .start;
    }

    fn getHeight(self: *const @This(), ed: *Editor, p2: Vec3) f32 {
        const dim = self.start.sub(p2);
        return switch (self.height_setting) {
            .grid => ed.grid.s.z(),
            .custom => self.custom_height,
            .min_w => @min(@abs(dim.x()), @abs(dim.y())),
            .max_w => @max(@abs(dim.x()), @abs(dim.y())),
        };
    }

    pub fn run(
        tool: *@This(),
        keys: struct { z_up: bool, z_down: bool, z_raycast: bool },
        ed: *Editor,
        area: graph.Rect,
        view: graph.za.Mat4,
        draw: *DrawCtx,
    ) void {
        const ray = ed.camRay(area, view);
        switch (tool.state) {
            .start => {
                if (keys.z_up)
                    tool.plane_z += ed.grid.s.z();
                if (keys.z_down)
                    tool.plane_z -= ed.grid.s.z();
                if (keys.z_raycast) {
                    const pot = ed.screenRay(area, view);
                    if (pot.len > 0) {
                        const inter = pot[0].point;
                        const cc = ed.grid.snapV3(inter);
                        grid.drawGridZ(inter, cc.z(), draw, ed.grid, 11);
                        if (ed.edit_state.lmouse == .rising) {
                            tool.plane_z = cc.z();
                        }
                    }
                } else if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    //user has a xy plane
                    //can reposition using keys or doing a raycast into world
                    grid.drawGridZ(inter, tool.plane_z, draw, ed.grid, 11);

                    const cc = if (tool.snap_z) ed.grid.snapV3(inter) else ed.grid.swiz(inter, "xy");
                    draw.point3D(cc, 0xff0000ee);

                    if (ed.edit_state.lmouse == .rising) {
                        tool.start = cc;
                        tool.state = .planar;
                    }
                }
            },
            .planar => {
                if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    grid.drawGridZ(inter, tool.plane_z, draw, ed.grid, 11);
                    const in = if (tool.snap_z) ed.grid.snapV3(inter) else ed.grid.swiz(inter, "xy");
                    const height = tool.getHeight(ed, in);
                    const cc = util3d.cubeFromBounds(tool.start, in.add(Vec3.new(0, 0, height)));
                    draw.cube(cc[0], cc[1], 0xffffff88);
                    const ext = cc[1];
                    const volume = ext.x() * ext.y() * ext.z();

                    if (ed.edit_state.lmouse == .rising and volume > tool.min_volume) {
                        tool.end = in;
                        tool.end.data[2] += height;
                        tool.state = .finished;
                        //tool.bb_gizmo.active = false;
                        //Put it into the
                    }
                }
            },
            .finished => {
                //try tool.finishPrimitive(self, td);
            },
        }
    }
};
