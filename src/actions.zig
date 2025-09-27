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
const util3d = @import("util_3d.zig");
const Lays = @import("layer.zig");
const LayerId = Lays.Id;

pub fn deleteSelected(ed: *Ed) !void {
    const selection = ed.getSelected();
    const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .autovis_invisible });
    if (selection.len > 0) {
        const ustack = try ed.undoctx.pushNewFmt("deletion of {d} entities", .{selection.len});

        for (selection) |id| {
            if (ed.ecs.intersects(id, vis_mask))
                continue;
            try ustack.append(try Undo.UndoCreateDestroy.create(ed.undoctx.alloc, id, .destroy));
        }
        const old_selection = try ed.selection.createStateSnapshot(ed.undoctx.alloc);
        ed.selection.list.clear();
        const new_selection = try ed.selection.createStateSnapshot(ed.undoctx.alloc);

        try ustack.append(try Undo.SelectionUndo.create(ed.undoctx.alloc, old_selection, new_selection));
        Undo.applyRedo(ustack.items, ed);
    }
}

//TODO this is actually "toggle hide"
//Decide on rules for
pub fn hideSelected(ed: *Ed) !void {
    const selected = ed.getSelected();
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
            const putresult = try ed.selection.put(p.id, ed);
            if (putresult.res != .masked) {
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
    const selection = ed.getSelected();

    if (selection.len == 0) return;
    const last = ed.selection.list.getLast() orelse return;
    const owner_count = ed.selection.list.countGroup();
    const last_owner = ed.groups.getOwner(ed.selection.list.getGroup(last) orelse return) orelse null;

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
    const old_selection_state = if (select) try ed.selection.createStateSnapshot(ed.undoctx.alloc) else null;
    if (select) {
        ed.selection.list.clear();
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

    if (select) {
        const new_state = try ed.selection.createStateSnapshot(ed.undoctx.alloc);
        const old = old_selection_state.?;

        try ustack.append(try Undo.SelectionUndo.create(ed.undoctx.alloc, old, new_state));
    }

    Undo.applyRedo(ustack.items, ed);

    return id_list.items;
}

pub fn createCube(ed: *Ed, pos: Vec3, ext: Vec3, tex_id: vpk.VpkResId, select: bool) !ecs.EcsT.Id {
    const prim = try pgen.cube(ed.frame_arena.allocator(), .{ .size = ext });

    const ids = try createSolid(ed, &prim, tex_id, pos, graph.za.Mat3.identity(), select);
    if (ids.len != 1) return error.horrible;

    return ids[0];
}

pub fn clearSelection(ed: *Ed) !void {
    const count = ed.selection.countSelected();
    if (count == 0)
        return;
    const ustack = try ed.undoctx.pushNewFmtOpts("clear selection of {d}", .{count}, .{ .soft_change = true });

    const old_selection = try ed.selection.createStateSnapshot(ed.undoctx.alloc);
    ed.selection.list.clear();
    const new_selection = try ed.selection.createStateSnapshot(ed.undoctx.alloc);

    try ustack.append(try Undo.SelectionUndo.create(ed.undoctx.alloc, old_selection, new_selection));
}

pub fn selectInBounds(ed: *Ed, bounds: [2]Vec3) !void {
    //IF ignore groups is on, just add everything normally
    //Otherwise, track which groups have been touched and only add/remove them once
    //Second put?
    //
    //ignore groups is off:
    //IF ent group not in groups
    // const added = selection.put
    // for( item in group) if (added) add else remove
    //else skip

    ed.selection.setToMulti();

    const GroupId = ecs.Groups.GroupId;
    // true is added, false removed
    var visted_groups = std.AutoHashMap(GroupId, bool).init(ed.frame_arena.allocator());
    const track_groups = !ed.selection.ignore_groups;

    var it = ed.editIterator(.bounding_box);
    while (it.next()) |item| {
        if (util3d.doesBBOverlapExclusive(bounds[0], bounds[1], item.a, item.b)) {
            const pr = ed.selection.put(it.i, ed) catch return;
            if (track_groups) {
                if (pr.res != .masked and pr.group != 0) {
                    const res = try visted_groups.getOrPut(pr.group);
                    if (!res.found_existing) { //The status of the first grouped entity determines direction of selection.
                        res.value_ptr.* = pr.res == .added;
                    }
                }
            }
        }
    }

    //Iterate visited groups
    // for visted if added ensure all of group in selection
    // else ensure none of group in selection
}

pub fn addSelectionToLayer(ed: *Ed, lay_id: LayerId) !void {
    const slice = ed.getSelected();
    if (slice.len > 0) {
        const lay = ed.layers.getLayerFromId(lay_id) orelse return;
        const ustack = try ed.undoctx.pushNewFmt("move {d} ent to '{s}'", .{ slice.len, lay.name });
        for (slice) |sel| {
            const old = if (ed.getComponent(sel, .layer)) |l| l.id else 0;
            try ustack.append(try Undo.UndoSetLayer.create(ed.undoctx.alloc, sel, old, lay_id));
        }
        Undo.applyRedo(ustack.items, ed);
    }
}

pub fn createLayer(ed: *Ed, parent_layer: LayerId, layer_name: []const u8) !LayerId {
    if (ed.layers.newLayerUnattached(layer_name) catch null) |new_lay| {
        const ustack = try ed.undoctx.pushNewFmt("Create layer", .{});
        const parent = ed.layers.getLayerFromId(parent_layer) orelse return error.invalidParent;

        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, new_lay.id, parent_layer, parent.children.items.len, .attach));
        Undo.applyRedo(ustack.items, ed);
        return new_lay.id;
    }
    return error.failedLayerCreate;
}

