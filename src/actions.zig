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
const util3d = graph.util_3d;
const Lays = @import("layer.zig");
const LayerId = Lays.Id;
const colors = @import("colors.zig").colors;
const L = @import("locale.zig");

pub fn deleteSelected(ed: *Ed) !void {
    const selection = ed.getSelected();
    const vis_mask = ecs.EcsT.getComponentMask(&.{ .invisible, .autovis_invisible });
    if (selection.len > 0) {
        const ustack = try ed.undoctx.pushNewFmt("{s} n={d}", .{ L.lang.undo.deletion, selection.len });

        for (selection) |id| {
            if (ed.ecs.intersects(id, vis_mask))
                continue;
            try ustack.append(.{ .create_destroy = try .create(ustack.alloc, id, .destroy) });
        }
        const old_selection = try ed.selection.createStateSnapshot(ustack.alloc);
        ed.selection.clear();
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
                try solid.markDirty(sel, ed);
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
    const ustack = try ed.undoctx.pushNewFmtOpts("{s} {d}", .{ L.lang.undo.clear_selection, count }, .{ .soft_change = true });

    const old_selection = try ed.selection.createStateSnapshot(ustack.alloc);
    ed.selection.clear();
    const new_selection = try ed.selection.createStateSnapshot(ustack.alloc);

    try ustack.append(.{ .selection = try .create(ustack.alloc, old_selection, new_selection) });
}

pub fn selectId(ed: *Ed, id: editor.EcsT.Id) !void {
    _ = try ed.selection.put(id, ed);
}

pub fn unloadMap(ed: *Ed) !void {
    //TODO should we nag on unsaved?

    ed.has_loaded_map = false;

    var it = ed.meshmap.iterator();
    while (it.next()) |item| {
        item.value_ptr.*.deinit();
        ed.alloc.destroy(item.value_ptr.*);
    }
    ed.meshmap.clearAndFree();

    try ed.ecs.destroyAll();
    ed.groups.reset();
    ed.undoctx.reset();
    try ed.layers.reset();

    ed.classtrack.reset();
    ed.targetname_track.reset();
    ed.draw_state.skybox_textures = null;
    ed.selection.clear();
    ed.paused = true;

    //delete skybox from draw_state
    //unload games
    //unload textures
    //unload models
    //unload fgd
    //clear asset_browser?
    //reset autovis
    //reset tools?
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

pub fn exportToObj(ed: *Ed, path: []const u8, name: []const u8) !void {
    const VecMap = @import("csg.zig").VecMap;
    const Help = struct {
        alloc: std.mem.Allocator,
        current_mtl: std.ArrayList(u8) = .{},
        out_wr: *std.io.Writer,
        const max_dist = 0.0001;
        // prefer whole numbers as they take up less bytes
        fn roundObjVert(vert: f32) f32 {
            const rounded = @round(vert);

            if (@abs(rounded - vert) < max_dist)
                return rounded;
            return vert;
        }

        fn emitVertex(vert: Vec3, lut: *std.ArrayList(u32), map: *VecMap, out: *std.io.Writer, alloc: std.mem.Allocator, prefix: []const u8, comptime count: usize) !void {
            const has = map.map.contains(vert);
            try lut.append(alloc, try map.put(vert));
            if (!has) {
                try out.print("{s}", .{prefix});
                for (0..count) |ci| {
                    try out.print(" {d}", .{roundObjVert(vert.data[ci])});
                }
                try out.print("\n", .{});
            }
        }

        fn emitMtl(self: *@This(), mtl: []const u8) !void {
            if (!std.mem.eql(u8, mtl, self.current_mtl.items)) {
                self.current_mtl.clearRetainingCapacity();
                try self.current_mtl.appendSlice(self.alloc, mtl);
                try self.out_wr.print("usemtl {s}\n", .{mtl});
            }
        }
    };
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
    var help: Help = .{
        .out_wr = wr,
        .alloc = ed.alloc,
    };
    defer {
        help.current_mtl.deinit(help.alloc);
    }

    try wr.print(header, .{
        .version = @import("version.zig").version_string,
        .map_name = ed.loaded_map_name orelse "unnamed",
        .map_version = ed.edit_state.map_version,
        .uuid = ed.edit_state.map_uuid,
    });

    var norm_lut = std.ArrayList(u32){};
    defer norm_lut.deinit(ed.alloc);
    var norm_map = VecMap.init(ed.alloc);
    defer norm_map.deinit();

    var vert_lut = std.ArrayList(u32){};
    defer vert_lut.deinit(ed.alloc);
    var vert_map = VecMap.init(ed.alloc);
    defer vert_map.deinit();

    var uv_lut = std.ArrayList(u32){};
    defer uv_lut.deinit(ed.alloc);
    var uv_map = VecMap.init(ed.alloc);
    defer uv_map.deinit();

    for (ed.ecs.entities.items, 0..) |ent, id| {
        if (ent.isSet(ecs.EcsT.Types.tombstone_bit))
            continue;
        if (ent.isSet(@intFromEnum(ecs.EcsT.Components.deleted)))
            continue;
        if (try ed.ecs.getOptPtr(@intCast(id), .layer)) |layer|
            if (ed.layers.isOmit(layer.id)) continue;

        if (try ed.ecs.getOptPtr(@intCast(id), .displacements)) |disps| { //disp has higher priority, so dispsolid is omitted
            const solid = try ed.ecs.getOptPtr(@intCast(id), .solid) orelse continue;
            try wr.print("o disp_{d}\n", .{id});
            for (disps.disps.items) |disp| {
                vert_lut.clearRetainingCapacity();
                norm_lut.clearRetainingCapacity();
                uv_lut.clearRetainingCapacity();

                for (disp._verts.items) |vert| {
                    try Help.emitVertex(vert, &vert_lut, &vert_map, wr, ed.alloc, "v", 3);
                }
                for (disp.normals.items) |norm| {
                    try Help.emitVertex(norm, &norm_lut, &norm_map, wr, ed.alloc, "vn", 3);
                }

                {
                    const tex = try ed.getTexture(disp.tex_id);
                    const side = &solid.sides.items[disp.parent_side_i];
                    try help.emitMtl(
                        if (try ed.vpkctx.resolveId(.{ .id = side.tex_id }, false)) |texi| texi.name else side.material,
                    );
                    const uvs = try ed.csgctx.calcUVCoordsIndexed(solid.verts.items, side.index.items, side.*, @intCast(tex.w), @intCast(tex.h), Vec3.zero(), null);
                    const si = disp.vert_start_i;
                    const uv0 = uvs[si % 4];
                    const uv1 = uvs[(si + 1) % 4];
                    const uv2 = uvs[(si + 2) % 4];
                    const uv3 = uvs[(si + 3) % 4];

                    const vper_row = ecs.Displacement.vertsPerRow(disp.power);
                    const vper_rowf: f32 = @floatFromInt(vper_row);
                    const t = 1.0 / (vper_rowf - 1);

                    for (0..disp._verts.items.len) |i| {
                        const fi: f32 = @floatFromInt(i);
                        const ri: f32 = @trunc(fi / vper_rowf);
                        const ci: f32 = @trunc(@mod(fi, vper_rowf));

                        const inter0 = uv0.lerp(uv1, ri * t);
                        const inter1 = uv3.lerp(uv2, ri * t);
                        const uv = inter0.lerp(inter1, ci * t);

                        try Help.emitVertex(.new(@mod(uv.x(), 1.0), @mod(uv.y(), 1.0), 0), &uv_lut, &uv_map, wr, ed.alloc, "vt", 2);
                    }
                }

                const len = @divExact(disp._index.items.len, 3);
                for (0..len) |tri_i| {
                    const ti = tri_i * 3;
                    try wr.print("f", .{});
                    for (ti..ti + 3) |i| {
                        const index = disp._index.items[i];
                        try wr.print(" {d}/{d}/{d}", .{
                            vert_lut.items[index] + 1,
                            uv_lut.items[index] + 1,
                            norm_lut.items[index] + 1,
                        });
                    }
                    try wr.print("\n", .{});
                }
            }
        } else if (try ed.ecs.getOptPtr(@intCast(id), .solid)) |solid| {
            vert_lut.clearRetainingCapacity();
            try wr.print("o solid_{d}\n", .{id});
            for (solid.verts.items) |item| {
                try Help.emitVertex(item, &vert_lut, &vert_map, wr, ed.alloc, "v", 3);
            }
            for (solid.sides.items) |side| {
                { //face

                    try help.emitMtl(
                        if (try ed.vpkctx.resolveId(.{ .id = side.tex_id }, false)) |tex| tex.name else side.material,
                    );
                }

                uv_lut.clearRetainingCapacity();

                const tw: f32 = @floatFromInt(side.tw);
                const th: f32 = @floatFromInt(side.th);
                for (side.index.items) |index| {
                    const upos = solid.verts.items[index];

                    const u = @as(f32, @floatCast(upos.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw));
                    const v = @as(f32, @floatCast(upos.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th));

                    const vec = Vec3.new(@mod(u, 1.0), @mod(v, 1.0), 0);
                    try Help.emitVertex(vec, &uv_lut, &uv_map, wr, ed.alloc, "vt", 2);
                }

                try wr.writeByte('f');
                for (side.index.items, 0..) |index, i| {
                    try wr.print(" {d}/{d}", .{ vert_lut.items[index] + 1, uv_lut.items[i] + 1 });
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
        ed.loaded_skybox_name,
        &ed.vpkctx,
        &ed.groups,
        lm,
        &ed.layers,
        .{ .check_solid = false },
    )) {
        ed.notify("{s}", .{L.lang.notify.exported_vmf}, colors.good);

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
        ed.notify("{s} {t}", .{ L.lang.notify.exported_vmf_fail, err }, colors.bad);
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
    const last = ed.selection.getLast() orelse return;
    const owner_count = ed.selection.countGroup();
    const last_owner = ed.groups.getOwner(ed.selection.getGroup(last) orelse return) orelse null;

    if (owner_count > 1)
        ed.notify("{d} owned groups selected, merging!", .{owner_count}, 0xfca7_3fff);

    const ustack = try ed.undoctx.pushNewFmt("{s} {d}", .{ L.lang.undo.group_objects, selection.len });
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
    if (owner) |o| try ed.selection.addWithGroup(o, new_group);
    for (selection) |id| {
        const old = if (try ed.ecs.getOpt(id, .group)) |g| g.id else 0;
        try ustack.append(.{
            .change_group = try .create(ustack.alloc, old, new_group, id),
        });
    }
    ustack.apply(ed);
    ed.notify("{s} {d}", .{ L.lang.undo.group_objects, selection.len }, 0x00ff00ff);
}

const pgen = @import("primitive_gen.zig");
const Primitive = pgen.Primitive;
pub fn createSolid(ed: *Ed, primitive: *const Primitive, tex_id: vpk.VpkResId, center: Vec3, rot: graph.za.Mat3, select: bool) ![]const ecs.EcsT.Id {
    const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.create_primitive});
    const old_selection_state = if (select) try ed.selection.createStateSnapshot(ustack.alloc) else null;
    if (select) {
        ed.selection.clear();
        ed.selection.mode = .many;
    }
    const aa = ed.frame_arena.allocator();
    var id_list = std.ArrayListUnmanaged(ecs.EcsT.Id){};
    const game: vpk.Game = ed.vpkctx.getGame(tex_id) orelse .Default;
    for (primitive.solids.items) |sol| {
        if (ecs.Solid.initFromPrimitive(ed.alloc, primitive.verts.items, sol.items, tex_id, center, rot, game.u_scale, game.v_scale)) |newsolid| {
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
                try ed.selection.addWithGroup(owner, gid.*);
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
        const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.create_layer});
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
        const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.delete_layer});

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

        const ustack = try ed.undoctx.pushNewFmt("{s} {s}", .{ L.lang.undo.dupe_layer, current.name });
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

    const ustack = try ed.undoctx.pushNewFmt("{s} {s} -> {s}", .{ L.lang.undo.merge_layer, to_merge.name, target.name });
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
        const ustack = try ed.undoctx.pushNewFmt("{s} {s}", .{ L.lang.undo.move_layer, moved.name });
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
    const ustack = try ed.undoctx.pushNewFmt("{s} {d}", .{ L.lang.undo.translate_face, list.len });
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
    const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.create_ent});
    try ustack.append(.{ .create_destroy = try .create(ustack.alloc, new, .create) });
    ustack.apply(ed);
}

