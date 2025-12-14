const std = @import("std");
const graph = @import("graph");
const BtnState = graph.SDL.ButtonState;
const Vec3 = graph.za.Vec3;
const util3d = graph.util_3d;
const Editor = @import("editor.zig").Context;
const grid = @import("grid.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const Font = graph.FontUtil.PublicFontInterface;
const limits = @import("limits.zig");
const FMT1D = "{d}";
//const FMT1D = "{d:.4}";
const FMT3D = FMT1D ++ " " ++ FMT1D ++ " " ++ FMT1D;

fn roundForDrawing(v: Vec3) Vec3 {
    var ret = v;
    const vv: [3]f32 = v.data;
    for (vv, 0..) |d, i| {
        const ad = @round(d);
        if (@abs(ad - d) < limits.delta_drawn)
            ret.data[i] = ad;
    }
    return ret;
}

pub fn drawDistance(start: Vec3, delta: Vec3, draw: *DrawCtx, tp: DrawCtx.TextParam, screen_area: graph.Rect, view: graph.za.Mat4) void {
    var tt = tp;
    tt.background_rect = 0xaa;
    const ss = (util3d.worldToScreenSpace(screen_area, view, start.add(delta)) orelse return).add(
        .{ .x = 0, .y = 0 },
    );

    const del = roundForDrawing(delta);
    draw.textFmt(ss, FMT3D, .{ del.x(), del.y(), del.z() }, tt);
}

pub fn drawPoint(point: Vec3, draw: *DrawCtx, tp: DrawCtx.TextParam, screen_area: graph.Rect, view: graph.za.Mat4) void {
    var tt = tp;
    tt.background_rect = 0xaa;
    const ss = (util3d.worldToScreenSpace(screen_area, view, point) orelse return).add(
        .{ .x = 0, .y = 0 },
    );

    const num = roundForDrawing(point);
    draw.textFmt(ss, FMT3D, .{ num.x(), num.y(), num.z() }, tt);
}

pub fn drawText3D(pos: Vec3, draw: *DrawCtx, tp: DrawCtx.TextParam, screen_area: graph.Rect, view: graph.za.Mat4, comptime fmt: []const u8, args: anytype) void {
    var tt = tp;
    tt.background_rect = 0xaa;
    const ss = (util3d.worldToScreenSpace(screen_area, view, pos) orelse return).add(
        .{ .x = 0, .y = 0 },
    );

    draw.textFmt(ss, fmt, args, tt);
}

pub fn drawBBDimensions(min: Vec3, max: Vec3, draw: *DrawCtx, t: DrawCtx.TextParam, screen_area: graph.Rect, view: graph.za.Mat4) void {
    const cc = util3d.cubeFromBounds(min, max);
    const ex = cc[1];
    const hx = ex.scale(0.5);

    const num = roundForDrawing(ex);
    {
        const pos = cc[0].add(Vec3.new(hx.x(), 0, hx.z()));
        if (util3d.worldToScreenSpace(screen_area, view, pos)) |ss| {
            draw.textFmt(ss, FMT1D, .{num.x()}, t);
            const start = Vec3.new(cc[0].x(), cc[0].y(), cc[0].z() + cc[1].z() / 2);
            draw.line3D(start, start.add(Vec3.new(cc[1].x(), 0, 0)), 0xff, 1);
        }
    }
    {
        const pos = cc[0].add(Vec3.new(0, hx.y(), hx.z()));
        if (util3d.worldToScreenSpace(screen_area, view, pos)) |ss| {
            draw.textFmt(ss, FMT1D, .{num.y()}, t);
            const start = cc[0].add(Vec3.new(0, 0, hx.z()));
            draw.line3D(start, start.add(Vec3.new(0, ex.y(), 0)), 0xff, 1);
        }
    }
    {
        const pos = cc[0].add(hx);
        if (util3d.worldToScreenSpace(screen_area, view, pos)) |ss| {
            draw.textFmt(ss, FMT1D, .{num.z()}, t);
            const start = cc[0].add(Vec3.new(hx.x(), hx.y(), 0));
            draw.line3D(start, start.add(Vec3.new(0, 0, ex.z())), 0xff, 1);
        }
    }
}

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

                        draw.line3D(self.start_point, self.start_point.add(p), 0x00ffffff, 2);
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
                    draw.point3D(cc, 0xff0000ee, 4);

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

pub const FastMove = struct {
    pub fn start() !void {}
};
