pub const Side = struct {
    const Justify = enum {
        left,
        right,
        center,
        fit,
        top,
        bottom,
    };
    pub const UVaxis = struct {
        axis: Vec3 = Vec3.zero(),
        trans: f32 = 0,
        scale: f32 = 0.25,

        pub fn eql(a: @This(), b: @This()) bool {
            return a.trans == b.trans and a.scale == b.scale and a.axis.x() == b.axis.x() and a.axis.y() == b.axis.y() and
                a.axis.z() == b.axis.z();
        }
    };

    /// Used by displacement
    _omit_from_batch: bool = false,

    _alloc: std.mem.Allocator,
    index: ArrayList(u32) = .{},
    u: UVaxis = .{},
    v: UVaxis = .{},
    tex_id: vpk.VpkResId = 0,
    //TODO these shouldn't be serialized
    tw: i32 = 10,
    th: i32 = 10,

    lightmapscale: i32 = 16,
    smoothing_groups: i32 = 0,

    /// This field is allocated by StringStorage.
    /// It is only used to keep track of textures that are missing, so they are persisted across save/load.
    /// the actual material assigned is stored in `tex_id`
    material: []const u8 = "",
    pub fn deinit(self: *@This()) void {
        self.index.deinit(self._alloc);
    }

    pub fn dupe(self: *@This()) !@This() {
        var ret = self.*;
        ret.index = try self.index.clone(self._alloc);
        return ret;
    }

    pub fn flipNormal(self: *@This()) void {
        std.mem.reverse(u32, self.index.items);
    }

    //return a point on this plane
    pub fn getP0(self: *const @This(), solid: *const Solid) ?Vec3 {
        if (self.index.items.len == 0) return null;

        return solid.verts.items[self.index.items[0]];
    }

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ ._alloc = alloc };
    }

    pub fn normal(self: *const @This(), solid: *const Solid) Vec3 {
        const ind = self.index.items;
        if (ind.len < 3) return Vec3.zero();
        const v = solid.verts.items;
        return util3d.trianglePlane(.{ v[ind[0]], v[ind[1]], v[ind[2]] });
    }

    pub fn rebuild(side: *@This(), solid: *Solid, batch: *ecs.MeshBatch, editor: *Editor) !void {
        if (side._omit_from_batch)
            return;
        side.tex_id = batch.tex_res_id;
        side.tw = batch.mat.slots[0].w;
        side.th = batch.mat.slots[0].h;
        const mesh = &batch.mesh;

        try mesh.vertices.ensureUnusedCapacity(mesh.alloc, side.index.items.len);

        try batch.lines_index.ensureUnusedCapacity(side.index.items.len * 2);
        //const uv_origin = solid.verts.items[side.index.items[0]];
        const uvs = try editor.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            if (editor.draw_state.mode == .lightmap_scale) 1.0 else @intCast(side.tw),
            if (editor.draw_state.mode == .lightmap_scale) 1.0 else @intCast(side.th),
            Vec3.zero(),
            if (editor.draw_state.mode == .lightmap_scale) @as(f64, @floatFromInt(side.lightmapscale)) else null,
        );
        const offset = mesh.vertices.items.len;
        for (side.index.items, 0..) |v_i, i| {
            const v = solid.verts.items[v_i];
            const norm = side.normal(solid).scale(-1);
            try mesh.vertices.append(mesh.alloc, .{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uvs[i].x(),
                .v = uvs[i].y(),
                .nx = norm.x(),
                .ny = norm.y(),
                .nz = norm.z(),
                .color = 0xffffffff,
            });
            const next = (i + 1) % side.index.items.len;
            try batch.lines_index.append(@intCast(offset + i));
            try batch.lines_index.append(@intCast(offset + next));
        }
        const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(offset), false);
        const start_i = mesh.indicies.items.len;
        try mesh.indicies.appendSlice(mesh.alloc, indexs);
        for (0..@divExact(indexs.len, 3)) |tri_i| {
            const si = tri_i * 3 + start_i;

            const v1 = &mesh.vertices.items[mesh.indicies.items[si]];
            const v2 = &mesh.vertices.items[mesh.indicies.items[si + 1]];
            const v3 = &mesh.vertices.items[mesh.indicies.items[si + 2]];
            const e1 = Vec3.new(v2.x, v2.y, v2.z).sub(Vec3.new(v1.x, v1.y, v1.z));
            const e2 = Vec3.new(v3.x, v3.y, v3.z).sub(Vec3.new(v1.x, v1.y, v1.z));
            const du1 = v2.u - v1.u;
            const dv1 = v2.v - v1.v;
            const du2 = v3.u - v1.u;
            const dv2 = v3.v - v1.v;
            const f = 1.0 / (du1 * dv2 - du2 * dv1);
            const tangent = Vec3.new(
                (dv2 * e1.x()) - (dv1 * e2.x()),
                (dv2 * e1.y()) - (dv1 * e2.y()),
                (dv2 * e1.z()) - (dv1 * e2.z()),
            ).scale(f);

            v1.tx += tangent.x();
            v2.tx += tangent.x();
            v3.tx += tangent.x();

            v1.ty += tangent.y();
            v2.ty += tangent.y();
            v3.ty += tangent.y();

            v1.tz += tangent.z();
            v2.tz += tangent.z();
            v3.tz += tangent.z();
        }
    }

    pub fn getMeanPoint(self: *const @This(), solid: *const Solid) Vec3 {
        var vec = Vec3.zero();
        if (self.index.items.len == 0) return vec;
        for (self.index.items) |ind| {
            vec = vec.add(solid.verts.items[ind]);
        }
        return vec.scale(1.0 / @as(f32, @floatFromInt(self.index.items.len)));
    }

    pub fn serial(self: @This(), editor: *Editor, jw: anytype, ent_id: EcsT.Id) !void {
        try jw.beginObject();
        {
            try jw.objectField("index");
            try jw.beginArray();

            for (self.index.items) |id| {
                try jw.write(id);
            }

            try jw.endArray();
            try jw.objectField("u");
            try editor.writeComponentToJson(jw, self.u, ent_id);
            try jw.objectField("v");
            try editor.writeComponentToJson(jw, self.v, ent_id);
            try jw.objectField("tex_id");
            try editor.writeComponentToJson(jw, self.tex_id, ent_id);
            try jw.objectField("lightmapscale");
            try editor.writeComponentToJson(jw, self.lightmapscale, ent_id);
            try jw.objectField("smoothing_groups");
            try editor.writeComponentToJson(jw, self.smoothing_groups, ent_id);
        }
        try jw.endObject();
    }

    pub fn resetUv(self: *@This(), norm: Vec3, face: bool, u_scale: f32, v_scale: f32) void {
        if (face) {
            const basis = Vec3.new(0, 0, 1);
            const ang = std.math.radiansToDegrees(
                std.math.acos(basis.dot(norm)),
            );
            const mat = graph.za.Mat3.fromRotation(ang, basis.cross(norm));
            self.u = .{ .axis = mat.mulByVec3(Vec3.new(1, 0, 0)), .trans = 0, .scale = u_scale };
            self.v = .{ .axis = mat.mulByVec3(Vec3.new(0, 1, 0)), .trans = 0, .scale = v_scale };
        } else {
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
            const b = util3d.getBasis(norm);
            self.u = .{ .axis = b[0], .trans = 0, .scale = u_scale };
            self.v = .{ .axis = b[1], .trans = 0, .scale = v_scale };
        }
    }

    pub fn justify(self: *@This(), verts: []const Vec3, kind: Justify) struct { u: UVaxis, v: UVaxis } {
        var u = self.u;
        var v = self.v;
        if (self.index.items.len < 3) return .{ .u = u, .v = v };

        const p0 = verts[self.index.items[0]];
        var umin = std.math.floatMax(f32);
        var umax = -std.math.floatMax(f32);
        var vmin = std.math.floatMax(f32);
        var vmax = -std.math.floatMax(f32);

        for (self.index.items) |ind| {
            const vert = verts[ind];
            const udot = vert.dot(self.u.axis);
            const vdot = vert.dot(self.v.axis);

            umin = @min(udot, umin);
            umax = @max(udot, umax);

            vmin = @min(vdot, vmin);
            vmax = @max(vdot, vmax);
        }
        const u_dist = umax - umin;
        const v_dist = vmax - vmin;

        const tw: f32 = @floatFromInt(self.tw);
        const th: f32 = @floatFromInt(self.th);

        switch (kind) {
            .fit => {
                u.scale = u_dist / tw;
                v.scale = v_dist / th;

                u.trans = @mod(-p0.dot(self.u.axis) / u.scale, tw);
                v.trans = @mod(-p0.dot(self.v.axis) / v.scale, th);
            },
            .left => u.trans = @mod(-umin / u.scale, tw),
            .right => u.trans = @mod(-umax / u.scale, tw),
            .top => v.trans = @mod(-vmin / v.scale, th),
            .bottom => v.trans = @mod(-vmax / v.scale, th),
            .center => {
                u.trans = @mod((-(umin + u_dist / 2) / u.scale) - tw / 2, tw);
                v.trans = @mod((-(vmin + v_dist / 2) / v.scale) - th / 2, th);
            },
        }
        return .{ .u = u, .v = v };
    }
};

