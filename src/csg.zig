const std = @import("std");
const graph = @import("graph");
const meshutil = graph.meshutil;
const Mesh = meshutil.Mesh;
// The csg algorithm requires the precison of 64 bit floats
// Once the meshes are generated we can convert to f32
const Vec3_64 = graph.za.Vec3_f64;
const Vec3_32 = graph.za.Vec3;
const Vec2 = graph.za.Vec2;
const vmf = @import("vmf.zig");
const Side = vmf.Side;
const editor = @import("editor.zig");
const ecs = @import("ecs.zig");
const limits = @import("limits.zig");
const StringStorage = @import("string.zig").StringStorage;
// This is a direct implementation of the quake method outlined in:
// https://github.com/jakgor471/vmf-files_webgl
//
// A fantastic pdf

pub var gen_time: u64 = 0;

/// This context exists as the csg generation requires lots of shortlived allocations.
/// Most of the functions will clobber whatever is in their corresponding array list and return the slice.
/// Thus, most functions are not thread safe
pub const Context = struct {
    const Self = @This();
    const INIT_CAPACITY = 20;
    const EPSILON: f64 = limits.csg_epsilon;
    const SideClass = enum {
        back,
        front,
        on,
    };
    alloc: std.mem.Allocator,
    base_winding: [4]Vec3_64,
    winding_a: std.ArrayList(Vec3_64),
    winding_b: std.ArrayList(Vec3_64),

    disp_winding: std.ArrayList(Vec3_32),

    triangulate_index: std.ArrayList(u32),
    uvs: std.ArrayList(Vec2),

    clip_winding_sides: std.ArrayList(SideClass),
    clip_winding_dists: std.ArrayList(f64),

    vecmap: VecMap,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return .{
            .alloc = alloc,
            .base_winding = undefined,
            .winding_a = try std.ArrayList(Vec3_64).initCapacity(alloc, INIT_CAPACITY),
            .winding_b = try std.ArrayList(Vec3_64).initCapacity(alloc, INIT_CAPACITY),
            .vecmap = VecMap.init(alloc),

            .triangulate_index = try std.ArrayList(u32).initCapacity(alloc, INIT_CAPACITY),
            .uvs = try std.ArrayList(Vec2).initCapacity(alloc, INIT_CAPACITY),
            .clip_winding_sides = try std.ArrayList(SideClass).initCapacity(alloc, INIT_CAPACITY),
            .clip_winding_dists = try std.ArrayList(f64).initCapacity(alloc, INIT_CAPACITY),
            .disp_winding = try std.ArrayList(Vec3_32).initCapacity(alloc, INIT_CAPACITY),
        };
    }

    pub fn deinit(self: *Self) void {
        self.disp_winding.deinit();
        self.winding_a.deinit();
        self.vecmap.deinit();
        self.winding_b.deinit();
        self.triangulate_index.deinit();
        self.uvs.deinit();
        self.clip_winding_sides.deinit();
        self.clip_winding_dists.deinit();
    }

    pub fn genMesh2(self: *Self, sides: []const Side, alloc: std.mem.Allocator, strstore: *StringStorage, edit: *editor.Context) !ecs.Solid {
        const MAPSIZE = std.math.maxInt(i32);
        var timer = try std.time.Timer.start();
        var ret = ecs.Solid.init(alloc);
        try ret.sides.resize(ret._alloc, sides.len);

        self.vecmap.clear();

        for (sides, 0..) |side, si| {
            const plane = Plane.fromTri(side.plane.tri);

            self.winding_a.clearRetainingCapacity();
            var wind_a = &self.winding_a;
            try wind_a.appendSlice(try self.baseWinding(plane, @floatFromInt(MAPSIZE / 2)));

            var wind_b = &self.winding_b;

            for (sides) |subside| {
                const pl2 = Plane.fromTri(subside.plane.tri);
                if (plane.norm.dot(pl2.norm) > 1 - EPSILON)
                    continue;

                try self.clipWinding(wind_a.*, wind_b, pl2);
                const temp = wind_a;
                wind_a = wind_b;
                wind_b = temp;
            }

            if (wind_a.items.len < 3)
                continue;

            for (wind_a.items) |*item| {
                item.* = roundVec(item.*);
            }
            //const ret = map.getPtr(side.material) orelse continue;

            const tex = try edit.loadTextureFromVpk(side.material);
            ret.sides.items[si] = .{
                .index = std.ArrayListUnmanaged(u32){},
                .material = try strstore.store(side.material),
                .tex_id = tex.res_id,
                .lightmapscale = side.lightmapscale,
                .smoothing_groups = side.smoothing_groups,
                .u = .{
                    .axis = side.uaxis.axis,
                    .trans = @floatCast(side.uaxis.translation),
                    .scale = @floatCast(side.uaxis.scale),
                },
                .v = .{
                    .axis = side.vaxis.axis,
                    .trans = @floatCast(side.vaxis.translation),
                    .scale = @floatCast(side.vaxis.scale),
                },
            };
            //const indexs = try self.triangulate(wind_a.items, 0);
            //const uvs = try self.calcUVCoords(wind_a.items, side, @intCast(ret.tex.w), @intCast(ret.tex.h));
            _ = timer.reset();
            //try ret.sides.items[si].index.appendSlice(indexs);
            for (wind_a.items) |vert| {
                const ind = try self.vecmap.put(vert.cast(f32));
                try ret.sides.items[si].index.append(ret._alloc, ind);
            }
            gen_time += timer.read();
        }
        try ret.verts.appendSlice(ret._alloc, self.vecmap.verts.items);
        return ret;
    }

    pub fn triangulate(self: *Self, winding: []const Vec3_64, offset: u32) ![]const u32 {
        return self.triangulateAny(winding, offset);
    }
    //Generate indicies into trianglnes that can be drawin with the uknow, opengl draw indexed
    pub fn triangulateAny(self: *Self, winding: anytype, offset: u32) ![]const u32 {
        self.triangulate_index.clearRetainingCapacity();
        const ret = &self.triangulate_index;
        if (winding.len < 3) return ret.items;

        for (1..winding.len - 1) |i| {
            const ii: u32 = @intCast(i);
            try ret.append(0 + offset);
            try ret.append(ii + 1 + offset);
            try ret.append(ii + offset);
        }

        return ret.items;
    }

    /// for each vertex defined by index into all_verts, Triangulate
    pub fn triangulateIndex(self: *Self, count: u32, offset: u32) ![]const u32 {
        self.triangulate_index.clearRetainingCapacity();
        const ret = &self.triangulate_index;
        if (count < 3) return ret.items;
        for (1..count - 1) |i| {
            const ii: u32 = @intCast(i);
            try ret.append(0 + offset);
            try ret.append(ii + 1 + offset);
            try ret.append(ii + offset);
        }
        return ret.items;
    }

    pub fn clipWinding(self: *Self, winding_in: std.ArrayList(Vec3_64), winding_out: *std.ArrayList(Vec3_64), plane: Plane) !void {
        self.clip_winding_sides.clearRetainingCapacity();
        self.clip_winding_dists.clearRetainingCapacity();
        var sides = &self.clip_winding_sides;
        var dists = &self.clip_winding_dists;
        for (winding_in.items) |wind| {
            const dist = plane.norm.dot(wind) - plane.dist;
            try dists.append(dist);
            if (dist > EPSILON) {
                try sides.append(.front);
            } else if (dist < -EPSILON) {
                try sides.append(.back);
            } else {
                try sides.append(.on);
            }
        }
        const front = winding_out;
        front.clearRetainingCapacity();
        if (winding_in.items.len == 0) return;
        try sides.append(sides.items[0]);
        try dists.append(dists.items[0]);

        for (winding_in.items, 0..) |p_cur, i| {
            if (sides.items[i] == .on) {
                try front.append(p_cur);
                continue;
            }
            if (sides.items[i] == .front)
                try front.append(p_cur);

            if (sides.items[i + 1] == .on or sides.items[i] == sides.items[i + 1])
                continue;

            const p_next = winding_in.items[(i + 1) % winding_in.items.len];
            const t = dists.items[i] / (dists.items[i] - dists.items[i + 1]);

            const v = p_next.sub(p_cur).scale(t);
            try front.append(p_cur.add(v));
        }
    }

    pub fn calcUVCoords(self: *Self, winding: []const Vec3_32, side: ecs.Side, tex_w: u32, tex_h: u32, origin: Vec3_32) ![]const Vec2 {
        self.uvs.clearRetainingCapacity();
        const uvs = &self.uvs;
        var umin: f32 = std.math.floatMax(f32);
        var vmin: f32 = std.math.floatMax(f32);
        const tw: f64 = @floatFromInt(tex_w);
        const th: f64 = @floatFromInt(tex_h);
        for (winding) |item_abs| {
            const item = item_abs.sub(origin);
            const uv = Vec2.new(
                @as(f32, @floatCast(item.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                @as(f32, @floatCast(item.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
            );
            try uvs.append(uv);
            umin = @min(umin, uv.x());
            vmin = @min(vmin, uv.y());
        }
        const uoff = @floor(umin);
        const voff = @floor(vmin);
        for (uvs.items) |*uv| {
            uv.xMut().* -= uoff;
            uv.yMut().* -= voff;
        }

        return uvs.items;
    }

    pub fn calcUVCoordsIndexed(self: *Self, winding: []const Vec3_32, index: []const u32, side: ecs.Side, tex_w: u32, tex_h: u32, origin: Vec3_32) ![]const Vec2 {
        self.uvs.clearRetainingCapacity();
        const uvs = &self.uvs;
        var umin: f32 = std.math.floatMax(f32);
        var vmin: f32 = std.math.floatMax(f32);
        const tw: f64 = @floatFromInt(tex_w);
        const th: f64 = @floatFromInt(tex_h);
        for (index) |i| {
            const item = winding[i].sub(origin);
            const uv = Vec2.new(
                @as(f32, @floatCast(item.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                @as(f32, @floatCast(item.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
            );
            try uvs.append(uv);
            umin = @min(umin, uv.x());
            vmin = @min(vmin, uv.y());
        }
        const uoff = @floor(umin);
        const voff = @floor(vmin);
        for (uvs.items) |*uv| {
            uv.xMut().* -= uoff;
            uv.yMut().* -= voff;
        }

        return uvs.items;
    }

    pub fn baseWinding(self: *Self, plane: Plane, size: f64) ![]const Vec3_64 {
        const global_up = try getGlobalUp(plane.norm);
        const right = plane.norm.cross(global_up).norm().scale(size / 2);

        const up = plane.norm.cross(right);
        const offset = plane.norm.scale(plane.dist);
        self.base_winding[0] = offset.add(right.scale(-1)).add(up);
        self.base_winding[1] = offset.add(right.scale(-1)).add(up.scale(-1));
        self.base_winding[2] = offset.add(right).add(up.scale(-1));
        self.base_winding[3] = offset.add(right).add(up);
        return &self.base_winding;
    }

    pub fn findDisplacmentStartI(self: *Self, side_winding: []const Vec3_32, start_pos: Vec3_32) !usize {
        _ = self;
        var nearest: f32 = std.math.floatMax(f32);
        var start_i: usize = 0;
        for (side_winding, 0..) |vert, i| {
            const dist = vert.distance(start_pos);
            if (dist < nearest) {
                start_i = i;
                nearest = dist;
            }
        }
        return start_i;
    }

    pub fn genMeshDisplacement(self: *Self, side_winding: []const Vec3_32, disp: *ecs.Displacement) !void {
        _ = self;
        const start_i = disp.vert_start_i;

        const v0 = side_winding[start_i];
        const v1 = side_winding[(start_i + 1) % side_winding.len];
        const v2 = side_winding[(start_i + 2) % side_winding.len];
        const v3 = side_winding[(start_i + 3) % side_winding.len];

        const vper_row: u32 = (std.math.pow(u32, 2, disp.power) + 1);
        var verts = &disp._verts;
        try verts.resize(disp._alloc, vper_row * vper_row);
        const t = 1.0 / (@as(f32, @floatFromInt(vper_row)) - 1); //In the paper, they don't subtract one, this would lead to incorrect lerp?
        const elev = disp.elevation;
        const helper = struct {
            pub fn checkArray(a: anytype, vp: usize) ?@TypeOf(a) {
                //if (!a.was_init)
                //    return null;
                if (a.len < vp * vp) {
                    std.debug.print("Invalid displacement\n", .{});
                    return null;
                }
                return a;
            }
        };

        const offsets: ?[]const Vec3_32 = helper.checkArray(disp.offsets.items, vper_row);
        const offset_normal: ?[]const Vec3_32 = helper.checkArray(disp.normal_offsets.items, vper_row);
        const norms: ?[]const Vec3_32 = helper.checkArray(disp.normals.items, vper_row);

        const dists: ?[]const f32 = helper.checkArray(disp.dists.items, vper_row);

        for (0..vper_row) |v_i| {
            const fi: f32 = @floatFromInt(v_i);
            const v_inter0 = v0.lerp(v1, t * fi);
            const v_inter1 = v3.lerp(v2, t * fi);
            for (0..vper_row) |c_i| {
                const g_i = v_i * vper_row + c_i;
                const ji: f32 = @floatFromInt(c_i);
                const v_orig = v_inter0.lerp(v_inter1, t * ji);

                const dist = if (dists) |d| d[g_i] else 0;

                //const vert = v_orig;
                var vert = v_orig;
                if (norms) |n|
                    vert = vert.add(n[g_i].scale(dist));

                if (offset_normal) |ofn|
                    vert = vert.add(ofn[g_i].scale(elev));

                if (offsets) |off|
                    vert = vert.add(off[g_i]);

                verts.items[g_i] = vert;
            }
        }

        var ind = &disp._index;
        ind.clearRetainingCapacity();
        // triangulate
        const quad_per_row = vper_row - 1;
        var left: bool = false;
        for (0..quad_per_row) |q_i| {
            for (0..quad_per_row) |q_j| {
                const in0: u32 = @intCast((q_i * vper_row) + q_j);
                const in1: u32 = @intCast((q_i * vper_row) + q_j + 1);
                const in2: u32 = @intCast(((q_i + 1) * vper_row) + q_j);
                const in3: u32 = @intCast(((q_i + 1) * vper_row) + q_j + 1);

                try ind.appendSlice(disp._alloc, &.{
                    in1, in2, in0, in3, in2, in1,
                });
                left = !left;
            }
            left = !left;
        }
    }
};

pub fn conVec(v: anytype) @TypeOf(v) {
    return @TypeOf(v).new(v.x(), v.z(), -v.y());
}

// Rounds off anything after 0.1
pub const VecMap = struct {
    pub const HashCtx = struct {
        const off = 10;
        pub fn hash(self: HashCtx, k: Vec3_32) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);

            std.hash.autoHash(&hasher, @as(i64, @intFromFloat(@round(k.x() * off))));
            std.hash.autoHash(&hasher, @as(i64, @intFromFloat(@round(k.y() * off))));
            std.hash.autoHash(&hasher, @as(i64, @intFromFloat(@round(k.z() * off))));
            return hasher.final();
        }

        pub fn eql(_: HashCtx, a: Vec3_32, b: Vec3_32) bool {
            //TODO maybe this sucks, look it up
            const x: i64 = @intFromFloat(@round(a.x() * off));
            const y: i64 = @intFromFloat(@round(a.y() * off));
            const z: i64 = @intFromFloat(@round(a.z() * off));

            const x1: i64 = @intFromFloat(@round(b.x() * off));
            const y1: i64 = @intFromFloat(@round(b.y() * off));
            const z1: i64 = @intFromFloat(@round(b.z() * off));

            //return @abs(x - x1) <= THRESH and @abs(y - y1) <= THRESH and @abs(z - z1) <= THRESH;

            return x == x1 and y == y1 and z == z1;
        }
    };

    pub const MapT = std.HashMap(Vec3_32, u32, HashCtx, 80);
    verts: std.ArrayList(Vec3_32),
    map: MapT,

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .verts = std.ArrayList(Vec3_32).init(alloc),
            .map = MapT.init(alloc),
        };
    }

    pub fn clear(self: *@This()) void {
        self.map.clearRetainingCapacity();
        self.verts.clearRetainingCapacity();
    }

    pub fn put(self: *@This(), v: Vec3_32) !u32 {
        const res = try self.map.getOrPut(v);
        if (!res.found_existing) {
            const index = self.verts.items.len;
            try self.verts.append(v);
            res.value_ptr.* = @intCast(index);
        }
        return res.value_ptr.*;
    }

    pub fn deinit(self: *@This()) void {
        self.verts.deinit();
        self.map.deinit();
    }
};

pub fn getGlobalUp(norm: Vec3_64) !Vec3_64 {
    var axis: ?usize = null;
    var max = -std.math.floatMax(f64);
    const dat: [3]f64 = norm.data;
    for (dat, 0..) |comp, i| {
        const abs = @abs(comp);
        if (abs > max) {
            max = abs;
            axis = i;
        }
    }
    if (axis == null)
        return error.invalidVector;
    if (axis == 1)
        return Vec3_64.new(1, 0, 0);
    return Vec3_64.new(0, 1, 0);
}

pub fn roundVec(v: Vec3_64) Vec3_64 {
    var a = v;
    const R: f64 = 128;
    const rr = @Vector(3, f64){ R, R, R };
    a.data = @round(v.data * rr) / rr;
    return a;
}

const Plane = struct {
    norm: Vec3_64,
    dist: f64,
    pub fn fromTri(tri: [3]Vec3_64) @This() {
        const v1 = tri[1].sub(tri[0]);
        const v2 = tri[2].sub(tri[0]);
        const norm = v1.cross(v2).norm();
        return .{
            .norm = norm,
            .dist = norm.dot(tri[0]),
        };
    }
};
