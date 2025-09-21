const std = @import("std");
const graph = @import("graph");
const Quat = graph.za.Quat;
const V3f = graph.za.Vec3;
const Vec3 = V3f;
const Mat4 = graph.za.Mat4;
const Mat3 = graph.za.Mat3;

/// This function is specific to the way angles are specified in VMF files.
pub fn extrinsicEulerAnglesToMat4(angles: Vec3) Mat4 {
    //I don't understand why the angles are mapped like this
    //see https://developer.valvesoftware.com/wiki/QAngle
    //x->y
    //y->z
    //z->x
    const fr = Mat4.fromRotation;
    const x1 = fr(angles.z(), Vec3.new(1, 0, 0));
    const y1 = fr(angles.x(), Vec3.new(0, 1, 0));
    const z1 = fr(angles.y(), Vec3.new(0, 0, 1));
    return z1.mul(y1.mul(x1));
}

pub fn extEulerToQuat(angle_deg: Vec3) Quat {
    const fr = Quat.fromAxis;
    const x1 = fr(angle_deg.z(), Vec3.new(1, 0, 0));
    const y1 = fr(angle_deg.x(), Vec3.new(0, 1, 0));
    const z1 = fr(angle_deg.y(), Vec3.new(0, 0, 1));
    return z1.mul(y1.mul(x1));
}

pub fn extrinsicEulerAnglesToMat3(angles: Vec3) Mat3 {
    //Wow this sucks.
    const fr = Mat3.fromRotation;
    const x1 = fr(angles.z(), Vec3.new(1, 0, 0));
    const y1 = fr(angles.x(), Vec3.new(0, 1, 0));
    const z1 = fr(angles.y(), Vec3.new(0, 0, 1));
    return z1.mul(y1.mul(x1));
}

//Specific to the source angles when indicating a direction
pub fn eulerToNormal(angles: Vec3) Vec3 {
    const sin = std.math.sin;
    const rad = std.math.degreesToRadians;
    const cos = std.math.cos;

    const pitch = rad(angles.x() * -1);
    const yaw = rad(angles.y() * -1 + 90);

    const xf = cos(yaw) * cos(pitch);
    const zf = sin(pitch);
    const yf = sin(yaw) * cos(pitch);
    return Vec3.new(yf, xf, zf);
}

/// Returns {ray_origin, ray_direction}
pub fn screenSpaceRay(win_dim: graph.Vec2f, screen_pos: graph.Vec2f, view: graph.za.Mat4) [2]Vec3 {
    const sw = win_dim.smul(0.5); //1920 / 2
    const pp = screen_pos.sub(sw).mul(sw.inv());
    const m_o = Vec3.new(pp.x, -pp.y, 0);
    const m_end = Vec3.new(pp.x, -pp.y, 1);
    const inv = view.inv();
    const ray_start = inv.mulByVec4(m_o.toVec4(1));
    const ray_end = inv.mulByVec4(m_end.toVec4(1));
    const ray_world = ray_start.toVec3().scale(1 / ray_start.w());
    const ray_endw = ray_end.toVec3().scale(1 / ray_end.w());

    const dir = ray_endw.sub(ray_world).norm();
    return [2]Vec3{ ray_world, dir };
}

pub fn worldToScreenSpace(view_rect: graph.Rect, view: graph.za.Mat4, world: Vec3) graph.Vec2f {
    var screen = view.mulByVec4(world.toVec4(1));
    if (screen.w() == 0) return .{ .x = 0, .y = 0 };

    const scx = (screen.x() / screen.w() + 1) / 2.0 * view_rect.w + view_rect.x;
    const scy_pre = (screen.y() / screen.w() + 1) / 2.0 * view_rect.h;

    const scy = view_rect.h - scy_pre;

    return .{ .x = scx, .y = scy };
}

