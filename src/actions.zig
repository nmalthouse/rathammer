/// Define editor actions
const std = @import("std");
const editor = @import("editor.zig");
const ecs = @import("ecs.zig");
const Undo = @import("undo.zig");
const Vec3 = graph.za.Vec3;
const graph = @import("graph");
const Ed = editor.Context;
const raycast = @import("raycast_solid.zig");
const async_util = @import("async.zig");
const RaycastSlice = []const raycast.RcastItem;
const vpk = @import("vpk.zig");
const util3d = @import("util_3d.zig");
const Lays = @import("layer.zig");
const LayerId = Lays.Id;
const colors = @import("colors.zig").colors;

pub fn deleteSelected(ed: *Ed) !void {
    const selection = ed.getSelected();
    const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .autovis_invisible });
    if (selection.len > 0) {
        const ustack = try ed.undoctx.pushNewFmt("deletion of {d} entities", .{selection.len});

        for (selection) |id| {
            if (ed.ecs.intersects(id, vis_mask))
                continue;
            try ustack.append(.{ .create_destroy = try .create(ustack.alloc, id, .destroy) });
        }
        const old_selection = try ed.selection.createStateSnapshot(ustack.alloc);
        ed.selection.list.clear();
        const new_selection = try ed.selection.createStateSnapshot(ustack.alloc);

        try ustack.append(.{ .selection = try .create(ustack.alloc, old_selection, new_selection) });
        ustack.apply(ed);
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
    ed.eventctx.pushEvent(.{ .undo = {} });
}

pub fn redo(ed: *Ed) void {
    ed.undoctx.redo(ed);
    ed.eventctx.pushEvent(.{ .redo = {} });
}

pub fn clearSelection(ed: *Ed) !void {
    const count = ed.selection.countSelected();
    if (count == 0)
        return;
    const ustack = try ed.undoctx.pushNewFmtOpts("clear selection of {d}", .{count}, .{ .soft_change = true });

    const old_selection = try ed.selection.createStateSnapshot(ustack.alloc);
    ed.selection.list.clear();
    const new_selection = try ed.selection.createStateSnapshot(ustack.alloc);

    try ustack.append(.{ .selection = try .create(ustack.alloc, old_selection, new_selection) });
}

pub fn selectId(ed: *Ed, id: editor.EcsT.Id) !void {
    _ = try ed.selection.put(id, ed);
}

pub fn trySave(ed: *Ed) !void {
    if (ed.loaded_map_name) |basename| {
        ed.saveAndNotify(basename, ed.loaded_map_path orelse "") catch |err| {
            ed.notify("Failed saving map: {t}", .{err}, colors.bad);
        };
    } else {
        try async_util.SdlFileData.spawn(ed.alloc, &ed.async_asset_load, .save_map);
    }
}

//TODO this is a quick and dirty implementation.
//Remove duplicate v and vt lines
//Write displacements
pub fn exportToObj(ed: *Ed, path: []const u8, name: []const u8) !void {
    const full_name = try std.fs.path.join(ed.frame_arena.allocator(), &.{ path, name });
    const header =
        \\# Obj exported from rathammer {[version]s}
        \\# map_name {[map_name]s}
        \\# map_version {[map_version]d}
        \\# map_uuid {[uuid]x}
        \\
    ;
    var write_buf: [4096]u8 = undefined;
    var output = try std.fs.cwd().createFile(full_name, .{});
    defer output.close();
    var writer = output.writer(&write_buf);
    const wr = &writer.interface;

    try wr.print(header, .{
        .version = @import("version.zig").version_string,
        .map_name = ed.loaded_map_name orelse "unnamed",
        .map_version = ed.edit_state.map_version,
        .uuid = ed.edit_state.map_uuid,
    });

    var vi: usize = 1;
    var vt_i: usize = 1;
    for (ed.ecs.entities.items, 0..) |ent, id| {
        if (ent.isSet(ecs.EcsT.Types.tombstone_bit))
            continue;
        if (ent.isSet(@intFromEnum(ecs.EcsT.Components.deleted)))
            continue;

        if (try ed.ecs.getOptPtr(@intCast(id), .displacements)) |disps| { //disp has higher priority, so dispsolid is omitted
            //TODO write the disp
            _ = disps;
        } else if (try ed.ecs.getOptPtr(@intCast(id), .solid)) |solid| {
            try wr.print("o solid_{d}\n", .{id});
            const v_offset = vi;
            for (solid.verts.items) |item| {
                vi += 1;
                try wr.print("v {d} {d} {d}\n", .{ item.x(), item.y(), item.z() });
            }
            for (solid.sides.items) |side| {
                { //face

                    if (try ed.vpkctx.resolveId(.{ .id = side.tex_id }, false)) |tex| {
                        try wr.print("usemtl {s}\n", .{tex.name});
                    } else {
                        //Fallback
                        try wr.print("usemtl {s}\n", .{side.material});
                    }
                }

                const tw: f32 = @floatFromInt(side.tw);
                const th: f32 = @floatFromInt(side.th);
                const vt_offset = vt_i;
                vt_i += side.index.items.len;
                for (side.index.items) |index| {
                    const upos = solid.verts.items[index];

                    const u = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw));
                    const v = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th));
                    try wr.print("vt {d} {d} \n", .{ @mod(u, 1.0), @mod(v, 1.0) });
                }

                try wr.writeByte('f');
                for (side.index.items, 0..) |index, i| {
                    try wr.print(" {d}/{d}", .{ index + v_offset, vt_offset + i });
                }
                try wr.writeByte('\n');
            }
        }
    }

    try wr.flush();
    ed.notify("Exported obj {s}/{s}", .{ path, name }, colors.good);
}

