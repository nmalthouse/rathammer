const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const limits = @import("limits.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const util3d = @import("util_3d.zig");
//Get on the grid

pub const Snap = struct {
    s: Vec3,

    min: Vec3 = Vec3.set(limits.min_grid),
    max: Vec3 = Vec3.set(limits.max_grid),

    pub fn double(self: *@This()) void {
        self.s = self.s.scale(2);
        self.s.data = std.math.clamp(self.s.data, self.min.data, self.max.data);
    }

    pub fn zero() @This() {
        return .{ .s = Vec3.zero() };
    }

    pub fn half(self: *@This()) void {
        self.s = self.s.scale(0.5);
        self.s.data = std.math.clamp(self.s.data, self.min.data, self.max.data);
    }

    pub fn setAll(self: *@This(), snap: f32) void {
        self.s = Vec3.set(snap);
    }

    pub fn snapV3(self: *const @This(), v: Vec3) Vec3 {
        return Vec3.new(
            snap1(v.x(), self.s.x()),
            snap1(v.y(), self.s.y()),
            snap1(v.z(), self.s.z()),
        );
    }

    pub fn isOne(self: *const @This()) bool {
        return self.s.x() == self.s.y() and self.s.y() == self.s.z();
    }

    pub fn countV3(self: *const @This(), v: Vec3) Vec3 {
        return Vec3.new(
            count1(v.x(), self.s.x()),
            count1(v.y(), self.s.y()),
            count1(v.z(), self.s.z()),
        );
    }

    pub fn swiz1(self: *const @This(), v: f32, comptime comp: []const u8) f32 {
        inline for (comp) |cc| {
            switch (cc) {
                'x' => return snap1(v, self.s.x()),
                'y' => return snap1(v, self.s.y()),
                'z' => return snap1(v, self.s.z()),
                else => @compileError("not a component"),
            }
        }
    }

    pub fn swiz(self: *const @This(), v: Vec3, comptime comp: []const u8) Vec3 {
        var ret = v;
        inline for (comp) |cc| {
            switch (cc) {
                'x' => ret.xMut().* = snap1(ret.x(), self.s.x()),
                'y' => ret.yMut().* = snap1(ret.y(), self.s.y()),
                'z' => ret.zMut().* = snap1(ret.z(), self.s.z()),
                else => @compileError("not a component"),
            }
        }
        return ret;
    }

    pub fn snap1(value: f32, snap: f32) f32 {
        if (snap < limits.min_snap) return value;
        return @round(value / snap) * snap;
    }

    fn count1(value: f32, snap: f32) f32 {
        if (snap < 1) return 0;
        return @round(value / snap);
    }
};

fn drawGridAxis1(del_x: f32, count: f32, width: f32, start_p: Vec3, comptime axis: usize, comptime plane_axis: usize, draw: *DrawCtx, count_pad: usize) void {
    if (axis > 2 or plane_axis > 2 or plane_axis == axis) @compileError("that is not right dude");
    const distx = del_x * @as(f32, if (count > 0) 1 else -1);

    const cc: usize = @intFromFloat(@abs(count));
    const rc: usize = cc + if (cc > 0) count_pad else 0;
    for (0..rc) |xi| {
        const xf: f32 = @floatFromInt(xi);
        {
            var start = Vec3.zero();
            start.data[axis] = xf * distx;
            start.data[plane_axis] = -width / 2;
            var end = start;
            end.data[plane_axis] = width / 2;

            draw.line3D(start.add(start_p), end.add(start_p), 0xffffffff, 2);
        }
    }
}

pub fn drawGridAxis(start_p: Vec3, counts: Vec3, d: *DrawCtx, snap: Snap, widths: Vec3) void {
    const start_snap = snap.snapV3(start_p);

    drawGridAxis1(snap.s.x(), counts.x(), widths.x(), start_snap, 0, 1, d, 2);
    drawGridAxis1(snap.s.y(), counts.y(), widths.y(), start_snap, 1, 0, d, 2);
    drawGridAxis1(snap.s.z(), counts.z(), widths.z(), start_snap, 2, 1, d, 2);
}

/// Draw a grid with a normal 'up'
/// Non cardinal 'up, will result in an incorrect grid because we snap on cardinal
/// TODO make it use correct snap values for each axis
pub fn drawGrid3d(inter: Vec3, plane_z: f32, d: *DrawCtx, snap: Snap, count: usize, up: Vec3) void {
    //const cpos = inter;
    const cpos = snap.snapV3(inter);
    const nline: f32 = @floatFromInt(count);

    const def_up = Vec3.new(0, 0, 1);
    const quat = graph.za.Quat.fromAxis(def_up.getAngle(up), def_up.cross(up));

    const iline2: f32 = @floatFromInt(count / 2);

    const sx = snap.s.x();
    const sy = snap.s.y();
    const othx = @trunc(nline * sx / 2);
    const othy = @trunc(nline * sy / 2);

    const pos = Vec3.new(cpos.x(), cpos.y(), plane_z);
    for (0..count) |n| {
        const fnn: f32 = @floatFromInt(n);
        {
            const start = Vec3.new((fnn - iline2) * sx, -othy, 0);
            const end = start.add(Vec3.new(0, 2 * othy, 0));

            d.line3D(quat.rotateVec(start).add(pos), quat.rotateVec(end).add(pos), 0xffffffff, 2);
        }
        const start = Vec3.new(-othx, (fnn - iline2) * sy, 0);
        const end = start.add(Vec3.new(2 * othx, 0, 0));
        d.line3D(quat.rotateVec(start).add(pos), quat.rotateVec(end).add(pos), 0xffffffff, 2);
    }
    //d.point3D(cpos, 0xff0000ee);
}

//pub fn drawGridAxis2D()

pub fn drawGridZ(inter: Vec3, plane_z: f32, d: *DrawCtx, snap: Snap, count: usize) void {
    //const cpos = inter;
    const cpos = snap.snapV3(inter);
    const nline: f32 = @floatFromInt(count);

    const iline2: f32 = @floatFromInt(count / 2);

    const sx = snap.s.x();
    const sy = snap.s.y();
    const othx = @trunc(nline * sx / 2);
    const othy = @trunc(nline * sy / 2);

    const pos = Vec3.new(cpos.x(), cpos.y(), plane_z);
    for (0..count) |n| {
        const fnn: f32 = @floatFromInt(n);
        {
            const start = Vec3.new((fnn - iline2) * sx, -othy, 0);
            const end = start.add(Vec3.new(0, 2 * othy, 0));

            d.line3D(start.add(pos), end.add(pos), 0xffffffff, 2);
        }
        const start = Vec3.new(-othx, (fnn - iline2) * sy, 0);
        const end = start.add(Vec3.new(2 * othx, 0, 0));
        d.line3D(start.add(pos), end.add(pos), 0xffffffff, 2);
    }
    //d.point3D(cpos, 0xff0000ee);
}

pub const Grid2DParam = struct {
    color: u32,
};
pub fn drawGrid2DAxis(comptime axis: u8, area_: graph.Rect, max_lines: f32, snap: f32, d: *DrawCtx, param: Grid2DParam) void {
    if (max_lines <= 0) return;
    if (axis != 'x' and axis != 'y') @compileError("invalid axis");

    const area = if (axis == 'y') area_.swapAxis() else area_;

    var gx_start = Snap.snap1(area.x, snap);
    var count = @ceil(area.w / snap);
    var wi = snap;

    if (count > max_lines) {
        const log2 = std.math.log2;
        const snap_exp = @ceil(log2(area.w / (snap * max_lines)));
        count = max_lines;
        wi = snap * std.math.pow(f32, 2, snap_exp);
        gx_start = Snap.snap1(area.x, wi);
    }

    for (0..@intFromFloat(count)) |ci| {
        const fi: f32 = @floatFromInt(ci);
        const start = graph.Vec2f{ .x = gx_start + fi * wi, .y = area.y };
        const end = graph.Vec2f{ .x = gx_start + fi * wi, .y = area.y + area.h };
        if (axis == 'y') {
            d.line(start.swapAxis(), end.swapAxis(), param.color, 1);
        } else {
            d.line(start, end, param.color, 1);
        }
    }
}

//pub fn drawGrid2D()void{ }
