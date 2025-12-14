const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const util3d = graph.util_3d;
const BtnState = graph.SDL.ButtonState;

///This one does rotations
pub const Gizmo = struct {
    const Self = @This();
    selected_index: ?usize = null,

    start: Vec3 = Vec3.zero(),

    pub fn reset(self: *Self) void {
        self.selected_index = null;
    }

    pub fn drawGizmo(
        self: *Self,
        orig: Vec3,
        angle_deg: *Vec3,
        camera_pos: Vec3,
        lmouse: BtnState,
        draw: *graph.ImmediateDrawingContext,
        rc: [2]Vec3,
        //screen_area: graph.Vec2f,
        //view: graph.za.Mat4,
        //mouse_pos: graph.Vec2f,
    ) BtnState {
        const CIRCLE_DIST_SCALE = 3;
        const gizmo_size = orig.distance(camera_pos) / 64 * 10;
        const oz = gizmo_size / 20;
        //const tr = oz * 3;
        const pz = gizmo_size / 2;
        const cube_orig = [_]Vec3{
            orig.add(Vec3.new(-pz, -pz, -oz / 2)), //xy plane(rot axis z)
            orig.add(Vec3.new(-pz, -oz / 2, -pz)),
            orig.add(Vec3.new(-oz / 2, -pz, -pz)),
        };
        const cube_ext = [cube_orig.len]Vec3{
            Vec3.new(pz * 2, pz * 2, oz),
            Vec3.new(pz * 2, oz, pz * 2),
            Vec3.new(oz, pz * 2, pz * 2),
        };
        const normals = [cube_orig.len]Vec3{ //Define the normals we check
            Vec3.new(0, 0, 1),
            Vec3.new(0, 1, 0),
            Vec3.new(1, 0, 0),
        };
        const al = 0xaa;
        const colors = [cube_orig.len]u32{
            0xff0000_00 + al,
            0xff00_00 + al,
            0xff_00 + al,
        };
        const angle_index = [cube_orig.len]u32{ 1, 0, 2 };
        const ind = self.selected_index orelse 100000;

        var min_dist: f32 = std.math.floatMax(f32);
        switch (lmouse) {
            .rising => {
                var caught_one = false;
                for (cube_orig, 0..) |co, ci| {
                    const ce = cube_ext[ci];
                    if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(ce))) |inter| {
                        const d = inter.distance(camera_pos);
                        if (d < min_dist) {
                            caught_one = true;
                            min_dist = d;
                            draw.point3D(inter, 0x7f_ff_ff_ff, 4);
                            self.selected_index = ci;
                            //Now that we intersect, e
                            self.start = util3d.doesRayIntersectPlane(
                                rc[0],
                                rc[1],
                                orig,
                                normals[ci],
                                //self.selected_axis.getPlaneNorm(camera_pos.sub(orig)),
                                //self.edit_state.selected_plane_norm,
                            ) orelse Vec3.zero(); //This should never be null
                        }
                    }
                }
                if (caught_one)
                    return .rising;
                return .low;
            },
            .high => {
                const si = self.selected_index orelse return .low;
                //const rc = util3d.screenSpaceRay(screen_area, mouse_pos, view);
                if (util3d.doesRayIntersectPlane(
                    rc[0],
                    rc[1],
                    orig,
                    normals[si],
                )) |end| {
                    const V2 = graph.za.Vec2;
                    //const acc = dist_n.dot(normals[si]);
                    //const dist = normals.

                    //const diff = end.sub(self.start);

                    //The basis of our projection onto the plane
                    const r1 = self.start.sub(orig);
                    const r2 = end.sub(orig);

                    const x1 = r1.norm();
                    const y1 = normals[si].cross(r1).norm();

                    const rstart = V2.new(x1.dot(r1), y1.dot(r1)).scale(CIRCLE_DIST_SCALE);
                    const rend = V2.new(x1.dot(r2), y1.dot(r2)).scale(CIRCLE_DIST_SCALE);
                    const SEGMENT_PER_180 = 30;
                    //angle = atan2(vector2.y, vector2.x) - atan2(vector1.y, vector1.x);
                    const theta_free = std.math.atan2(rend.y(), rend.x()) - std.math.atan2(rstart.y(), rstart.x());
                    const theta = std.math.radiansToDegrees(theta_free);
                    angle_deg.data[angle_index[si]] += theta;
                    const n_segment_f: f32 = @trunc((@abs(theta) / 180) * SEGMENT_PER_180) + 1;
                    const dtheta = theta / n_segment_f;
                    const n_segment: u32 = @intFromFloat(n_segment_f);
                    var last_vert = x1.scale(rstart.x()).add(y1.scale(rstart.y())).add(orig);
                    draw.line3D(last_vert, orig, 0x0000ffff, 2);
                    for (0..n_segment) |n| {
                        const fnn: f32 = @floatFromInt(n + 1);
                        const th = std.math.degreesToRadians(dtheta * fnn);
                        const vert_2d = V2.new(std.math.cos(th) * rstart.x(), rstart.y() + std.math.sin(th) * rstart.x());

                        const vert_3d = x1.scale(vert_2d.x()).add(y1.scale(vert_2d.y()));
                        const vv = vert_3d.add(orig);
                        draw.line3D(last_vert, vv, 0xffff00ff, 2);
                        last_vert = vv;
                    }
                    draw.line3D(last_vert, orig, 0x0000ffff, 2);

                    return .high; //The gizmo is active
                }
            },
            .low => {
                for (cube_orig, 0..) |ori, i| {
                    const color = if (i == ind) 0xffff_ffff else colors[i];
                    draw.cube(ori, cube_ext[i], color);
                }
                self.selected_index = null;
            },
            .falling => return .falling,
        }
        return .low;
    }
};
