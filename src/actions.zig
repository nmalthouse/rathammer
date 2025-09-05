/// Define editor actions
const std = @import("std");
const editor = @import("editor.zig");
const ecs = @import("ecs.zig");
const Undo = @import("undo.zig");
const Vec3 = graph.za.Vec3;
const graph = @import("graph");
const Ed = editor.Context;
const raycast = @import("raycast_solid.zig");
const RaycastSlice = []const raycast.RcastItem;
const vpk = @import("vpk.zig");

pub fn deleteSelected(ed: *Ed) !void {
    const selection = ed.selection.getSlice();
    const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .autovis_invisible });
    if (selection.len > 0) {
        const ustack = try ed.undoctx.pushNewFmt("deletion of {d} entities", .{selection.len});
        for (selection) |id| {
            if (ed.ecs.intersects(id, vis_mask))
                continue;
            try ustack.append(try Undo.UndoCreateDestroy.create(ed.undoctx.alloc, id, .destroy));
        }
        Undo.applyRedo(ustack.items, ed);
        ed.selection.clear();
    }
}

pub fn hideSelected(ed: *Ed) !void {
    const selected = ed.selection.getSlice();
    for (selected) |sel| {
        if (!(ed.ecs.hasComponent(sel, .invisible) catch continue)) {
            ed.edit_state.manual_hidden_count += 1;
            if (ed.getComponent(sel, .solid)) |solid| {
                try solid.removeFromMeshMap(sel, ed);
            }
            ed.ecs.attachComponent(sel, .invisible, .{}) catch continue;
        } else {
            if (ed.edit_state.manual_hidden_count > 0) { //sanity check
                ed.edit_state.manual_hidden_count -= 1;
            }

            _ = ed.ecs.removeComponent(sel, .invisible) catch continue;
            if (ed.getComponent(sel, .solid)) |solid| {
                try solid.rebuild(sel, ed);
            }
        }
    }
}

pub fn unhideAll(ed: *Ed) !void {
    try ed.rebuildVisGroups();
    ed.edit_state.manual_hidden_count = 0;
}

pub fn undo(ed: *Ed) void {
    ed.undoctx.undo(ed);
}

pub fn redo(ed: *Ed) void {
    ed.undoctx.redo(ed);
}

pub fn selectId(ed: *Ed, id: editor.EcsT.Id) !void {
    _ = try ed.selection.put(id, ed);
}

pub fn selectRaycast(ed: *Ed, screen_area: graph.Rect, view: graph.za.Mat4) !void {
    const pot = ed.screenRay(screen_area, view);
    var starting_point: ?Vec3 = null;
    if (pot.len > 0) {
        for (pot) |p| {
            if (starting_point) |sp| {
                const dist = sp.distance(p.point);
                if (dist > ed.selection.options.nearby_distance) break;
            }
            if (try ed.selection.put(p.id, ed)) {
                if (starting_point == null) starting_point = p.point;
                if (ed.selection.options.select_nearby) {
                    continue;
                }
                break;
            }
        }
    }
}

pub fn groupSelection(ed: *Ed) !void {
    var kit = ed.selection.groups.keyIterator();
    var owner_count: usize = 0;
    var last_owner: ?editor.EcsT.Id = null;
    while (kit.next()) |group| {
        if (ed.groups.getOwner(group.*)) |own| {
            owner_count += 1;
            last_owner = own;
        }
    }

    const selection = ed.selection.getSlice();

    if (owner_count > 1)
        try ed.notify("{d} owned groups selected, merging!", .{owner_count}, 0xfca7_3fff);

    if (selection.len > 0) {
        const ustack = try ed.undoctx.pushNewFmt("Grouping of {d} objects", .{selection.len});
        const group = if (last_owner) |lo| ed.groups.getGroup(lo) else null;
        var owner: ?ecs.EcsT.Id = null;
        if (last_owner == null) {
            if (ed.edit_state.default_group_entity != .none) {
                const new = try ed.ecs.createEntity();
                try ed.ecs.attach(new, .entity, .{
                    .class = @tagName(ed.edit_state.default_group_entity),
                });
                owner = new;
            }
        }
        const new_group = if (group) |g| g else try ed.groups.newGroup(owner);
        for (selection) |id| {
            const old = if (try ed.ecs.getOpt(id, .group)) |g| g.id else 0;
            try ustack.append(
                try Undo.UndoChangeGroup.create(ed.undoctx.alloc, old, new_group, id),
            );
        }
        Undo.applyRedo(ustack.items, ed);
        try ed.notify("Grouped {d} objects", .{selection.len}, 0x00ff00ff);
    }
}

const pgen = @import("primitive_gen.zig");
const Primitive = pgen.Primitive;
pub fn createSolid(ed: *Ed, primitive: *const Primitive, tex_id: vpk.VpkResId, center: Vec3, rot: graph.za.Mat3, select: bool) ![]const ecs.EcsT.Id {
    const ustack = try ed.undoctx.pushNewFmt("draw cube", .{});
    defer Undo.applyRedo(ustack.items, ed);
    if (select) {
        ed.selection.clear();
        ed.selection.mode = .many;
    }
    const aa = ed.frame_arena.allocator();
    var id_list = std.ArrayListUnmanaged(ecs.EcsT.Id){};
    for (primitive.solids.items) |sol| {
        if (ecs.Solid.initFromPrimitive(ed.alloc, primitive.verts.items, sol.items, tex_id, center, rot)) |newsolid| {
            const new = try ed.ecs.createEntity();
            try id_list.append(aa, new);
            if (select) {
                _ = try ed.selection.put(new, ed);
            }
            try ed.ecs.attach(new, .solid, newsolid);
            try ed.ecs.attach(new, .bounding_box, .{});
            try ed.ecs.attach(new, .layer, .{ .id = ed.edit_state.selected_layer });
            const solid_ptr = try ed.ecs.getPtr(new, .solid);
            try solid_ptr.translate(new, Vec3.zero(), ed, Vec3.zero(), null);
            {
                try ustack.append(try Undo.UndoCreateDestroy.create(ed.undoctx.alloc, new, .create));
            }
        } else |a| {
            std.debug.print("Invalid cube {!}\n", .{a});
        }
    }
    return id_list.items;
}

pub fn createCube(ed: *Ed, pos: Vec3, ext: Vec3, tex_id: vpk.VpkResId, select: bool) !ecs.EcsT.Id {
    const prim = try pgen.cube(ed.frame_arena.allocator(), .{ .size = ext });

    const ids = try createSolid(ed, &prim, tex_id, pos, graph.za.Mat3.identity(), select);
    if (ids.len != 1) return error.horrible;

    return ids[0];
}

pub fn clearSelection(ed: *Ed) void {
    ed.selection.clear();
}