//Zig port of:
//Fast Ray-Box Intersection
//by Andrew Woo
//from "Graphics Gems", Academic Press, 1990
//
//returns null or the point of intersection in slice form
pub fn doesRayIntersectBoundingBox(comptime numdim: usize, comptime ft: type, min_b: [numdim]ft, max_b: [numdim]ft, ray_origin: [numdim]ft, ray_dir: [numdim]ft) ?[numdim]ft {
    const RIGHT = 0;
    const LEFT = 1;
    const MIDDLE = 2;

    const zeros = [_]ft{0} ** numdim;
    var quadrant = zeros;
    var candidate_plane = zeros;
    var inside = true;
    var max_t = zeros;

    // Find candidate planes; this loop can be avoided if
    // rays cast all from the eye(assume perpsective view)
    for (0..numdim) |i| {
        if (ray_origin[i] < min_b[i]) {
            quadrant[i] = LEFT;
            candidate_plane[i] = min_b[i];
            inside = false;
        } else if (ray_origin[i] > max_b[i]) {
            quadrant[i] = RIGHT;
            candidate_plane[i] = max_b[i];
            inside = false;
        } else {
            quadrant[i] = MIDDLE;
        }
    }

    // Ray origin inside bounding box
    if (inside)
        return ray_origin;

    // Calculate T distances to candidate planes
    for (0..numdim) |i| {
        if (quadrant[i] != MIDDLE and ray_dir[i] != 0) {
            max_t[i] = (candidate_plane[i] - ray_origin[i]) / ray_dir[i];
        } else {
            max_t[i] = -1;
        }
    }

    // Get largest of the maxT's for final choice of intersection
    var which_plane: usize = 0;
    for (1..numdim) |i| {
        if (max_t[which_plane] < max_t[i])
            which_plane = i;
    }

    // Check final candidate actually inside box
    if (max_t[which_plane] < 0)
        return null;

    var coord = zeros;
    for (0..numdim) |i| {
        if (which_plane != i) {
            coord[i] = ray_origin[i] + max_t[which_plane] * ray_dir[i];
            if (coord[i] < min_b[i] or coord[i] > max_b[i])
                return null;
        } else {
            coord[i] = candidate_plane[i];
        }
    }

    return coord;
}

//Zig port of:
//Transforming Axis-Aligned Bounding Boxes
//by Jim Arvo
//from "Graphics Gems", Academic Press, 1990
pub fn bbRotate(rot: Mat3, translate: Vec3, box_min: Vec3, box_max: Vec3) [2]Vec3 {
    var a_min = [3]f32{ 0, 0, 0 };
    var a_max = [3]f32{ 0, 0, 0 };

    var b_min = [3]f32{ 0, 0, 0 };
    var b_max = [3]f32{ 0, 0, 0 };

    for (0..3) |i| {
        b_min[i] = translate.data[i];
        b_max[i] = translate.data[i];
        a_min[i] = box_min.data[i];
        a_max[i] = box_max.data[i];
    }

    for (0..3) |i| {
        for (0..3) |j| {
            const a = rot.data[j][i] * a_min[j];
            const b = rot.data[j][i] * a_max[j];
            if (a < b) {
                b_min[i] += a;
                b_max[i] += b;
            } else {
                b_min[i] += b;
                b_max[i] += a;
            }
        }
    }
    return .{
        Vec3.new(b_min[0], b_min[1], b_min[2]),
        Vec3.new(b_max[0], b_max[1], b_max[2]),
    };
}

pub fn meanVerticies(verts: []const Vec3) Vec3 {
    var mean = Vec3.zero();
    for (verts) |v|
        mean.add(v);
    return mean.scale(1 / @as(f32, @floatFromInt(verts.len)));
}

pub fn projectPointOntoRay(ray_origin: Vec3, ray_dir: Vec3, p: Vec3) Vec3 {
    //d is ray_dir
    //v is point - ray_orig

    //vec3 d = (C - B) / C.distance(B);
    //vec3 v = A - B;
    //double t = v.dot(d);
    //vec3 P = B + t * d;
    //return P.distance(A);

    const v = p.sub(ray_origin);
    const t = v.dot(ray_dir);

    const point_on_line = ray_origin.add(ray_dir.scale(t));
    return point_on_line;
}

pub fn trianglePlane(verts: [3]V3f) V3f {
    const a = verts[2].sub(verts[0]);
    const b = verts[1].sub(verts[0]);
    return b.cross(a).norm();
}

test "broken plane" {
    const a = V3f.new(1, 0, 0);
    const b = V3f.new(2, 0, 0);
    const c = V3f.new(3, 1, 0);

    const re = trianglePlane(.{ a, b, c });
    std.debug.print("THE RESULT IS {any}\n", .{re});
}

