const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");
const BtnState = graph.SDL.ButtonState;
const Editor = @import("editor.zig").Context;

pub const Gizmo = struct {
    start: Vec3 = Vec3.zero(),
    selected_axis: enum {
        x,
        y,
        z,
        xy,
        xz,
        yz,
        none, //Must be last element

        pub fn index(self: @This()) ?usize {
            if (self == .none)
                return null;
            return @intFromEnum(self);
        }

        pub fn setFromIndex(self: *@This(), index_: usize) void {
            const info = @typeInfo(@This());
            const count = info.@"enum".fields.len;
            if (index_ > count - 1)
                return; //Silently fail
            self.* = @enumFromInt(index_);
        }

        /// Return the normal of the plane which the mouse raycast's should be checked against for a given axis.
        /// The plane passes through the gizmo origin.
        pub fn getPlaneNorm(self: @This(), norm: Vec3) Vec3 {
            var n = norm;
            switch (self) {
                else => {},
                .x => n.data[0] = 0,
                .y => n.data[1] = 0,
                .z => n.data[2] = 0,
                .xy => return Vec3.new(0, 0, 1),
                .xz => return Vec3.new(0, 1, 0),
                .yz => return Vec3.new(1, 0, 0),
            }
            return n.norm();
        }

        /// Given a point on the plane returned from getPlaneNorm, return the distance that should be considered.
        pub fn getDistance(self: @This(), dist: Vec3) Vec3 {
            const V = Vec3.new;
            return switch (self) {
                else => dist,
                .x => V(dist.x(), 0, 0),
                .y => V(0, dist.y(), 0),
                .z => V(0, 0, dist.z()),

                .xy => V(dist.x(), dist.y(), 0),
                .xz => V(dist.x(), 0, dist.z()),
                .yz => V(0, dist.y(), dist.z()),
            };
        }
    } = .none,

    //TODO make this work with a rotated gizmo
    /// Returns true if the gizmo is being dragged
    pub fn handle(
        self: *@This(),
        orig: Vec3,
        orig_mut: *Vec3,
        camera_pos: Vec3,
        lmouse: BtnState,
        draw: *graph.ImmediateDrawingContext,
        screen_area: graph.Rect,
        view: graph.za.Mat4,
        editor: *Editor,
    ) BtnState {
        //const sa = self.edit_state.selected_axis;
        const gizmo_size = orig.distance(camera_pos) / 64 * 20;
        const oz = gizmo_size / 20;
        const tr = oz * 3;
        const pz = gizmo_size / 2;
        const cube_orig = [_]Vec3{
            orig.add(Vec3.new(oz, 0, 0)), //xyz
            orig.add(Vec3.new(0, oz, 0)),
            orig.add(Vec3.new(0, 0, oz)),
            orig.add(Vec3.new(tr, tr, 0)), //xy
            orig.add(Vec3.new(tr, 0, tr)), //xz
            orig.add(Vec3.new(0, tr, tr)), //yz
        };
        const cubes = [cube_orig.len]Vec3{
            Vec3.new(gizmo_size, oz, oz),
            Vec3.new(oz, gizmo_size, oz),
            Vec3.new(oz, oz, gizmo_size),
            Vec3.new(pz, pz, oz / 2), //xy
            Vec3.new(pz, oz / 2, pz), //xz
            Vec3.new(oz / 2, pz, pz), //xz
        };
        const al: u32 = 0xaa;
        const colors = [cube_orig.len]u32{
            0xff000000 + al,
            0xff0000 + al,
            0xff00 + al,
            0xffff0000 + al,
            0xff00ff00 + al,
            0xffff00 + al,
        };
        const ind = self.selected_axis.index() orelse 100000;
        if (lmouse != .high) {
            for (cube_orig, 0..) |co, i| {
                const color = if (i == ind) 0xffff_ff88 else colors[i];
                draw.cube(co, cubes[i], color);
            }
        }

        var min_dist: f32 = std.math.floatMax(f32);
        switch (lmouse) {
            .rising => {
                var caught_one = false;
                const rc = editor.camRay(screen_area, view);
                for (cubes, 0..) |cu, ci| {
                    const co = cube_orig[ci];
                    if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(cu))) |inter| {
                        const d = inter.distance(camera_pos);
                        if (d < min_dist) {
                            caught_one = true;
                            min_dist = d;
                            draw.point3D(inter, 0x7f_ff_ff_ff, 4);
                            self.selected_axis.setFromIndex(ci);
                            //Now that we intersect, e
                            self.start = util3d.doesRayIntersectPlane(
                                rc[0],
                                rc[1],
                                orig,
                                self.selected_axis.getPlaneNorm(camera_pos.sub(orig)),
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
                if (self.selected_axis == .none)
                    return .low;
                const rc = editor.camRay(screen_area, view);
                if (util3d.doesRayIntersectPlane(
                    rc[0],
                    rc[1],
                    orig,
                    self.selected_axis.getPlaneNorm(camera_pos.sub(orig)),
                )) |end| {
                    const diff = end.sub(self.start);
                    orig_mut.* = orig.add(self.selected_axis.getDistance(diff));
                    return .high; //The gizmo is active
                }
            },
            .low => self.selected_axis = .none,
            .falling => return .falling,
        }
        return .low;
    }
};
