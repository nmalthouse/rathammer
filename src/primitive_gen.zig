const std = @import("std");
const graph = @import("graph");
const _Vec = struct { x: f32, y: f32, z: f32 };
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");
const gridutil = @import("grid.zig");

//Ideally we use the same functions to generate the solids and immediate draw.
//somekind of callback
//we have a draw.convexPolygonIndexed function
//just use an arena!

pub const Primitive = struct {
    verts: std.ArrayList(Vec3),
    solids: std.ArrayList(std.ArrayList(std.ArrayList(u32))),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .verts = std.ArrayList(Vec3).init(alloc),
            .solids = std.ArrayList(std.ArrayList(std.ArrayList(u32))).init(alloc),
        };
    }

    pub fn norm(self: *const @This(), ind: []const u32) Vec3 {
        if (ind.len < 3) return Vec3.zero();

        return util3d.trianglePlane(.{
            self.verts.items[ind[0]],
            self.verts.items[ind[1]],
            self.verts.items[ind[2]],
        });
    }

    //Ptr is invalid after calling again
    pub fn newSolid(self: *@This()) !*std.ArrayList(std.ArrayList(u32)) {
        const new = std.ArrayList(std.ArrayList(u32)).init(self.verts.allocator);
        try self.solids.append(new);
        return &self.solids.items[self.solids.items.len - 1];
    }

    pub fn newFace(self: *@This()) std.ArrayList(u32) {
        return std.ArrayList(u32).init(self.verts.allocator);
    }

    pub fn toObj(self: *const @This(), wr: anytype) !void {
        for (self.verts.items) |item|
            try wr.print("v {d} {d} {d}\n", .{ item.x(), item.y(), item.z() });

        for (self.solids.items, 0..) |solid, i| {
            try wr.print("o solid{d}\n", .{i});
            for (solid.items) |face| {
                try wr.print("f", .{});
                for (face.items) |ind|
                    try wr.print(" {d}", .{ind + 1});
                try wr.print("\n", .{});
            }
        }
    }

    pub fn draw(self: *const @This(), dctx: *graph.ImmediateDrawingContext, center: Vec3, rot: graph.za.Mat3) void {
        const min_gray = 0x44;
        const max_gray = 0xdd;
        const v1 = Vec3.new(1, 0, 0);
        for (self.solids.items) |sol| {
            for (sol.items) |face| {
                const n = self.norm(face.items);
                const amt = @abs(v1.dot(n));
                const gray: u32 = @intFromFloat(@min((0xff - min_gray) * amt + min_gray, max_gray));
                const color = gray << 24 | gray << 16 | gray << 8 | 0xff;
                dctx.convexPolyIndexed(face.items, self.verts.items, color, .{
                    .offset = center,
                    .rot = rot,
                });
            }
        }
    }
};

