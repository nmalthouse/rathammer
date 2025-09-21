const std = @import("std");
const ecs = @import("ecs.zig");
const Solid = ecs.Solid;
const graph = @import("graph");
const csg = @import("csg.zig");
const Vec3 = graph.za.Vec3;
const Side = ecs.Side;
const vpk = @import("vpk.zig");
const util_3d = @import("util_3d.zig");
//
// planes intersect if n1 cross n2 != 0

//For each face of solid
//  does intersect with clip_plane
//  categorize side a or b
//  store
//
//  for a sides

// classify right, left, planar

// for each side
//  for each vert
//      if this_vert_side != last_vert_side

pub const VertKind = enum {
    left,
    right,
    on,

    pub fn getW(plane_p0: Vec3, plane_norm: Vec3) f32 {
        return plane_norm.dot(plane_p0);
    }

    pub fn classify(plane_norm: Vec3, w: f32, v: Vec3) VertKind {
        const EPS = 0.001;
        const p = plane_norm.dot(v) - w;
        if (p > EPS)
            return .right;
        if (p < -EPS)
            return .left;
        return .on;
    }
};

test "classify" {
    const ex = std.testing.expectEqual;
    const p0 = Vec3.zero();
    const n = Vec3.new(1, 0, 0);
    const p = Vec3.new(10, 10, 10);
    const w = VertKind.getW(p0, n);
    try ex(.right, VertKind.classify(n, w, p));
    try ex(.left, VertKind.classify(n, w, Vec3.new(-10, 0, 0)));
    try ex(.on, VertKind.classify(n, w, Vec3.new(0, 0, 0)));

    const p1 = Vec3.new(11, -8, 3);
    const n1 = Vec3.new(1, 1, 1).norm();
    const w1 = VertKind.getW(p1, n1);
    try ex(.right, VertKind.classify(n1, w1, Vec3.new(12, 6, 9)));
    try ex(.left, VertKind.classify(n1, w1, Vec3.new(2, -15, 7)));
    try ex(.left, VertKind.classify(n1, w1, Vec3.new(0, 0, 0)));
}

fn doesSegmentIntersectPlane(p0: Vec3, pn: Vec3, start: Vec3, end: Vec3) Vec3 {
    const dir = end.sub(start);
    const w = pn.dot(p0);
    const d = (w - start.dot(pn)) / dir.dot(pn);
    return start.add(dir.scale(d));
}

fn doesSegmentIntersectPlane2(p0: Vec3, pn: Vec3, start: Vec3, end: Vec3) ?Vec3 {
    const norm = end.sub(start).norm();
    const ln = norm.dot(pn);
    if (@abs(ln) < 0.0001)
        return null;

    const d = (p0.sub(start).dot(pn)) / ln;
    const d2 = end.sub(start).length();
    //0 d d2
    if (d > 0 and d < d2 or d < 0 and d > d2)
        return start.add(norm.scale(d));
    return null;
}

test "line segment plane" {
    const ex = std.testing.expectEqual;
    const thing = doesSegmentIntersectPlane;
    const p0 = Vec3.new(0, 0, 0);
    const pn = Vec3.new(1, 0, 0);
    const st = Vec3.new(-1, 0, 0);
    const end = Vec3.new(1, 0, 0);
    try ex(thing(p0, pn, st, end), Vec3.new(0, 0, 0));
}

const Mapper = struct {
    map: std.AutoHashMap(u32, u32),
    index: u32 = 0,

    pub fn put(self: *@This(), vi: u32) !void {
        if (self.map.contains(vi)) return;
        defer self.index += 1;
        try self.map.put(vi, self.index);
    }

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .map = std.AutoHashMap(u32, u32).init(alloc),
        };
    }

    pub fn reset(self: *@This()) void {
        self.map.clearRetainingCapacity();
        self.index = 0;
    }

    pub fn buildSolid(self: *@This(), solid: *Solid, verts: []const Vec3) !void {
        try solid.verts.resize(solid._alloc, self.map.count());
        var it = self.map.iterator();
        while (it.next()) |item|
            solid.verts.items[item.value_ptr.*] = verts[item.key_ptr.*];

        for (solid.sides.items) |*side| {
            for (side.index.items) |*index| {
                index.* = self.map.get(index.*) orelse return error.broken;
            }
        }
        try solid.optimizeMesh();
    }
};

