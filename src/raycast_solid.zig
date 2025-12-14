const std = @import("std");
const util3d = graph.util_3d;
const graph = @import("graph");
const edit = @import("editor.zig");
const Vec3 = graph.za.Vec3;
const csg = @import("csg.zig");
const ecs = @import("ecs.zig");

const RaycastResult = struct {
    point: Vec3,
    side_index: usize,
};
threadlocal var RAYCAST_RESULT_BUFFER: [2]RaycastResult = undefined;
pub fn doesRayIntersectSolid(r_o: Vec3, r_d: Vec3, solid: *const ecs.Solid, csgctx: *csg.Context) ![]const RaycastResult {
    var count: usize = 0;
    for (solid.sides.items, 0..) |side, s_i| {
        if (side.index.items.len < 3) continue;
        // triangulate using csg
        //Indexs into side.index
        const ind = try csgctx.triangulateIndex(@intCast(side.index.items.len), 0);
        const ts = solid.verts.items;
        const sindex = side.index.items;
        for (0..@divExact(ind.len, 3)) |i_i| {
            const i = i_i * 3;

            if (util3d.mollerTrumboreIntersection(
                r_o,
                r_d,
                ts[sindex[ind[i]]],
                ts[sindex[ind[i + 1]]],
                ts[sindex[ind[i + 2]]],
            )) |inter| {
                count += 1;
                if (count > 2)
                    return error.invalidSolid;
                RAYCAST_RESULT_BUFFER[count - 1] = .{ .point = inter, .side_index = s_i };

                //return .{ .point = inter, .side_index = s_i };
            }
        }
    }
    if (count == 2) { //Manually sort by distance
        const d1 = RAYCAST_RESULT_BUFFER[0].point.distance(r_o);
        const d2 = RAYCAST_RESULT_BUFFER[1].point.distance(r_o);
        if (d1 > d2)
            std.mem.swap(RaycastResult, &RAYCAST_RESULT_BUFFER[0], &RAYCAST_RESULT_BUFFER[1]);
    }
    return RAYCAST_RESULT_BUFFER[0..count];
}

pub const RcastItem = struct {
    id: edit.EcsT.Id,
    side_id: ?u32 = null,
    dist: f32,
    point: graph.za.Vec3 = undefined,

    pub fn lessThan(_: void, a: @This(), b: @This()) bool {
        return a.dist < b.dist;
    }
};

pub const Ctx = struct {
    const Self = @This();
    pot: std.ArrayList(RcastItem) = .{},
    pot_fine: std.ArrayList(RcastItem) = .{},
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pot.deinit(self.alloc);
        self.pot_fine.deinit(self.alloc);
    }

    pub fn findNearestSolid(self: *Self, ecs_p: *edit.EcsT, ray_o: Vec3, ray_d: Vec3, csgctx: *csg.Context, bb_only: bool) ![]const RcastItem {
        const vis_mask = edit.EcsT.getComponentMask(&.{ .invisible, .deleted, .autovis_invisible });
        //var rcast_timer = try std.time.Timer.start();
        //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
        self.pot.clearRetainingCapacity();
        var bbit = ecs_p.iterator(.bounding_box);
        while (bbit.next()) |bb| {
            if (ecs_p.intersects(bbit.i, vis_mask))
                continue;
            if (util3d.doesRayIntersectBBZ(ray_o, ray_d, bb.a, bb.b)) |inter| {
                const len = inter.distance(ray_o);
                try self.pot.append(self.alloc, .{ .id = bbit.i, .dist = len, .side_id = null });
            }
        }
        if (!bb_only) {
            self.pot_fine.clearRetainingCapacity();
            for (self.pot.items) |bp_rc| {
                if (try ecs_p.getOptPtr(bp_rc.id, .solid)) |solid| {
                    for (try doesRayIntersectSolid(ray_o, ray_d, solid, csgctx)) |in| {
                        const len = in.point.distance(ray_o);
                        try self.pot_fine.append(self.alloc, .{ .id = bp_rc.id, .dist = len, .point = in.point, .side_id = @intCast(in.side_index) });
                    }
                } else {
                    try self.pot_fine.append(self.alloc, bp_rc);
                }
            }

            std.sort.insertion(RcastItem, self.pot_fine.items, {}, RcastItem.lessThan);
            return self.pot_fine.items;
        }
        std.sort.insertion(RcastItem, self.pot.items, {}, RcastItem.lessThan);
        return self.pot.items;
    }

    pub fn reset(self: *Self) void {
        self.pot_fine.clearRetainingCapacity();
    }

    pub fn addPotentialSolid(self: *Self, ecs_p: *edit.EcsT, ray_o: Vec3, ray_d: Vec3, csgctx: *csg.Context, pot_id: edit.EcsT.Id) !void {
        if (try ecs_p.getOptPtr(pot_id, .solid)) |solid| {
            for (try doesRayIntersectSolid(ray_o, ray_d, solid, csgctx)) |in| {
                const len = in.point.distance(ray_o);
                try self.pot_fine.append(self.alloc, .{ .id = pot_id, .dist = len, .point = in.point, .side_id = @intCast(in.side_index) });
            }
        }
    }

    pub fn sortFine(self: *Self) []const RcastItem {
        std.sort.insertion(RcastItem, self.pot_fine.items, {}, RcastItem.lessThan);
        return self.pot_fine.items;
    }
};