pub fn deleteLayer(ed: *Ed, layer: LayerId) !LayerId {
    // mark each item in layer as deleted,

    const lay = ed.layers.getLayerFromId(layer) orelse return error.invalidLayer;
    if (ed.layers.getParent(ed.layers.root, layer)) |parent| {
        const ustack = try ed.undoctx.pushNewFmt("delete layer", .{});

        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, layer, parent[0].id, parent[1], .detach));

        const aa = ed.frame_arena.allocator();
        const mask = (try ed.layers.gatherChildren(aa, lay))[0];

        var it = ed.editIterator(.layer);
        while (it.next()) |item| {
            if (mask.isSet(item.id)) {
                try ustack.append(try Undo.UndoCreateDestroy.create(ed.undoctx.alloc, it.i, .destroy));
            }
        }

        Undo.applyRedo(ustack.items, ed);
        if (parent[1] == 0) return parent[0].id;
        return parent[0].children.items[parent[1] - 1].id;
    }
    return error.invalidParent;
}

pub fn dupeLayer(ed: *Ed, layer: LayerId) !void {
    const H = struct {
        const Map = std.AutoHashMap(LayerId, LayerId);
        fn genNewLayer(lays: *Lays.Context, old: *const Lays.Layer, idmap: *Map, name: ?[]const u8) !*Lays.Layer {
            const new = try lays.newLayerUnattached(name orelse old.name);
            try idmap.put(old.id, new.id);
            for (old.children.items) |child| {
                try new.children.append(lays.alloc, try genNewLayer(lays, child, idmap, null));
            }

            return new;
        }
    };
    const layers = &ed.layers;
    const current = layers.getLayerFromId(layer) orelse return;

    const aa = ed.frame_arena.allocator();

    if (layers.getParent(layers.root, layer)) |parent| {
        var idmap = H.Map.init(aa);
        const new_name = try ed.printScratch("{s}_dupe", .{current.name});
        const new = try H.genNewLayer(layers, current, &idmap, new_name);
        var mask = try std.DynamicBitSetUnmanaged.initEmpty(aa, layers.layer_counter + 1);
        {
            var it = idmap.keyIterator();
            while (it.next()) |item|
                mask.set(item.*);
        }

        const ustack = try ed.undoctx.pushNewFmt("Dupe layer {s}", .{current.name});
        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, new.id, parent[0].id, parent[1] + 1, .attach));

        var it = ed.editIterator(.layer);
        while (it.next()) |item| {
            if (mask.isSet(item.id)) {
                const new_id = idmap.get(item.id) orelse continue;
                const duped = try ed.dupeEntity(it.i);
                ed.putComponent(duped, .layer, .{ .id = new_id });
                try ustack.append(try Undo.UndoCreateDestroy.create(ed.undoctx.alloc, duped, .create));
            }
        }
        Undo.applyRedo(ustack.items, ed);
    }
}

pub fn mergeLayer(ed: *Ed, merge: LayerId, target_id: LayerId) !void {
    // put undo set layer on all matching merge, delete merge;

    const to_merge = ed.layers.getLayerFromId(merge) orelse return;
    const target = ed.layers.getLayerFromId(target_id) orelse return;

    const aa = ed.frame_arena.allocator();
    const mask = (try ed.layers.gatherChildren(aa, to_merge))[0];

    const ustack = try ed.undoctx.pushNewFmt("Merge layer {s} into {s}", .{ to_merge.name, target.name });
    var it = ed.editIterator(.layer);
    while (it.next()) |item| {
        if (mask.isSet(item.id)) {
            try ustack.append(try Undo.UndoSetLayer.create(ed.undoctx.alloc, it.i, item.id, target_id));
        }
    }
    if (ed.layers.getParent(ed.layers.root, merge)) |parent| {
        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, merge, parent[0].id, parent[1], .detach));
    }
    Undo.applyRedo(ustack.items, ed);
}

pub fn moveLayer(ed: *Ed, moved_id: LayerId, new_parent_id: LayerId, sib_index: usize) !void {
    //verify sel_id is not a child of selected_ptr.*. (creates cycle)
    if (!ed.layers.isChildOf(moved_id, new_parent_id)) {
        const moved = ed.layers.getLayerFromId(moved_id) orelse return;
        const new_parent = ed.layers.getLayerFromId(new_parent_id) orelse return;

        const parent = ed.layers.getParent(ed.layers.root, moved.id) orelse return;
        const ustack = try ed.undoctx.pushNewFmt("Moved layer {s}", .{moved.name});
        //first detach, than reattach to new
        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, moved.id, parent[0].id, parent[1], .detach));
        try ustack.append(try Undo.UndoAttachLayer.create(ed.undoctx.alloc, moved.id, new_parent.id, sib_index, .attach));
        Undo.applyRedo(ustack.items, ed);
    }
}