pub const ClipCtx = struct {
    const Self = @This();

    verts: std.ArrayList(VertKind),
    alloc: std.mem.Allocator,
    mappers: [2]Mapper,
    vert_map: csg.VecMap.MapT,
    ret_verts: std.ArrayList(Vec3),
    sides: [2]Side,
    split_side: Side,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .verts = std.ArrayList(VertKind).init(alloc),
            .alloc = alloc,
            .mappers = .{ Mapper.init(alloc), Mapper.init(alloc) },
            .vert_map = csg.VecMap.MapT.initContext(alloc, .{}),
            .ret_verts = std.ArrayList(Vec3).init(alloc),
            .sides = .{ Side.init(alloc), Side.init(alloc) },
            .split_side = Side.init(alloc),
        };
    }

    pub fn reset(self: *Self) void {
        self.verts.clearRetainingCapacity();
        for (&self.mappers) |*m|
            m.reset();
        self.vert_map.clearRetainingCapacity();
        self.ret_verts.clearRetainingCapacity();
        self.split_side.index.clearRetainingCapacity();
    }

    pub fn deinit(self: *Self) void {
        self.verts.deinit();
        for (&self.mappers) |*m|
            m.map.deinit();
        self.vert_map.deinit();
        self.ret_verts.deinit();
        self.split_side.deinit();
    }

    pub fn putOne(self: *Self, i: u8, ind: u32) !void {
        try self.sides[i].index.append(self.sides[i]._alloc, ind);
        try self.mappers[i].put(ind);
    }

    pub fn putBoth(self: *Self, ind: u32) !void {
        try self.putOne(0, ind);
        try self.putOne(1, ind);
    }

    pub fn clipSolid(self: *Self, solid: *const Solid, plane_p0: Vec3, plane_norm: Vec3, tex_id: ?vpk.VpkResId) ![2]Solid {
        self.reset();
        const w = VertKind.getW(plane_p0, plane_norm);
        for (solid.verts.items) |v| {
            try self.verts.append(VertKind.classify(plane_norm, w, v));
            try self.ret_verts.append(v);
        }

        var ret: [2]Solid = .{ Solid.init(self.alloc), Solid.init(self.alloc) };
        //Track verticies used by each

        //TODO don't add the pointless verticies

        for (solid.sides.items) |*side| {
            for (&self.sides) |*s| {
                s.* = try side.dupe();
                try s.index.resize(s._alloc, 0);
            }
            for (side.index.items, 0..) |vi, ii| {
                const k = self.verts.items[vi];
                switch (k) {
                    .left, .right => {
                        switch (k) {
                            .left => try self.putOne(0, vi),
                            .right => try self.putOne(1, vi),
                            else => unreachable,
                        }
                        const n_i = (ii + 1) % side.index.items.len;
                        const next_kind = self.verts.items[side.index.items[n_i]];
                        // Make the cut, add verts.
                        if (next_kind != .on and next_kind != k) {
                            const start = solid.verts.items[side.index.items[n_i]];
                            const end = solid.verts.items[vi];
                            const int = doesSegmentIntersectPlane(plane_p0, plane_norm, start, end);
                            if (!self.vert_map.contains(int)) {
                                const index: u32 = @intCast(self.ret_verts.items.len);
                                try self.vert_map.put(int, index);
                                try self.ret_verts.append(int);
                                // ! only put the vertex into new side once
                                try self.split_side.index.append(self.split_side._alloc, index);
                            }
                            const in = self.vert_map.get(int) orelse return error.broken;
                            try self.putBoth(in);
                            //Make a new vertex;

                        }
                    },
                    .on => {
                        if (!self.vert_map.contains(self.ret_verts.items[vi])) {
                            try self.vert_map.put(self.ret_verts.items[vi], 0);
                            try self.split_side.index.append(self.split_side._alloc, vi);
                        }
                        try self.putBoth(vi);
                    },
                }
            }
            for (&self.sides, 0..) |*s, i| {
                if (s.index.items.len > 0) {
                    try ret[i].sides.append(ret[i]._alloc, s.*);
                } else {
                    s.deinit();
                }
            }
        }
        if (self.split_side.index.items.len >= 3) {
            sortPolygonPoints(self.split_side.index.items, plane_norm, self.ret_verts.items);
            const rv = self.ret_verts.items;
            const it = self.split_side.index.items;
            const plane = util_3d.trianglePlane(.{ rv[it[0]], rv[it[1]], rv[it[2]] });
            self.split_side.tex_id = tex_id orelse 0;

            self.split_side.resetUv(plane, false);
            try ret[0].sides.append(ret[0]._alloc, try self.split_side.dupe());
            var duped = try self.split_side.dupe();
            duped.flipNormal();
            try ret[1].sides.append(ret[1]._alloc, duped);
        }
        for (&self.mappers, 0..) |*m, i|
            try m.buildSolid(&ret[i], self.ret_verts.items);

        return ret;
    }
};

pub fn sortPolygonPoints(points: []u32, pn: Vec3, verts: []const Vec3) void {
    const Ctx = struct {
        mean: Vec3,
        b0: Vec3,
        b1: Vec3,
        verts: []const Vec3,

        fn lessThan(ctx: @This(), ia: u32, ib: u32) bool {
            const va = ctx.verts[ia];
            const vb = ctx.verts[ib];

            const ar = va.sub(ctx.mean);
            const br = vb.sub(ctx.mean);
            const aa = std.math.atan2(ctx.b1.dot(ar), ctx.b0.dot(ar));
            const ba = std.math.atan2(ctx.b1.dot(br), ctx.b0.dot(br));
            return aa < ba;
        }
    };
    if (points.len == 0) return;
    var mean = Vec3.zero();
    for (points) |v|
        mean = mean.add(verts[v]);
    mean = mean.scale(1 / @as(f32, @floatFromInt(points.len)));

    const b0 = verts[points[0]].sub(mean).norm();
    const ctx: Ctx = .{ .mean = mean, .b0 = b0, .b1 = b0.cross(pn), .verts = verts };
    std.sort.insertion(u32, points, ctx, Ctx.lessThan);
}

//TODO this doesn't test anything
test "clip solid" {
    if (true)
        return;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var sol = try Solid.initFromCube(alloc, Vec3.new(-10, -10, -10), Vec3.new(10, 10, 10), 0);
    defer sol.deinit();
    var ctx = ClipCtx.init(alloc);
    defer ctx.deinit();
    const p0 = Vec3.new(-4, -4, -4);
    const pn = Vec3.new(1, 1, 1).norm();
    var ret = try ctx.clipSolid(&sol, p0, pn, 0);

    std.debug.print("\n", .{});
    const o = std.debug;
    const off = ret[0].printObj(0, "crass", o);
    _ = ret[1].printObj(off, "crass2", o);

    for (&ret) |*r|
        r.deinit();
}