pub fn cylinder(
    alloc: std.mem.Allocator,
    param: struct {
        a: f32,
        b: f32,
        z: f32,
        num_segment: u32 = 16,
        grid: gridutil.Snap,
    },
) !Primitive {
    var prim = Primitive.init(alloc);
    const a = param.a;
    const b = param.b;
    //const r = param.r;
    const num_segment = param.num_segment;
    const dtheta: f32 = std.math.tau / @as(f32, @floatFromInt(num_segment));
    const z = param.z;
    try prim.verts.resize(num_segment * 2);
    for (0..num_segment) |ni| {
        const fi: f32 = @floatFromInt(ni);

        const thet = fi * dtheta;
        const x_f = @cos(thet) * a;
        const y_f = @sin(thet) * b;
        const x = param.grid.swiz1(x_f, "x");
        const y = param.grid.swiz1(y_f, "y");

        prim.verts.items[ni] = Vec3.new(x, y, -z / 2);
        prim.verts.items[ni + num_segment] = Vec3.new(x, y, z / 2);
    }

    var faces = try prim.newSolid();
    {
        var face = prim.newFace();
        var opp_face = prim.newFace();
        for (0..num_segment) |nni| {
            const ni: u32 = @intCast(nni);
            try face.append(ni);
            try opp_face.append(num_segment - 1 - ni + num_segment);
        }
        try faces.append(face);
        try faces.append(opp_face);
    }

    for (0..num_segment) |nni| {
        var face = prim.newFace();
        const ni: u32 = @intCast(nni);
        const v0 = ni;
        const v1 = (ni + 1) % num_segment;
        try face.appendSlice(&.{
            v0 + num_segment,
            v1 + num_segment,
            v1,
            v0,
        });
        try faces.append(face);
    }

    return prim;
}
pub const Axis = enum {
    x,
    y,
    z,

    /// Primitives that have an orientation like a cylinder specify
    /// their shape by a 2d coordinates x,y and depth z
    pub fn Vec(self: @This(), x: f32, y: f32, z: f32) Vec3 {
        return switch (self) {
            .x => Vec3.new(z, y, x),
            .y => Vec3.new(x, z, y),
            .z => Vec3.new(x, y, z),
        };
    }

    pub fn getMat(self: @This(), swap1: bool, angle: f32) graph.za.Mat3 {
        const Mat3 = graph.za.Mat3;
        var m1 = Mat3.identity();
        const m2 = switch (self) {
            .x => Mat3.fromRotation(90, Vec3.new(0, 1, 0)),
            .y => Mat3.fromRotation(90, Vec3.new(1, 0, 0)),
            .z => Mat3.identity(),
        };
        if (swap1) {
            //m1.data[1][1] = -1;
            m1 = Mat3.fromRotation(180, Vec3.new(1, 0, 0));
        }
        const m3 = Mat3.fromRotation(angle, Vec3.new(0, 0, 1));
        return m3.mul(m2.mul(m1));
    }
};

fn sign(n: f32) f32 {
    return if (n < 0) -1 else 1;
}

pub fn arch(
    alloc: std.mem.Allocator,
    param: struct {
        a: f32, //Ellipse radius x
        b: f32, //Ellipse radius y
        thick: f32 = 16,
        num_segment: u32 = 16,
        grid: gridutil.Snap,
        z: f32,
        theta_deg: f32 = 180,
        snap_to_box: bool = false, // the Arch will be square on the outside, arch inside.
    },
) !Primitive {
    var prim = Primitive.init(alloc);
    const a = param.a - param.thick;
    const a2 = param.a;

    const b = param.b - param.thick;
    const b2 = param.b;
    const num_segment = param.num_segment;
    const z = param.grid.swiz1(param.z, "z");
    try prim.verts.resize(num_segment * 4);
    const dtheta: f32 = std.math.degreesToRadians(param.theta_deg) / @as(f32, @floatFromInt(num_segment - 1)); //Do half only
    const dtheta_deg: f32 = std.math.radiansToDegrees(dtheta);
    for (0..num_segment) |ni| {
        const fi: f32 = @floatFromInt(ni);

        const thet = fi * dtheta;
        const x1_f = @cos(thet) * a;
        const y1_f = @sin(thet) * b;

        const x2_f, const y2_f = blk: {
            const x = @cos(thet) * a2;
            const y = @sin(thet) * b2;
            if (param.snap_to_box) {
                const quad = @mod(std.math.radiansToDegrees(thet), 90);
                if (quad >= 45 and quad - dtheta_deg < 45)
                    break :blk .{ sign(x) * a2, sign(y) * b2 };
                const quadrant: i32 = @intFromFloat(@trunc(std.math.radiansToDegrees(thet) / 45.0));
                switch (quadrant) {
                    0 => break :blk .{ a2, y },
                    1 => break :blk .{ x, b2 },
                    2 => break :blk .{ x, b2 },
                    3 => break :blk .{ -a2, y },

                    4 => break :blk .{ -a2, y },
                    5 => break :blk .{ x, -b2 },
                    6 => break :blk .{ x, -b2 },
                    7 => break :blk .{ a2, y },
                    else => {},
                }
            }
            break :blk .{ x, y };
        };

        //const x2_f = @cos(thet) * a2;
        //const y2_f = @sin(thet) * b2;

        const x1 = param.grid.swiz1(x1_f, "x");
        const y1 = param.grid.swiz1(y1_f, "y");
        const x2 = param.grid.swiz1(x2_f, "x");
        const y2 = param.grid.swiz1(y2_f, "y");

        prim.verts.items[ni + num_segment * 0] = Vec3.new(x1, y1, -z / 2); //lower
        prim.verts.items[ni + num_segment * 1] = Vec3.new(x1, y1, z / 2); //lower far
        prim.verts.items[ni + num_segment * 2] = Vec3.new(x2, y2, -z / 2); //upper
        prim.verts.items[ni + num_segment * 3] = Vec3.new(x2, y2, z / 2); //upper far
    }

    for (0..num_segment - 1) |nni| {
        const ni: u32 = @intCast(nni);
        const v0 = ni; //lower
        const v0z = ni + num_segment * 1; //lower far
        const v1z = (ni + 1) + num_segment * 1; //next far
        const v1 = (ni + 1); //next

        const fv0 = ni + num_segment * 2; //upper
        const fv0z = ni + num_segment * 3; //upper far

        const fv1 = (ni + 1) + num_segment * 2; //next upper
        const fv1z = (ni + 1) + num_segment * 3; //next upper far
        try rectPrism(
            &prim,
            v1,
            v0,
            fv0,
            fv1,
            v1z,
            v0z,
            fv0z,
            fv1z,
        );
    }
    return prim;
}