pub fn buildMap(ed: *Ed, do_user_script: bool) !void {
    const jsontovmf = @import("jsonToVmf.zig").jsontovmf;
    const lm = try ed.printArena("{s}.vmf", .{ed.loaded_map_name orelse "dump"});
    var build_arena = std.heap.ArenaAllocator.init(ed.alloc);
    defer build_arena.deinit();
    if (jsontovmf(
        build_arena.allocator(),
        &ed.ecs,
        ed.skybox.sky_name,
        &ed.vpkctx,
        &ed.groups,
        lm,
        .{ .check_solid = false },
    )) {
        ed.notify("Exported map to vmf", .{}, colors.good);

        try async_util.MapCompile.spawn(ed.alloc, &ed.async_asset_load, .{
            .vmf = lm,
            .gamedir_pre = ed.game_conf.mapbuilder.game_dir,
            .exedir_pre = ed.game_conf.mapbuilder.exe_dir,
            .gamename = ed.game_conf.mapbuilder.game_name,

            .outputdir = ed.game_conf.mapbuilder.output_dir,
            .cwd_path = ed.dirs.games_dir.path,
            .tmpdir = ed.game_conf.mapbuilder.tmp_dir,

            .user_cmd = ed.game_conf.mapbuilder.user_build_cmd,
        }, if (do_user_script) .user_script else .builtin);
    } else |err| {
        ed.notify("Failed exporting map to vmf {t}", .{err}, colors.bad);
    }
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
        ed.notify("{d} owned groups selected, merging!", .{owner_count}, 0xfca7_3fff);

    const ustack = try ed.undoctx.pushNewFmt("Grouping of {d} objects", .{selection.len});
    const group = if (last_owner) |lo| ed.groups.getGroup(lo) else null;
    var owner: ?ecs.EcsT.Id = null;
    if (last_owner == null) {
        if (ed.edit_state.default_group_entity != .none) {
            const group_origin = blk: {
                if (ed.getComponent(last, .bounding_box)) |bb| {
                    break :blk bb.b.add(bb.a).scale(0.5);
                }
                break :blk Vec3.zero();
            };

            const new = try ed.ecs.createEntity();
            var bb = ecs.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
            try ed.ecs.attach(new, .entity, .{
                .origin = group_origin,
                .class = @tagName(ed.edit_state.default_group_entity),
            });
            bb.setFromOrigin(group_origin);
            try ed.ecs.attach(new, .bounding_box, bb);
            try ed.ecs.attach(new, .layer, .{ .id = ed.edit_state.selected_layer });
            try ustack.append(.{ .create_destroy = try .create(ustack.alloc, new, .create) });
            owner = new;
        }
    }
    const new_group = if (group) |g| g else try ed.groups.newGroup(owner);
    if (owner) |o| try ed.selection.list.add(o, new_group);
    for (selection) |id| {
        const old = if (try ed.ecs.getOpt(id, .group)) |g| g.id else 0;
        try ustack.append(.{
            .change_group = try .create(ustack.alloc, old, new_group, id),
        });
    }
    ustack.apply(ed);
    ed.notify("Grouped {d} objects", .{selection.len}, 0x00ff00ff);
}