pub fn clipSelected(ed: *Ed, points: [3]Vec3) !void {
    const p0 = points[0];
    const p1 = points[1];
    const p2 = points[2];
    const pnorm = util3d.trianglePlane(.{ p0, p1, p2 }).norm();

    const selected = ed.getSelected();
    const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.clip});
    for (selected) |sel_id| {
        const solid = ed.getComponent(sel_id, .solid) orelse continue;
        const game: vpk.Game = ed.vpkctx.getGame(ed.edit_state.selected_texture_vpk_id orelse 0) orelse .Default;
        var ret = try ed.clipctx.clipSolid(solid, p0, pnorm, ed.edit_state.selected_texture_vpk_id, game.u_scale, game.v_scale);

        ed.selection.clear();
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

    const ustack = try ed.undoctx.pushNewFmt("{s} {d}", .{ if (dupe) L.lang.undo.dupe_ents else L.lang.undo.transform_ents, selected.len });
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
    const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.texture_manip});
    try ustack.append(.{ .texture_manip = try .create(ustack.alloc, old, new, side.id, side.side_i) });
    ustack.apply(ed);
}

pub fn applyTextureToSelection(ed: *Ed, tex_id: vpk.VpkResId) !void {
    const selection = ed.getSelected();
    const ustack = try ed.undoctx.pushNewFmt("{s}", .{L.lang.undo.texture_apply});
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

pub fn unloadPointfile(ed: *Ed) void {
    if (ed.draw_state.pointfile) |pf|
        pf.verts.deinit();
    ed.draw_state.pointfile = null;
}

pub fn loadPointfile(ed: *Ed, dir: std.fs.Dir, path: []const u8) !void {
    unloadPointfile(ed);
    ed.draw_state.pointfile = try @import("pointfile.zig").loadPointfile(ed.alloc, dir, path);
}