pub fn doesRayIntersectConvexPolygon(ray_origin: V3f, ray_dir: V3f, plane_normal: V3f, verts: []const V3f) ?V3f {
    if (verts.len == 0) return null;

    const plane_int = doesRayIntersectPlane(ray_origin, ray_dir, verts[0], plane_normal) orelse return null;
    for (1..verts.len) |i| {
        const a = verts[i - 1];
        const b = verts[i];
        const l1 = a.sub(plane_int); //legs of triangle
        const l2 = b.sub(plane_int);

        const th = std.math.atan2(l1.cross(l2).dot(plane_normal), l1.dot(l2));
        if (th < 0)
            return null;
    }
    return plane_int;
}
pub fn doesRayIntersectConvexPolygondo(ray_origin: V3f, ray_dir: V3f, plane_normal: V3f, verts: []const V3f) ?V3f {
    if (verts.len == 0) return null;

    const help = struct {
        fn rej(v: V3f, i: usize) graph.za.Vec2 {
            const V2 = graph.za.Vec2;
            return switch (i) {
                0 => V2.new(v.y(), v.z()),
                1 => V2.new(v.x(), v.z()),
                2 => V2.new(v.x(), v.y()),
                else => unreachable,
            };
        }
    };

    const plane_int = doesRayIntersectPlane(ray_origin, ray_dir, verts[0], plane_normal) orelse return null;

    var reject: usize = 0;
    var min = @abs(plane_normal.x());
    for (1..2) |i| {
        if (@abs(plane_normal.data[i]) > min) {
            min = @abs(plane_normal.data[i]);
            reject = i;
        }
    }
    const pint = help.rej(plane_int, reject);

    var cd = false;
    for (1..verts.len) |i| {
        const a = help.rej(verts[i - 1], reject);
        const b = help.rej(verts[i], reject);
        if ((a.y() > pint.y()) != (b.y() > pint.y()) and
            (pint.x() < (b.x() - a.x()) * (pint.y() - a.y()) / (b.y() - a.y()) + a.x()))
            cd = !cd;
    }

    return if (cd) plane_int else null;
}

// Translated from Wikipedia
pub fn mollerTrumboreIntersection(
    r_o: V3f,
    r_d: V3f,
    tr0: V3f,
    tr1: V3f,
    tr2: V3f,
) ?V3f {
    const EPS = 0.00001;
    const e1 = tr1.sub(tr0);
    const e2 = tr2.sub(tr0);
    const ray_cross_e2 = r_d.cross(e2);
    const det = e1.dot(ray_cross_e2);
    if (det > -EPS and det < EPS)
        return null; //piss off

    const inv_det = 1.0 / det;
    const s = r_o.sub(tr0);
    const u = inv_det * s.dot(ray_cross_e2);
    if (u < 0.0 or u > 1.0)
        return null;
    const s_cross_e1 = s.cross(e1);
    const v = inv_det * r_d.dot(s_cross_e1);
    if (v < 0.0 or u + v > 1.0)
        return null;

    const t = inv_det * e2.dot(s_cross_e1);
    if (t > EPS) {
        const inter = r_o.add(r_d.scale(t));
        return inter;
    }
    return null;
}

pub fn doesRayIntersectBBZ(ray_origin: V3f, ray_dir: V3f, min: V3f, max: V3f) ?V3f {
    const ret = doesRayIntersectBoundingBox(3, f32, min.data, max.data, ray_origin.data, ray_dir.data);
    return if (ret) |r| V3f.new(r[0], r[1], r[2]) else null;
}

pub fn doesRayIntersectPlane(ray_0: V3f, ray_norm: V3f, plane_0: V3f, plane_norm: V3f) ?V3f {
    const ln = ray_norm.dot(plane_norm);
    if (@abs(ln) < 0.0001)
        return null;

    const d = (plane_0.sub(ray_0).dot(plane_norm)) / ln;
    return ray_0.add(ray_norm.scale(d));
}

pub fn snapV3(v: Vec3, snap: f32) Vec3 {
    if (snap < 1) return v;
    // @round(v / snap)  * snap
    const sn = @as(@Vector(3, f32), @splat(snap));
    return Vec3{
        //.data = @divFloor(v.data, @as(@Vector(3, f32), @splat(snap))) * @as(@Vector(3, f32), @splat(snap)),
        .data = @round(v.data / sn) * sn,
    };
}