const pgen = @import("primitive_gen.zig");
const Primitive = pgen.Primitive;
pub fn createSolid(ed: *Ed, primitive: *const Primitive, tex_id: vpk.VpkResId, center: Vec3, rot: graph.za.Mat3, select: bool) ![]const ecs.EcsT.Id {
    const ustack = try ed.undoctx.pushNewFmt("draw cube", .{});
    const old_selection_state = if (select) try ed.selection.createStateSnapshot(ustack.alloc) else null;
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
                try ustack.append(.{ .create_destroy = try .create(ustack.alloc, new, .create) });
            }
        } else |a| {
            std.debug.print("Invalid cube {t}\n", .{a});
        }
    }

    if (select) {
        const new_state = try ed.selection.createStateSnapshot(ustack.alloc);
        const old = old_selection_state.?;

        try ustack.append(.{ .selection = try .create(ustack.alloc, old, new_state) });
    }

    ustack.apply(ed);

    return id_list.items;
}

pub fn createCube(ed: *Ed, pos: Vec3, ext: Vec3, tex_id: vpk.VpkResId, select: bool) !ecs.EcsT.Id {
    const prim = try pgen.cube(ed.frame_arena.allocator(), .{ .size = ext });

    const ids = try createSolid(ed, &prim, tex_id, pos, graph.za.Mat3.identity(), select);
    if (ids.len != 1) return error.horrible;

    return ids[0];
}

pub fn selectInBounds(ed: *Ed, bounds: [2]Vec3) !void {
    ed.selection.setToMulti();

    const GroupId = ecs.Groups.GroupId;
    const aa = ed.frame_arena.allocator();
    // This is needed otherwise when ignore_groups is false, group members are added/removed n times where n is the number of group members present in the bounds.
    var visited_groups = std.AutoHashMap(GroupId, void).init(aa);
    const track_groups = !ed.selection.ignore_groups;

    var it = ed.editIterator(.bounding_box);
    while (it.next()) |item| {
        if (util3d.doesBBOverlapExclusive(bounds[0], bounds[1], item.a, item.b)) {
            const group = if (try ed.ecs.getOpt(it.i, .group)) |g| g.id else 0;

            if (track_groups) {
                if (group == 0) {
                    _ = try ed.selection.put(it.i, ed);
                } else if (!visited_groups.contains(group)) {
                    const pr = try ed.selection.put(it.i, ed);
                    if (pr.res != .masked)
                        try visited_groups.put(group, {});
                }
            } else {
                _ = try ed.selection.put(it.i, ed);
            }
        }
    }

    if (track_groups) {
        // Ensure all group owners are put into the selection
        var git = visited_groups.keyIterator();
        while (git.next()) |gid| {
            if (ed.groups.getOwner(gid.*)) |owner|
                try ed.selection.list.add(owner, gid.*);
        }
    }
}

pub fn addSelectionToLayer(ed: *Ed, lay_id: LayerId) !void {
    const slice = ed.getSelected();
    if (slice.len > 0) {
        const lay = ed.layers.getLayerFromId(lay_id) orelse return;
        const ustack = try ed.undoctx.pushNewFmt("move {d} ent to '{s}'", .{ slice.len, lay.name });
        for (slice) |sel| {
            const old = if (ed.getComponent(sel, .layer)) |l| l.id else .none;
            try ustack.append(.{ .set_layer = try .create(ustack.alloc, sel, old, lay_id) });
        }
        ustack.apply(ed);
    }
}

pub fn createLayer(ed: *Ed, parent_layer: LayerId, layer_name: []const u8) !LayerId {
    if (ed.layers.newLayerUnattached(layer_name) catch null) |new_lay| {
        const ustack = try ed.undoctx.pushNewFmt("Create layer", .{});
        const parent = ed.layers.getLayerFromId(parent_layer) orelse return error.invalidParent;

        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, new_lay.id, parent_layer, parent.children.items.len, .attach) });
        ustack.apply(ed);
        return new_lay.id;
    }
    return error.failedLayerCreate;
}