//Here is a picture
// f is far
// z is behind
//
// fv1 v1
//
// fv0 v0
fn rectPrism(
    prim: *Primitive,
    v0: u32, //winding ccw
    v1: u32,
    fv1: u32,
    fv0: u32,
    v0z: u32,
    v1z: u32,
    fv1z: u32,
    fv0z: u32,
) !void {
    const faces = try prim.newSolid();
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v0, v0z, v1z, v1 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv1, fv1z, fv0z, fv0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv0, fv0z, v0z, v0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v1, v1z, fv1z, fv1 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v0, v1, fv1, fv0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv0z, fv1z, v1z, v0z });
        try faces.append(face);
    }
}

pub fn cube(alloc: std.mem.Allocator, param: struct { size: Vec3 }) !Primitive {
    var prim = Primitive.init(alloc);

    const s = param.size;
    const x = s.x();
    const y = s.y();
    const z = s.z();

    const verts = [8]Vec3{
        Vec3.new(-x, -y, z),
        Vec3.new(-x, y, z),
        Vec3.new(x, y, z),
        Vec3.new(x, -y, z),

        Vec3.new(-x, -y, -z),
        Vec3.new(-x, y, -z),
        Vec3.new(x, y, -z),
        Vec3.new(x, -y, -z),
    };
    try prim.verts.appendSlice(&verts);
    try rectPrism(&prim, 0, 1, 2, 3, 4, 5, 6, 7);

    return prim;
}

pub fn stairs(alloc: std.mem.Allocator, param: struct {
    z: f32,
    width: f32,
    height: f32,
    rise: f32,
    run: f32,
    run_pad: f32 = 0,
    rise_pad: f32 = 0,
    front_perc: f32 = -1,
    back_perc: f32 = 1,
    grid: gridutil.Snap,
}) !Primitive {
    var prim = Primitive.init(alloc);

    const stairs_x = @trunc(param.width / param.run);
    const stairs_y = @trunc(param.height / param.rise);
    const num_stairs: usize = @intFromFloat(@abs(@min(stairs_x, stairs_y)));
    const z = param.z / 2;
    const zf = param.z / -2;

    const run = param.run;
    const rise = param.rise;

    const run_a = run - param.run_pad;
    const rise_a = rise - param.rise_pad;
    const x0 = param.width / -2;
    const y0 = param.height / -2;

    var last_back: f32 = 0;
    try prim.verts.resize(num_stairs * 8);
    for (0..num_stairs) |ns| {
        const fs: f32 = @floatFromInt(ns);

        //The bottom corner of the stair
        const x = x0 + fs * run;
        const y = y0 + fs * rise;

        const yo = if (ns == 0) 0 else (y - last_back) * param.front_perc;
        const yb = yo * param.back_perc;
        last_back = y + yb;

        const i: u32 = @intCast(ns * 8);
        prim.verts.items[i + 0] = param.grid.snapV3(Vec3.new(x, y + yo, z)); //bottom left
        prim.verts.items[i + 1] = param.grid.snapV3(Vec3.new(x + run_a, y + yb, z)); //bot r
        prim.verts.items[i + 2] = param.grid.snapV3(Vec3.new(x + run_a, y + rise_a, z)); //top r
        prim.verts.items[i + 3] = param.grid.snapV3(Vec3.new(x, y + rise_a, z)); //top l

        prim.verts.items[i + 4] = param.grid.snapV3(Vec3.new(x, y + yo, zf));
        prim.verts.items[i + 5] = param.grid.snapV3(Vec3.new(x + run_a, y + yb, zf));
        prim.verts.items[i + 6] = param.grid.snapV3(Vec3.new(x + run_a, y + rise_a, zf));
        prim.verts.items[i + 7] = param.grid.snapV3(Vec3.new(x, y + rise_a, zf));

        try rectPrism(
            &prim,
            i + 0,
            i + 3,
            i + 2,
            i + 1,

            i + 4,
            i + 7,
            i + 6,
            i + 5,
        );
    }

    return prim;
}