pub fn cubeFromBounds(p1: Vec3, p2: Vec3) struct { Vec3, Vec3 } {
    const ext = p1.sub(p2);
    return .{
        Vec3{ .data = @min(p1.data, p2.data) },
        Vec3{ .data = @abs(ext.data) },
    };
}

pub fn snap1(comp: f32, snap: f32) f32 {
    if (snap < 1) return comp;
    return @round(comp / snap) * snap;
}

// Given some plane in r3
// plane_n
// returns the point of intersection and the constrained point
pub fn planeNormalGizmo(plane_p0: Vec3, plane_n: Vec3, ray: [2]Vec3) ?struct { Vec3, Vec3 } {
    const ray_dir = ray[1];
    const v_proj = ray_dir.sub(plane_n.scale(ray_dir.dot(plane_n)));

    if (doesRayIntersectPlane(ray[0], ray[1], plane_p0, v_proj)) |inter| {
        const dist = inter.sub(plane_p0);
        const acc = dist.dot(plane_n);
        return .{ inter, plane_n.scale(acc) };
    }
    return null;
}

pub fn getBasis(norm: Vec3) [2]Vec3 {
    var n: u8 = 0;
    var dist: f32 = 0;
    const vs = [3]Vec3{ Vec3.new(1, 0, 0), Vec3.new(0, 1, 0), Vec3.new(0, 0, 1) };
    for (vs, 0..) |v, i| {
        const d = @abs(norm.dot(v));
        if (d > dist) {
            n = @intCast(i);
            dist = d;
        }
    }
    //0 -> 1 2
    //1 -> 0 2
    //2 -> 1 0
    return switch (n) {
        0 => .{ vs[2], vs[1] }, //yz
        1 => .{ vs[0], vs[2] }, //xz
        2 => .{ vs[0], vs[1] }, //xy
        else => .{ vs[0], vs[1] },
    };

    //const u: u8 = if (n == 2) 0 else 2;
    //const v: u8 = if (n == 1) 0 else 1;
    //return .{ vs[u], vs[v] };
}

//Touching does not count
pub fn doesBBOverlapExclusive(a_min: Vec3, a_max: Vec3, b_min: Vec3, b_max: Vec3) bool {
    for (0..3) |i| {
        const d = a_min.data[i] < b_max.data[i] and a_max.data[i] > b_min.data[i];
        if (!d) return false;
    }
    return true;
}

pub fn doesBBContainPoint(a_min: Vec3, a_max: Vec3, point: Vec3) bool {
    for (0..3) |i| {
        const d = a_min.data[i] < point.data[i] and a_max.data[i] > point.data[i];
        if (!d) return false;
    }
    return true;
}

//Given a point laying on a bounding box, what's the normal of the face?
pub fn pointBBIntersectionNormal(bb_min: Vec3, bb_max: Vec3, point: Vec3) ?Vec3 {
    var zero = Vec3.zero();
    for (0..3) |i| {
        if (bb_min.data[i] == point.data[i]) {
            zero.data[i] = -1;
            return zero;
        }
        if (bb_max.data[i] == point.data[i]) {
            zero.data[i] = 1;
            return zero;
        }
    }
    return null;
}

pub fn roundNormal(norm: Vec3) Vec3 {
    var n: u8 = 0;
    var dist: f32 = 0;
    const vs = [3]Vec3{ Vec3.new(1, 0, 0), Vec3.new(0, 1, 0), Vec3.new(0, 0, 1) };
    for (vs, 0..) |v, i| {
        const d = @abs(norm.dot(v));
        if (d > dist) {
            n = @intCast(i);
            dist = d;
        }
    }
    return norm.mul(vs[n]).norm();
}

pub fn cubeVerts(p0: Vec3, size: Vec3) [8]Vec3 {
    const a = p0;
    const at = a.add(Vec3.new(0, 0, size.z()));
    const sz = size;
    return [8]Vec3{
        a,
        a.add(Vec3.new(sz.x(), 0, 0)),
        a.add(Vec3.new(sz.x(), sz.y(), 0)),
        a.add(Vec3.new(0, sz.y(), 0)),
        at,
        at.add(Vec3.new(sz.x(), 0, 0)),
        at.add(Vec3.new(sz.x(), sz.y(), 0)),
        at.add(Vec3.new(0, sz.y(), 0)),
    };
}

pub fn maxComp(v: Vec3) f32 {
    return @max(v.x(), v.y(), v.z());
}