pub fn deleteLayer(ed: *Ed, layer: LayerId) !LayerId {
    // mark each item in layer as deleted,

    const lay = ed.layers.getLayerFromId(layer) orelse return error.invalidLayer;
    if (ed.layers.getParent(ed.layers.root, layer)) |parent| {
        const ustack = try ed.undoctx.pushNewFmt("delete layer", .{});

        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, layer, parent[0].id, parent[1], .detach) });

        const aa = ed.frame_arena.allocator();
        const mask = (try ed.layers.gatherChildren(aa, lay))[0];

        var it = ed.editIterator(.layer);
        while (it.next()) |item| {
            if (mask.isSet(@intFromEnum(item.id))) {
                try ustack.append(.{ .create_destroy = try .create(ustack.alloc, it.i, .destroy) });
            }
        }

        ustack.apply(ed);
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
                mask.set(@intFromEnum(item.*));
        }

        const ustack = try ed.undoctx.pushNewFmt("Dupe layer {s}", .{current.name});
        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, new.id, parent[0].id, parent[1] + 1, .attach) });

        var it = ed.editIterator(.layer);
        while (it.next()) |item| {
            if (mask.isSet(@intFromEnum(item.id))) {
                const new_id = idmap.get(item.id) orelse continue;
                const duped = try ed.dupeEntity(it.i);
                ed.putComponent(duped, .layer, .{ .id = new_id });
                try ustack.append(.{ .create_destroy = try .create(ustack.alloc, duped, .create) });
            }
        }
        ustack.apply(ed);
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
        if (mask.isSet(@intFromEnum(item.id))) {
            try ustack.append(.{ .set_layer = try .create(ustack.alloc, it.i, item.id, target_id) });
        }
    }
    if (ed.layers.getParent(ed.layers.root, merge)) |parent| {
        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, merge, parent[0].id, parent[1], .detach) });
    }
    ustack.apply(ed);
}

pub fn moveLayer(ed: *Ed, moved_id: LayerId, new_parent_id: LayerId, sib_index: usize) !void {
    //verify sel_id is not a child of selected_ptr.*. (creates cycle)
    if (!ed.layers.isChildOf(moved_id, new_parent_id)) {
        const moved = ed.layers.getLayerFromId(moved_id) orelse return;
        const new_parent = ed.layers.getLayerFromId(new_parent_id) orelse return;

        const parent = ed.layers.getParent(ed.layers.root, moved.id) orelse return;
        const ustack = try ed.undoctx.pushNewFmt("Moved layer {s}", .{moved.name});
        //first detach, than reattach to new
        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, moved.id, parent[0].id, parent[1], .detach) });
        try ustack.append(.{ .attach_layer = try .create(ustack.alloc, moved.id, new_parent.id, sib_index, .attach) });
        ustack.apply(ed);
    }
}

pub const SelectedSide = struct {
    id: editor.EcsT.Id,
    side_i: u16,
};
pub fn translateFace(ed: *Ed, list: []const SelectedSide, dist: Vec3) !void {
    if (list.len == 0) return;
    const ustack = try ed.undoctx.pushNewFmt("translated {d} face{s}", .{ list.len, if (list.len > 1) "s" else "" });
    for (list) |li| {
        try ustack.append(.{ .face_translate = try .create(
            ustack.alloc,
            li.id,
            li.side_i,
            dist,
        ) });
    }
    ustack.apply(ed);
}

pub fn createEntity(ed: *Ed, new: editor.EcsT.Id) !void {
    const ustack = try ed.undoctx.pushNewFmt("create entity", .{});
    try ustack.append(.{ .create_destroy = try .create(ustack.alloc, new, .create) });
    ustack.apply(ed);
}

pub fn clipSelected(ed: *Ed, points: [3]Vec3) !void {
    const p0 = points[0];
    const p1 = points[1];
    const p2 = points[2];
    const pnorm = util3d.trianglePlane(.{ p0, p1, p2 }).norm();

    const selected = ed.getSelected();
    const ustack = try ed.undoctx.pushNewFmt("Clip", .{});
    for (selected) |sel_id| {
        const solid = ed.getComponent(sel_id, .solid) orelse continue;
        var ret = try ed.clipctx.clipSolid(solid, p0, pnorm, ed.edit_state.selected_texture_vpk_id);

        ed.selection.list.clear();
        try ustack.append(.{ .create_destroy = try .create(ustack.alloc, sel_id, .destroy) });

        for (&ret) |*r| {
            if (r.sides.items.len < 4) { //TODO more extensive check of validity
                r.deinit();
                continue;
            }
            const new = try ed.ecs.createEntity();
            try ustack.append(.{ .create_destroy = try .create(ustack.alloc, new, .create) });
            try ed.ecs.attach(new, .solid, r.*);
            try ed.ecs.attach(new, .bounding_box, .{});
            try ed.ecs.attach(new, .layer, .{ .id = ed.edit_state.selected_layer });
            const solid_ptr = try ed.ecs.getPtr(new, .solid);
            try solid_ptr.translate(new, Vec3.zero(), ed, Vec3.zero(), null);
        }
    }
    ustack.apply(ed);
}