pub fn uvSphere(alloc: std.mem.Allocator, param: struct {
    a: f32,
    b: f32,
    z: f32,
    theta_seg: u32 = 11,
    phi_seg: u32 = 11,
    phi: f32 = 360,
    grid: gridutil.Snap,
    thick: f32 = 16,
}) !Primitive {
    var prim = Primitive.init(alloc);

    const dtheta: f32 = std.math.pi / @as(f32, @floatFromInt(param.theta_seg)) / 2;
    const phi_offset: usize = if (param.phi >= 360) 0 else 1;
    const dphi: f32 = std.math.degreesToRadians(param.phi) / @as(f32, @floatFromInt(param.phi_seg - phi_offset));

    const a = param.a - param.thick;
    const a2 = param.a;

    const b = param.b - param.thick;
    const b2 = param.b;

    const h = param.z - param.thick;
    const h2 = param.z;

    const num: u32 = @intCast(param.theta_seg * param.phi_seg);
    try prim.verts.resize(num * 2);
    for (0..param.theta_seg) |dth| {
        const th: f32 = @as(f32, @floatFromInt(dth)) * dtheta;
        for (0..param.phi_seg) |dpi| {
            const phi: f32 = @as(f32, @floatFromInt(dpi)) * dphi;
            const x = @sin(th) * @cos(phi);
            const y = @sin(th) * @sin(phi);
            const z = @cos(th);
            const gi = dth * param.theta_seg + dpi;
            prim.verts.items[gi] = param.grid.snapV3(Vec3.new(x, y, z).mul(Vec3.new(a, b, h)));
            prim.verts.items[gi + num] = param.grid.snapV3(Vec3.new(x, y, z).mul(Vec3.new(a2, b2, h2)));
        }
    }

    //var faces = try prim.newSolid();
    for (0..param.theta_seg - 1) |ddth| {
        const dth: u32 = @intCast(ddth);
        for (0..param.phi_seg - phi_offset) |ddpi| {
            const dpi: u32 = @as(u32, @intCast(ddpi));
            const v0 = (dpi) % param.phi_seg;
            const v1 = (dpi + 1) % param.phi_seg;
            const v2 = (v1 + param.phi_seg);
            const v3 = (v0 + param.phi_seg);
            const off = dth * param.theta_seg;
            //+ dth * param.theta_seg;

            try rectPrism(
                &prim,
                v3 + off,
                v2 + off,
                v1 + off,
                v0 + off,

                v3 + off + num,
                v2 + off + num,
                v1 + off + num,
                v0 + off + num,
            );
            //{
            //    var face = prim.newFace();
            //    try face.appendSlice(&.{
            //        v0 + off, v1 + off, v2 + off, v3 + off,
            //    });

            //    try faces.append(face);
            //}
            //{
            //    var face = prim.newFace();
            //    try face.appendSlice(&.{
            //        v3 + off + num,
            //        v2 + off + num,
            //        v1 + off + num,
            //        v0 + off + num
            //    });

            //    try faces.append(face);
            //}
        }
    }

    return prim;
}