pub const InvalidSolid = struct {
    pub const ECS_NO_SERIAL = void;

    pub fn dupe(self: *@This(), _: anytype, _: anytype) !@This() {
        return self.*;
    }

    pub fn initFromJson(_: std.json.Value, _: anytype) !@This() {
        return error.notAllowed;
    }

    problem: SolidValidityReport,
};

pub const SolidValidityReport = union(enum) {
    const SideI = struct {
        side_i: u32,
        mid_v: Vec3,
    };

    tooFewSides,

    duplicateVerts: struct {
        first_i: u32,
        second_i: u32,
    },
    index_out_of_bounds: struct {
        side_i: u32,
        index: u32,
    },
    not_sealed: struct {
        vert_i: u32,
    },
    invalid_normal: SideI,
    side_not_flat: SideI,

    duplicate_normal: struct {
        first_side_i: u32,
        second_side_i: u32,

        first_mid_v: Vec3,
        second_mid_v: Vec3,
    },
};

pub const Solid = struct {
    const Self = @This();
    _alloc: std.mem.Allocator,
    sides: ArrayList(Side) = .{},
    verts: ArrayList(Vec3) = .{},

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    pub fn init(alloc: std.mem.Allocator) Solid {
        return .{ ._alloc = alloc };
    }

    //pub fn initFromJson(v: std.json.Value, editor: *Context) !@This() {
    //    //var ret = init(editor.alloc);
    //    return editor.readComponentFromJson(v, Self);
    //}

    pub fn dupe(self: *const Self, _: anytype, _: anytype) !Self {
        const ret_sides = try self.sides.clone(self._alloc);
        for (ret_sides.items, 0..) |*side, i| {
            side.* = try self.sides.items[i].dupe();
        }
        return .{
            ._alloc = self._alloc,
            .sides = ret_sides,
            .verts = try self.verts.clone(self._alloc),
        };
    }

    pub fn checkValidity(self: *const Self) !?SolidValidityReport {
        const log = std.log.scoped(.ecs_solid);
        // a prism is the simplest valid solid
        if (self.verts.items.len < 4) return .{ .tooFewSides = {} };

        var vmap = csg.VecMap.init(self._alloc);
        defer vmap.deinit();

        { // Are all verts unique?
            for (self.verts.items, 0..) |vert, v_i| {
                _ = vmap.putUnique(vert) catch |err| {
                    if (err == error.notUnique) {
                        const first_i = vmap.map.get(vert) orelse blk: { //This should never fail
                            log.err("first duplicate vert not found! defaulting to zero", .{});
                            break :blk 0;
                        };
                        return .{ .duplicateVerts = .{
                            .first_i = first_i,
                            .second_i = @intCast(v_i),
                        } };
                    }
                    return err;
                };
            }
        }

        {
            // Are all vertices used by >= 3 sides. If not the solid is not sealed.
            // Are all indices valid
            var vert_ref_count = std.ArrayList(usize){};
            defer vert_ref_count.deinit(self._alloc);
            try vert_ref_count.appendNTimes(self._alloc, 0, self.verts.items.len);
            for (self.sides.items, 0..) |side, s_i| {
                for (side.index.items) |ind| {
                    if (ind >= vert_ref_count.items.len) return .{ .index_out_of_bounds = .{
                        .side_i = @intCast(s_i),
                        .index = ind,
                    } };

                    vert_ref_count.items[ind] += 1;
                }
            }

            for (vert_ref_count.items, 0..) |vref, v_i| {
                if (vref < 3) return .{ .not_sealed = .{ .vert_i = @intCast(v_i) } };
            }
        }

        {
            //Is each normal valid
            //Is each face's normal unique?

            var norms = csg.VecMap.init(self._alloc);
            defer norms.deinit();
            norms.map.ctx.multiplier = 10000;

            for (self.sides.items, 0..) |*side, s_i| {
                const norm = side.normal(self);
                if (@abs(norm.length()) < 0.1) return .{ .invalid_normal = .{ .side_i = @intCast(s_i), .mid_v = self.sides.items[s_i].getMeanPoint(self) } };

                _ = norms.putUnique(norm) catch |err| {
                    if (err == error.notUnique) {
                        const first_i = norms.map.get(norm) orelse blk: { //This should never fail
                            log.err("first duplicate normal not found! defaulting to zero", .{});
                            break :blk 0;
                        };

                        return .{ .duplicate_normal = .{
                            .first_side_i = first_i,
                            .second_side_i = @intCast(s_i),
                            .first_mid_v = self.sides.items[first_i].getMeanPoint(self),
                            .second_mid_v = self.sides.items[s_i].getMeanPoint(self),
                        } };
                    }
                    return err;
                };
            }
        }

        { //For each face:
            //   Is the normal consistent for all verticies? IE this face flat

            for (self.sides.items, 0..) |*side, s_i| {
                const len = side.index.items.len;
                const norm = side.normal(self);
                for (0..side.index.items.len) |ind_i| {
                    const v0 = self.verts.items[side.index.items[(ind_i + 0) % len]];
                    const v1 = self.verts.items[side.index.items[(ind_i + 1) % len]];
                    const v2 = self.verts.items[side.index.items[(ind_i + 2) % len]];
                    const this_norm = util3d.trianglePlane(.{ v0, v1, v2 });
                    if (this_norm.dot(norm) < limits.normal_similarity_threshold) {
                        return .{ .side_not_flat = .{
                            .side_i = @intCast(s_i),
                            .mid_v = side.getMeanPoint(self),
                        } };
                    }
                }
            }
        }
        return null;
    }

    /// Check if this solid can be written to a vmf file
    /// Assumes optimizeMesh_ has been called on self
    /// returns error if invalid
    pub fn validateVmfSolid(self: *const Self, csgctx: *csg.Context) !void {
        //To be valid:
        //  sides.len >= 4
        //  Every normal is unique

        if (self.sides.items.len < 4) return error.lessThan4Sides;

        var sstr = @import("string.zig").DummyStorage{};

        const vmf_sides = try self._alloc.alloc(vmf.Side, self.sides.items.len);
        defer self._alloc.free(vmf_sides);
        for (self.sides.items, 0..) |s, i| {
            if (s.index.items.len < 3) return error.degenerateSide;
            const inds = s.index.items;
            const v1 = self.verts.items[inds[0]];
            const v2 = self.verts.items[inds[1]];
            const v3 = self.verts.items[inds[2]];

            vmf_sides[i] = .{ .plane = .{ .tri = .{
                Vec3f64.new(v1.x(), v1.y(), v1.z()),
                Vec3f64.new(v2.x(), v2.y(), v2.z()),
                Vec3f64.new(v3.x(), v3.y(), v3.z()),
            } } };
        }

        var new_solid = try csgctx.genMesh2(vmf_sides, self._alloc, &sstr);
        defer new_solid.deinit();
        if (new_solid.sides.items.len != self.sides.items.len) return error.sideLen;
        if (new_solid.verts.items.len != self.verts.items.len) {
            if (false) {
                std.debug.print("{d} {d}\n", .{ new_solid.verts.items.len, self.verts.items.len });
                var stdout_buf: [128]u8 = undefined;
                var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
                try self.print(&stdout_writer.interface);
                try new_solid.print(&stdout_writer.interface);

                const off = try self.printObj(0, "old", &stdout_writer.interface);
                _ = try new_solid.printObj(off, "new", &stdout_writer.interface);
                try stdout_writer.interface.flush();
            }
            return error.vertLen;
        }

        const eps: f32 = 0.1;
        for (new_solid.verts.items, 0..) |nv, i| {
            if (nv.distance(self.verts.items[i]) > eps) {
                std.debug.print("DIST {d}\n", .{nv.distance(self.verts.items[i])});
                return error.vertsDifferent;
            }
        }

        //for(new_solid.sides.items, 0..)|ns, i|{ }
    }

    pub fn initFromPrimitive(alloc: std.mem.Allocator, verts: []const Vec3, faces: []const std.ArrayList(u32), tex_id: vpk.VpkResId, offset: Vec3, rot: graph.za.Mat3, u_scale: f32, v_scale: f32) !Solid {
        var ret = init(alloc);
        for (verts) |v|
            try ret.verts.append(alloc, rot.mulByVec3(v).add(offset));

        for (faces) |face| {
            var ind = ArrayList(u32){};
            try ind.appendSlice(alloc, face.items);

            try ret.sides.append(alloc, .{
                ._alloc = alloc,
                .index = ind,
                .u = .{},
                .v = .{},
                .material = "",
                .tex_id = tex_id,
            });
        }
        try ret.optimizeMesh(.{ .can_reorder = true });
        for (ret.sides.items) |*side| {
            const norm = side.normal(&ret);
            side.resetUv(norm, true, u_scale, v_scale);
        }
        return ret;
    }

    /// Ensures the following:
    ///     All verticies are unique
    ///     All side indicies are unique
    ///     Side's have > 2 verticies
    ///
    /// Rearrange verticies into well defined order
    /// Rearrange indicies to start with smallest index
    ///
    /// Does NOT check for convexity
    /// Does NOT check for solidity
    pub fn optimizeMesh(self: *Self, opts: struct {
        can_reorder: bool = false,
    }) !void {
        const alloc = self._alloc;
        var vmap = csg.VecMap.init(alloc);
        defer vmap.deinit();
        var new_sides = ArrayList(Side){};

        var index_map = std.AutoHashMap(u32, void).init(alloc);
        defer index_map.deinit();
        var index = ArrayList(u32){};
        defer index.deinit(alloc);

        {
            for (self.sides.items) |*side| {
                index_map.clearRetainingCapacity();
                index.clearRetainingCapacity();
                for (side.index.items) |*ind| { // ensure each vertex unique
                    ind.* = try vmap.put(self.verts.items[ind.*]);
                }

                for (side.index.items) |ind| { //ensure each index unique
                    const res = try index_map.getOrPut(ind);
                    if (res.found_existing) {} else {
                        try index.append(alloc, ind);
                    }
                }
                if (index.items.len < 3) { //Remove degenerate sides
                    side.deinit();
                    continue;
                }
                side.index.clearRetainingCapacity();
                try side.index.appendSlice(alloc, index.items);

                try new_sides.append(self._alloc, side.*);
            }
            self.sides.deinit(self._alloc);
            self.sides = new_sides;
        }
        if (vmap.verts.items.len < self.verts.items.len) {
            self.verts.shrinkAndFree(self._alloc, vmap.verts.items.len);
        }
        try self.verts.resize(self._alloc, vmap.verts.items.len);

        //Do not reorder indices or remove duplicate faces when a disp is attached as it may cause disp to be modified
        if (opts.can_reorder) { //Canonical form of solid . verts have a unique order, index have a unique order
            //enables fast comparison
            const mapping = try self._alloc.alloc(usize, vmap.verts.items.len);
            defer self._alloc.free(mapping);
            const map2 = try self._alloc.alloc(usize, vmap.verts.items.len);
            defer self._alloc.free(map2);
            for (0..mapping.len) |m|
                mapping[m] = m;

            var sort = csg.VecOrder.SortCtx{ .new = vmap.verts.items, .mapping = mapping };
            std.sort.insertionContext(0, mapping.len, &sort);

            for (0..mapping.len) |mi| {
                map2[mapping[mi]] = mi;
            }

            for (self.sides.items) |*side| {
                var smallest: u32 = std.math.maxInt(u32);
                var sm_i: usize = 0;
                for (side.index.items, 0..) |*ind, ii| {
                    ind.* = @intCast(map2[ind.*]);
                    if (ind.* < smallest) {
                        smallest = ind.*;
                        sm_i = ii;
                    }
                }
                try index.resize(side._alloc, side.index.items.len);

                @memcpy(index.items, side.index.items);

                side.index.clearRetainingCapacity();
                try side.index.appendSlice(side._alloc, index.items[sm_i..]);
                try side.index.appendSlice(side._alloc, index.items[0..sm_i]);
            }
        }

        @memcpy(self.verts.items, vmap.verts.items);

        if (opts.can_reorder) { //Check all sides are unique

            const HashCtx = struct {
                const Key = []const u32;

                pub fn hash(ctx: @This(), key: Key) u64 {
                    _ = ctx;

                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHashStrat(&hasher, key, .Deep);
                    return hasher.final();
                }

                pub fn eql(_: @This(), a: Key, b: Key) bool {
                    return std.mem.eql(u32, a, b);
                }
            };
            const MapT = std.HashMap(HashCtx.Key, void, HashCtx, std.hash_map.default_max_load_percentage);

            var to_remove: std.ArrayList(usize) = .{};
            defer to_remove.deinit(self._alloc);
            var map = MapT.init(self._alloc);
            defer map.deinit();
            for (self.sides.items, 0..) |side, i| {
                const res = try map.getOrPut(side.index.items);
                if (res.found_existing)
                    try to_remove.append(self._alloc, i);
            }

            var i = to_remove.items.len;
            while (i > 0) : (i -= 1) {
                const n = to_remove.items[i - 1];
                var old = self.sides.orderedRemove(n);
                old.deinit();
            }
            if (to_remove.items.len > 0)
                std.debug.print("Removed {d} duplicate sides\n", .{to_remove.items.len});
        }
    }

    pub fn roundAllVerts(self: *Self, id: EcsT.Id, ed: *Editor) !void {
        for (self.verts.items) |*vert| {
            vert.data = @round(vert.data);
        }
        try self.markDirty(id, ed);
    }

    pub fn deinit(self: *Self) void {
        for (self.sides.items) |*side|
            side.deinit();
        self.sides.deinit(self._alloc);
        self.verts.deinit(self._alloc);
    }

    pub fn recomputeBounds(self: *Self, aabb: *AABB, o_disp: ?*Displacements, opts: struct {
        include_both: bool,
    }) void {
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));

        if (o_disp) |disps| {
            for (disps.disps.items) |disp| {
                for (disp._verts.items) |v| {
                    min = min.min(v);
                    max = max.max(v);
                }
            }
        }

        if (opts.include_both or o_disp == null) {
            for (self.verts.items) |s| {
                min = min.min(s);
                max = max.max(s);
            }
        }
        aabb.a = min;
        aabb.b = max;
    }

    fn translateVertsSimple(self: *@This(), vert_i: []const u32, offset: Vec3) void {
        for (vert_i) |v_i| {
            if (v_i >= self.verts.items.len) continue;

            self.verts.items[v_i] = self.verts.items[v_i].add(offset);
        }
    }

    // TODO Update displacemnt
    pub fn translateVerts(self: *@This(), id: EcsT.Id, offset: Vec3, editor: *Editor, vert_i: []const u32, vert_offsets: ?[]const Vec3, factor: f32) !void {
        if (vert_offsets) |offs| {
            for (vert_i, 0..) |v_i, i| {
                if (v_i >= self.verts.items.len) continue;

                self.verts.items[v_i] = self.verts.items[v_i].add(offset).add(offs[i].scale(factor));
            }
        } else {
            self.translateVertsSimple(vert_i, offset);
        }

        try self.markDirty(id, editor);
    }

    pub fn flipNormal(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |*side| {
            side.flipNormal();
        }
        try self.markDirty(id, editor);
    }

    //Update displacement
    pub fn translateSide(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor, side_i: usize) !void {
        if (side_i >= self.sides.items.len) return;
        for (self.sides.items[side_i].index.items) |ind| {
            self.verts.items[ind] = self.verts.items[ind].add(vec);
        }

        try self.markDirty(id, editor);
    }

    pub fn markDirty(self: *@This(), id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |*side| {
            try editor.markMeshDirty(id, side.tex_id);
        }
        editor.draw_state.meshes_dirty = true;
    }

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor, rot_origin: Vec3, rot: ?Quat) !void {
        //move all verts, recompute bounds
        //for each batchid, call rebuild

        if (rot) |quat| {
            for (self.verts.items) |*vert| {
                const v = vert.sub(rot_origin);
                const rotv = quat.rotateVec(v);

                vert.* = rotv.add(rot_origin).add(vec);
            }
        } else {
            for (self.verts.items) |*vert| {
                vert.* = vert.add(vec);
            }
        }
        var pos = rot_origin.scale(-1);
        if (pos.length() > 0.1)
            pos = Vec3.new(1, 0, 0);
        for (self.sides.items) |*side| {
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;

            if (rot) |quat| {
                const pos_r = quat.rotateVec(pos.sub(rot_origin)).add(rot_origin);

                const new_u_axis = quat.rotateVec(side.u.axis);
                const new_v_axis = quat.rotateVec(side.v.axis);

                const u_trans_r = pos.dot(side.u.axis) / side.u.scale + side.u.trans - pos_r.dot(new_u_axis) / side.u.scale;
                const v_trans_r = pos.dot(side.v.axis) / side.v.scale + side.v.trans - pos_r.dot(new_v_axis) / side.v.scale;

                side.u.trans = u_trans_r;
                side.v.trans = v_trans_r;

                side.u.axis = new_u_axis;
                side.v.axis = new_v_axis;
            }
        }
        try self.markDirty(id, editor);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Editor) !void {
        for (self.sides.items) |side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            if (batch.*.contains.remove(id))
                batch.*.is_dirty = true;
        }
        _ = try editor.ecs.removeComponentOpt(id, .invalid);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn drawEdgeOutline(self: *Self, draw: *DrawCtx, vec: Vec3, param: struct {
        edge_size: f32 = 1,
        point_size: f32 = 1,
        edge_color: u32 = 0,
        point_color: u32 = 0,
    }) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(vec);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(vec);
                if (param.edge_color > 0)
                    draw.line3D(last, p, param.edge_color, param.edge_size);
                if (param.point_color > 0)
                    draw.point3D(p, param.point_color, param.point_size);
                last = p;
            }
        }
    }

    pub fn drawEdgeOutlineFast(self: *Self, line_batch: *graph.ImmediateDrawingContext.Line3DBatch, point_batch: *graph.ImmediateDrawingContext.Point3DBatch, offset: Vec3, edge_color: u32, point_color: u32) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(offset);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(offset);
                if (edge_color > 0)
                    graph.ImmediateDrawingContext.line3DBatch(line_batch, last, p, edge_color);
                if (point_color > 0)
                    graph.ImmediateDrawingContext.point3DBatch(point_batch, p, point_color);
                last = p;
            }
        }
    }

    pub fn getSidePtr(self: *Self, side_id: ?u32) ?*Side {
        if (side_id) |si| {
            if (si >= self.sides.items.len) return null;
            return &self.sides.items[si];
        }
        return null;
    }

    /// only_verts contains a list of vertex indices to apply offset to.
    /// If it is null, all vertices are offset
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Editor, offset: Vec3, only_verts: ?[]const u32, opts: struct { texture_lock: bool, invert_normal: bool = false }) !void {
        for (self.sides.items) |side| {
            if (side._omit_from_batch)
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try editor.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const ioffset = batch.vertices.items.len;
            const tw: f32 = @floatFromInt(side.tw);
            const th: f32 = @floatFromInt(side.th);
            for (side.index.items, 0..) |vi, i| {
                _ = i;
                const v = self.verts.items[vi];

                var off = offset;
                if (only_verts) |ov| {
                    if (std.mem.indexOfScalar(u32, ov, vi) == null)
                        off = Vec3.zero();
                }
                const pos = v.add(off);

                const upos = if (opts.texture_lock) v else pos;
                batch.appendVert(.{
                    .pos = .{
                        .x = pos.x(),
                        .y = pos.y(),
                        .z = pos.z(),
                    },
                    .uv = .{
                        .x = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                        .y = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset), opts.invert_normal);
            batch.appendIndex(indexs);
        }
    }

    //the vertexOffsetCb is given the vertex, the side_index, the index
    pub fn drawImmediateCustom(self: *Self, draw: *DrawCtx, ed: *Editor, user: anytype, vertOffsetCb: fn (@TypeOf(user), Vec3, u32, u32) Vec3, texture_lock: bool) !void {
        for (self.sides.items, 0..) |side, s_i| {
            if (side._omit_from_batch) //don't draw this sideit
                continue;
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try ed.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            const ioffset = batch.vertices.items.len;
            const tw: f32 = @floatFromInt(side.tw);
            const th: f32 = @floatFromInt(side.th);
            for (side.index.items, 0..) |vi, i| {
                const v = self.verts.items[vi];

                const off = vertOffsetCb(user, v, @intCast(s_i), @intCast(i));

                const pos = v.add(off);
                const upos = if (texture_lock) v else pos;
                batch.appendVert(.{
                    .pos = .{
                        .x = pos.x(),
                        .y = pos.y(),
                        .z = pos.z(),
                    },
                    .uv = .{
                        .x = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                        .y = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try ed.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset), false);
            batch.appendIndex(indexs);
        }
    }

    //wr must have print method
    pub fn print(solid: *const Self, wr: anytype) !void {
        try wr.print("Solid\n", .{});
        for (solid.verts.items, 0..) |vert, i| {
            try wr.print("  v {d} [{d:.1} {d:.1} {d:.1}]\n", .{ i, vert.x(), vert.y(), vert.z() });
        }
        for (solid.sides.items, 0..) |side, i| {
            try wr.print("  side {d}: ", .{i});
            for (side.index.items) |ind|
                try wr.print(" {d}", .{ind});
            try wr.print("\n", .{});
            const norm = side.normal(solid);
            try wr.print("  Normal: [{d} {d} {d}]\n", .{ norm.x(), norm.y(), norm.z() });
        }
    }

    /// Returns the number of verticies serialized
    pub fn printObj(self: *const Self, vert_offset: usize, name: []const u8, out: anytype) !usize {
        try out.print("o {s}\n", .{name});
        for (self.verts.items) |v|
            try out.print("v {d} {d} {d}\n", .{ v.x(), v.y(), v.z() });

        for (self.sides.items) |side| {
            try out.print("f", .{});
            for (side.index.items) |ind| {
                try out.print(" {d}", .{ind + 1 + vert_offset});
            }
            try out.print("\n", .{});
        }

        return self.verts.items.len;
    }
};

const ecs = @import("ecs.zig");
const EcsT = ecs.EcsT;
const graph = @import("graph");
const csg = @import("csg.zig");
const limits = @import("limits.zig");
const vmf = @import("vmf.zig");
const Vec3f64 = graph.za.Vec3_f64;
const AABB = ecs.AABB;
const Displacements = ecs.Displacements;
const Mat4 = graph.za.Mat4;
const DrawCtx = graph.ImmediateDrawingContext;
const Quat = graph.za.Quat;
const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const vpk = @import("vpk.zig");
const util3d = graph.util_3d;
const Vec3 = graph.za.Vec3;
const Editor = @import("editor.zig").Context;