pub fn rotateTranslateSelected(ed: *Ed, dupe: bool, angle_delta: ?Vec3, origin: Vec3, dist: Vec3) !void {
    const selected = ed.getSelected();
    const aa = ed.frame_arena.allocator();
    var new_ent_list = std.ArrayList(ecs.EcsT.Id){};
    //Map old groups to duped groups
    var group_mapper = std.AutoHashMap(ecs.Groups.GroupId, ecs.Groups.GroupId).init(ed.frame_arena.allocator());

    const ustack = try ed.undoctx.pushNewFmt("{s} of {d} entities", .{ if (dupe) "Dupe" else "Translation", selected.len });
    for (selected) |id| {
        if (dupe) {
            if (ed.groups.getGroup(id)) |_| {
                // We do not ever duplicate owner entities as it isn't clear what should happen.
                // When ignore_groups is false, new groups are created and their owners are
                // explicitly duped below.
                continue;
            }
            const duped = try ed.dupeEntity(id);

            try ustack.append(.{ .create_destroy = try .create(ustack.alloc, duped, .create) });
            try ustack.append(.{ .translate = try .create(
                ustack.alloc,
                dist,
                angle_delta,
                duped,
                origin,
            ) });
            if (!ed.selection.ignore_groups) {
                if (try ed.ecs.getOpt(duped, .group)) |group| {
                    if (group.id != ecs.Groups.NO_GROUP) {
                        if (!group_mapper.contains(group.id)) {
                            try group_mapper.put(group.id, try ed.groups.newGroup(null));
                        }
                        try new_ent_list.append(aa, duped);
                    }
                }
            }
        } else {
            try ustack.append(.{ .translate = try .create(
                ustack.alloc,
                dist,
                angle_delta,
                id,
                origin,
            ) });
        }
    }
    if (dupe) {
        var it = group_mapper.iterator();
        while (it.next()) |item| {
            if (ed.groups.getOwner(item.key_ptr.*)) |owner| {
                const duped = try ed.dupeEntity(owner);

                Undo.UndoTranslate.applyTransRot(
                    ed,
                    duped,
                    dist,
                    angle_delta,
                    origin,
                    1,
                );

                try ustack.append(.{ .create_destroy = try .create(ustack.alloc, duped, .create) });
                try ed.groups.setOwner(item.value_ptr.*, duped);
                //TODO set the group owner with undo stack
            }
        }
        for (new_ent_list.items) |new_ent| {
            const old_group = try ed.ecs.get(new_ent, .group);
            const new_group = group_mapper.get(old_group.id) orelse continue;
            try ustack.append(.{
                .change_group = try .create(ustack.alloc, old_group.id, new_group, new_ent),
            });
        }
        //now iterate the new_ent_list and update the group mapping
    }
    ustack.apply(ed);
}

const TexState = Undo.UndoTextureManip.State;
pub fn manipTexture(ed: *Ed, old: TexState, new: TexState, side: SelectedSide) !void {
    const ustack = try ed.undoctx.pushNewFmt("texture manip", .{});
    try ustack.append(.{ .texture_manip = try .create(ustack.alloc, old, new, side.id, side.side_i) });
    ustack.apply(ed);
}

pub fn applyTextureToSelection(ed: *Ed, tex_id: vpk.VpkResId) !void {
    const selection = ed.getSelected();
    const ustack = try ed.undoctx.pushNewFmt("texture apply", .{});
    for (selection) |sel_id| {
        if (ed.getComponent(sel_id, .solid)) |solid| {
            for (solid.sides.items, 0..) |*sp, side_id| {
                const old_s = Undo.UndoTextureManip.State{ .u = sp.u, .v = sp.v, .tex_id = sp.tex_id, .lightmapscale = sp.lightmapscale, .smoothing_groups = sp.smoothing_groups };
                var new_s = old_s;
                new_s.tex_id = tex_id;
                try ustack.append(.{ .texture_manip = try .create(ustack.alloc, old_s, new_s, sel_id, @intCast(side_id)) });
            }
        }
    }
    ustack.apply(ed);
}
