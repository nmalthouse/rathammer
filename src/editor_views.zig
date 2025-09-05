const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;
const snapV3 = Editor.snapV3;
const util3d = @import("util_3d.zig");
const cubeFromBounds = Editor.cubeFromBounds;
const Solid = Editor.Solid;
const AABB = Editor.AABB;
const raycast = @import("raycast_solid.zig");
const Gui = graph.Gui;
const fgd = @import("fgd.zig");
const undo = @import("undo.zig");
const tools = @import("tools.zig");
const ecs = @import("ecs.zig");
const eql = std.mem.eql;
const Os9Gui = graph.Os9Gui;
const Window = graph.SDL.Window;
const action = @import("actions.zig");

const panereg = @import("pane.zig");

pub const Main3DView = struct {
    vt: panereg.iPane,

    font: *graph.FontUtil.PublicFontInterface,
    fh: f32,

    grab_when: enum {
        shift_low,
        shift_high,
        toggle,
    } = .toggle,
    // only used when grab_when == .toggle
    grab_toggled: bool = false,

    pub fn draw_fn(vt: *panereg.iPane, screen_area: graph.Rect, editor: *Context, d: panereg.ViewDrawState, pane_id: panereg.PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const grab_when = editor.config.mouse_grab_when;
        switch (grab_when) {
            .toggle => {
                if (editor.isBindState(editor.config.keys.mouse_capture.b, .rising)) {
                    self.grab_toggled = !self.grab_toggled;
                }
            },
            else => {},
        }
        const shift_high = switch (grab_when) {
            .key_low => !editor.isBindState(editor.config.keys.mouse_capture.b, .high),
            .key_high => editor.isBindState(editor.config.keys.mouse_capture.b, .high),
            .toggle => self.grab_toggled,
        };
        switch (editor.panes.grab.trySetGrab(pane_id, shift_high)) {
            else => {},
            .ungrabbed => {
                const center = screen_area.center();
                graph.c.SDL_WarpMouseInWindow(d.win.win, center.x, center.y);
            },
        }

        editor.draw_state.cam3d.updateDebugMove(if (editor.panes.grab.owns(pane_id)) d.camstate else .{});
        draw3Dview(editor, screen_area, d.draw, self.font, self.fh) catch return;
    }

    pub fn create(alloc: std.mem.Allocator, font: *graph.FontUtil.PublicFontInterface, font_h: f32) !*panereg.iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .draw_fn = &@This().draw_fn,
            },
            .font = font,
            .fh = font_h,
        };
        return &ret.vt;
    }

    pub fn deinit(vt: *panereg.iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

pub fn draw3Dview(
    self: *Context,
    screen_area: graph.Rect,
    draw: *graph.ImmediateDrawingContext,
    font: *graph.FontUtil.PublicFontInterface,
    fh: f32,
) !void {
    graph.c.glPolygonMode(
        graph.c.GL_FRONT_AND_BACK,
        if (self.draw_state.tog.wireframe) graph.c.GL_LINE else graph.c.GL_FILL,
    );
    defer graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_FILL);
    try self.draw_state.ctx.beginNoClear(screen_area.dim());
    try self.draw_state.screen_space_text_ctx.beginNoClear(screen_area.dim());
    draw.setViewport(screen_area);
    const old_dim = draw.screen_dimensions;
    draw.screen_dimensions = screen_area.dim();
    defer draw.screen_dimensions = old_dim;
    // draw_nd "draw no depth" is for any immediate drawing after the depth buffer has been cleared.
    // "draw" still has depth buffer
    const draw_nd = &self.draw_state.ctx;
    //graph.c.glScissor(x, y, w, h);

    //const mat = graph.za.Mat4.identity();

    const view_3d = self.draw_state.cam3d.getMatrix(screen_area.w / screen_area.h, self.draw_state.cam_near_plane, self.draw_state.cam_far_plane);
    self.renderer.beginFrame();
    self.renderer.clearLights();
    self.draw_state.active_lights = 0;

    var it = self.meshmap.iterator();
    while (it.next()) |mesh| {
        if (self.tool_res_map.contains(mesh.key_ptr.*))
            continue;
        try self.renderer.submitDrawCall(.{
            .prim = .triangles,
            .num_elements = @intCast(mesh.value_ptr.*.mesh.indicies.items.len),
            .element_type = graph.c.GL_UNSIGNED_INT,
            .vao = mesh.value_ptr.*.mesh.vao,
            .diffuse = mesh.value_ptr.*.mesh.diffuse_texture,
        });
        //mesh.value_ptr.*.mesh.drawSimple(view_3d, mat, self.draw_state.basic_shader);
    }

    if (self.renderer.mode == .def) {
        if (self.classtrack.getLast("light_environment", &self.ecs)) |env_id| {
            if (self.getComponent(env_id, .key_values)) |kvs| {
                const pitch = kvs.getFloats("pitch", 1) orelse 0;
                const color = kvs.getFloats("_light", 4) orelse [4]f32{ 255, 255, 255, 255 };
                const ambient = kvs.getFloats("_ambient", 4) orelse [4]f32{ 255, 255, 255, 255 };
                const yaws = kvs.getFloats("angles", 3) orelse [3]f32{ 0, 0, 0 };
                self.renderer.pitch = pitch;
                self.renderer.sun_color = color;
                self.renderer.ambient = ambient;
                for (&self.renderer.sun_color) |*cc| //Normalize it
                    cc.* /= 255;
                for (&self.renderer.ambient) |*cc| //Normalize it
                    cc.* /= 255;
                self.renderer.yaw = yaws[1];
            }
        }

        //var itit = self.ecs.iterator(.entity);
        //while (itit.next()) |item| {
        for (try self.classtrack.get("light", &self.ecs)) |item| {
            //if (std.mem.eql(u8, "light", item.class)) {
            const ent = try self.ecs.getOptPtr(item, .entity) orelse continue;

            if (self.draw_state.cam3d.pos.distance(ent.origin) > self.renderer.light_render_dist) continue;

            const kvs = try self.ecs.getOptPtr(item, .key_values) orelse continue;
            const color = kvs.getFloats("_light", 4) orelse continue;
            const constant = kvs.getFloats("_constant_attn", 1) orelse 0;
            const lin = kvs.getFloats("_linear_attn", 1) orelse 1;
            const quad = kvs.getFloats("_quadratic_attn", 1) orelse 0;

            self.draw_state.active_lights += 1;
            try self.renderer.point_light_batch.inst.append(.{
                .light_pos = graph.Vec3f.new(ent.origin.x(), ent.origin.y(), ent.origin.z()),
                .quadratic = quad,
                .constant = constant + self.draw_state.const_add,
                .linear = lin,
                .diffuse = graph.Vec3f.new(color[0], color[1], color[2]).scale(color[3] * self.draw_state.light_mul),
            });
            //}
        }
        for (try self.classtrack.get("light_spot", &self.ecs)) |item| {
            const ent = try self.ecs.getOptPtr(item, .entity) orelse continue;
            if (self.draw_state.cam3d.pos.distance(ent.origin) > self.renderer.light_render_dist) continue;
            const kvs = try self.ecs.getOptPtr(item, .key_values) orelse continue;
            const color = kvs.getFloats("_light", 4) orelse continue;
            const angles = kvs.getFloats("angles", 3) orelse continue;
            const constant = kvs.getFloats("_constant_attn", 1) orelse 0;
            const lin = kvs.getFloats("_linear_attn", 1) orelse 1;
            const quad = kvs.getFloats("_quadratic_attn", 1) orelse 0;
            const cutoff = kvs.getFloats("_cone", 1) orelse 45;
            const cutoff_inner = kvs.getFloats("_inner_cone", 1) orelse 45;
            const pitch = kvs.getFloats("pitch", 1) orelse 0;
            self.draw_state.active_lights += 1;

            const rotated = util3d.eulerToNormal(Vec3.new(-pitch, angles[1], 0));
            const angle = Vec3.new(1, 0, 0).getAngle(rotated);
            const norm = Vec3.new(1, 0, 0).cross(rotated);
            const quat = graph.za.Quat.fromAxis(angle, norm);

            try self.renderer.spot_light_batch.inst.append(.{
                .pos = graph.Vec3f.new(ent.origin.x(), ent.origin.y(), ent.origin.z()),
                .quadratic = quad,
                .constant = constant + self.draw_state.const_add,
                .linear = lin,
                .diffuse = graph.Vec3f.new(color[0], color[1], color[2]).scale(color[3] * self.draw_state.light_mul),
                .cutoff_outer = cutoff,
                .cutoff = cutoff_inner,
                .dir = graph.Vec3f.new(quat.x, quat.y, quat.z),
                .w = quat.w,
            });
        }
        for (try self.classtrack.get("infodecal", &self.ecs)) |item| {
            const ent = try self.ecs.getOptPtr(item, .entity) orelse continue;
            if (self.draw_state.cam3d.pos.distance(ent.origin) > self.renderer.light_render_dist) continue;
            //const kvs = try self.ecs.getOptPtr(item, .key_values) orelse continue;
            //
            try self.renderer.decal_batch.inst.append(.{
                .pos = graph.Vec3f.new(ent.origin.x(), ent.origin.y(), ent.origin.z()),
                .ext = graph.Vec3f.new(16, 32, 24),
            });
        }
    }
    try self.renderer.decal_batch.inst.append(.{
        .pos = graph.Vec3f.new(0, 0, 0),
        .ext = graph.Vec3f.new(100, 100, 100),
    });

    try self.renderer.draw(self.draw_state.cam3d, screen_area, old_dim, .{
        .fac = self.draw_state.factor,
        .near = self.draw_state.cam_near_plane,
        .far = self.draw_state.cam_far_plane,
        .pad = self.draw_state.pad,
        .index = self.draw_state.index,
    }, draw, self.draw_state.planes);

    const LADDER_RENDER_DISTANCE = 1024;
    //In the future, entity specific things like this should be scriptable instead.
    for (try self.classtrack.get("func_useableladder", &self.ecs)) |ladder| {
        const kvs = try self.ecs.getOptPtr(ladder, .key_values) orelse continue;

        const p0 = kvs.getFloats("point0", 3) orelse continue;
        const p1 = kvs.getFloats("point1", 3) orelse continue;
        const size = Vec3.new(32, 32, 72);
        const offset = Vec3.new(16, 16, 0);
        const v0 = Vec3.new(p0[0], p0[1], p0[2]).sub(offset);
        const v1 = Vec3.new(p1[0], p1[1], p1[2]).sub(offset);

        if (v0.distance(self.draw_state.cam3d.pos) > LADDER_RENDER_DISTANCE and v1.distance(self.draw_state.cam3d.pos) > LADDER_RENDER_DISTANCE)
            continue;

        draw.cube(v0, size, 0xFF8C00ff);
        draw.cube(v1, size, 0xFF8C00ff);

        const c0 = util3d.cubeVerts(v0, size);
        const c1 = util3d.cubeVerts(v1, size);
        for (c0, 0..) |v, i| {
            const vv = c1[i];
            draw.line3D(v, vv, 0xff8c0088, 4);
        }
    }

    try draw.flush(null, self.draw_state.cam3d);
    {
        var ent_it = self.editIterator(.entity);
        while (ent_it.next()) |ent| {
            try ent.drawEnt(self, view_3d, draw, draw_nd, .{});
        }
    }

    graph.c.glEnable(graph.c.GL_BLEND);
    graph.c.glBlendFunc(graph.c.GL_SRC_ALPHA, graph.c.GL_ONE_MINUS_SRC_ALPHA);
    graph.c.glBlendEquation(graph.c.GL_FUNC_ADD);
    { //Draw all the tools after everything as many are transparent
        //TODO turn into alpha tested texture map

        const mat = graph.za.Mat4.identity();
        var tool_it = self.tool_res_map.iterator();
        while (tool_it.next()) |item| {
            const mesh = self.meshmap.get(item.key_ptr.*) orelse continue;
            mesh.mesh.drawSimple(view_3d, mat, self.draw_state.basic_shader);
        }
    }

    //Draw helpers for the selected entity
    if (self.selection.getGroupOwnerExclusive(&self.groups)) |sel_id| {
        blk: {
            const selection = self.selection.getSlice();
            if (self.getComponent(sel_id, .entity)) |ent| {
                var origin = ent.origin;
                if (selection.len == 1) {
                    if (self.getComponent(selection[0], .solid)) |solid| {
                        _ = solid;
                        if (self.getComponent(selection[0], .bounding_box)) |bb| {
                            const diff = bb.b.sub(bb.a).scale(0.5);
                            origin = bb.a.add(diff);
                        }
                    }
                }
                if (self.getComponent(sel_id, .key_values)) |kvs| {
                    const eclass = self.fgd_ctx.getPtr(ent.class) orelse break :blk;
                    for (eclass.field_data.items) |field| {
                        switch (field.type) {
                            .angle => {
                                var angle = kvs.getFloats(field.name, 3) orelse break :blk;
                                if (kvs.getFloats("pitch", 1)) |pitch| { //Workaround for valves shitty fgd
                                    angle[0] = -pitch;
                                }
                                const rotated = util3d.eulerToNormal(Vec3.fromSlice(&angle));
                                draw_nd.line3D(origin, origin.add(rotated.scale(64)), 0xff0000ff, 12);
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }

    if (self.isBindState(self.config.keys.undo.b, .rising)) {
        action.undo(self);
    }
    if (self.isBindState(self.config.keys.redo.b, .rising)) {
        action.redo(self);
    }

    if (self.isBindState(self.config.keys.toggle_select_mode.b, .rising))
        self.selection.toggle();

    if (self.isBindState(self.config.keys.hide_selected.b, .rising)) {
        try action.hideSelected(self);
    }

    if (self.isBindState(self.config.keys.unhide_all.b, .rising))
        try action.unhideAll(self);

    if (self.isBindState(self.config.keys.select.b, .rising)) {
        try action.selectRaycast(self, screen_area, view_3d);
    }
    if (self.isBindState(self.config.keys.clear_selection.b, .rising))
        action.clearSelection(self);

    if (self.isBindState(self.config.keys.group_selection.b, .rising)) {
        try action.groupSelection(self);
    }

    if (self.isBindState(self.config.keys.delete_selected.b, .rising)) {
        try action.deleteSelected(self);
    }

    const td = tools.ToolData{
        .screen_area = screen_area,
        .view_3d = &view_3d,
        .draw = draw,
        .text_param = .{
            .color = 0xffff_ffff,
            .px_size = fh,
            .font = font,
        },
    };
    if (self.getCurrentTool()) |vt| {
        const selected = self.selection.getSlice();
        if (self.draw_state.draw_outlines) {
            for (selected) |sel| {
                if (self.getComponent(sel, .solid)) |solid| {
                    solid.drawEdgeOutline(draw_nd, Vec3.zero(), .{
                        .point_color = vt.selected_solid_point_color,
                        .edge_color = vt.selected_solid_edge_color,
                        .edge_size = 2,
                        .point_size = self.config.dot_size,
                    });
                }
            }
        }
        try vt.runTool_fn(vt, td, self);
    }
    if (self.draw_state.tog.skybox) { //sky stuff
        const c = graph.c;
        c.glDisable(c.GL_BLEND);
        c.glDepthMask(c.GL_FALSE);
        c.glDepthFunc(c.GL_LEQUAL);
        defer c.glDepthFunc(c.GL_LESS);
        defer c.glDepthMask(c.GL_TRUE);

        const c3d = self.draw_state.cam3d;
        const za = graph.za;
        const la = za.lookAt(Vec3.zero(), c3d.front, c3d.getUp());
        const perp = za.perspective(c3d.fov, screen_area.w / screen_area.h, 0, 1);

        for (self.skybox.meshes.items, 0..) |*sk, i| {
            sk.draw(.{ .texture = self.skybox.textures.items[i].id, .shader = self.skybox.shader }, perp.mul(la), graph.za.Mat4.identity());
        }
    }
    if (self.draw_state.pointfile) |pf| {
        const sl = pf.verts.items;
        if (sl.len > 1) {
            for (sl[0 .. sl.len - 1], 0..) |v, i| {
                const next = sl[i + 1];
                draw.line3D(v, next, 0xff0000ff, 4);
            }
        }
    }
    if (self.draw_state.portalfile) |pf| {
        const sl = pf.verts.items;
        if (sl.len % 4 == 0) {
            for (0..sl.len / 4) |i| {
                const sll = sl[i * 4 .. i * 4 + 4];
                for (0..sll.len) |in| {
                    const next = (in + 1) % sll.len;
                    draw.line3D(sll[in], sll[next], 0x0000ffff, 2);
                }
            }
        }
    }

    try draw.flush(null, self.draw_state.cam3d);
    graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);

    try draw_nd.flush(null, self.draw_state.cam3d);
    graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
    { // text stuff
        const col = 0xff_ff_ffff;
        const p = self.draw_state.cam3d.pos;

        const SINGLE_COLOR = 0xfcc858ff;
        const MANY_COLOR = 0xfc58d6ff;
        const HIDDEN_COLOR = 0x20B2AAff;

        var mt = graph.MultiLineText.start(draw, screen_area.pos(), font);
        if (self.draw_state.init_asset_count > 0) {
            mt.textFmt("Loading assets: {d}", .{self.draw_state.init_asset_count}, fh, col);
        }
        if (self.draw_state.active_lights > 0) {
            mt.textFmt("Lights: {d}", .{self.draw_state.active_lights}, fh, col);
        }
        if (self.layers.getLayerFromId(self.edit_state.selected_layer)) |lay| {
            mt.textFmt("Active layer: {s}", .{lay.name}, fh, col);
        }
        if (self.grid.isOne()) {
            mt.textFmt("grid: {d}", .{self.grid.s.x()}, fh, col);
        } else {
            mt.textFmt("grid: {d:.2} {d:.2} {d:.2}", .{ self.grid.s.x(), self.grid.s.y(), self.grid.s.z() }, fh, col);
        }
        mt.textFmt("pos: {d:.2} {d:.2} {d:.2}", .{ p.data[0], p.data[1], p.data[2] }, fh, col);
        mt.textFmt("select: {s}", .{@tagName(self.selection.mode)}, fh, switch (self.selection.mode) {
            .one => SINGLE_COLOR,
            .many => MANY_COLOR,
        });
        if (self.selection.mode == .many)
            mt.textFmt("Selected: {d}", .{self.selection.multi.items.len}, fh, col);
        if (self.edit_state.manual_hidden_count > 0) {
            mt.textFmt("{d} objects hidden", .{self.edit_state.manual_hidden_count}, fh, HIDDEN_COLOR);
        }
        {
            //TODO put an actual dt here
            const notify_slice = try self.notifier.getSlice(16);
            for (notify_slice) |n| {
                mt.text(n.msg, fh, n.color);
            }
        }
        mt.drawBgRect(0x99, fh * 30);
    }

    const off = fh * 5;
    self.drawToolbar(graph.Rec(0, screen_area.h - off, screen_area.w, off), draw, font, fh);
    if (self.asset.getRectFromName("crosshair.png")) |cross| {
        const start = screen_area.center().sub(cross.dim().scale(0.5));
        draw.rectTex(graph.Rec(
            @trunc(start.x),
            @trunc(start.y),
            cross.w,
            cross.h,
        ), cross, self.asset_atlas);
    }

    try self.draw_state.screen_space_text_ctx.flush(null, null);
    try draw.flush(null, null);
}

const Split = @import("splitter.zig");
pub const Tab = struct {
    split: []Split.Op,
    panes: []panereg.PaneId,

    pub fn newSplit(s: []Split.Op, i: *usize, sp: []const Split.Op) []Split.Op {
        @memcpy(s[i.* .. i.* + sp.len], sp);
        defer i.* += sp.len;
        return s[i.* .. i.* + sp.len];
    }

    pub fn newPane(p: []panereg.PaneId, pi: *usize, ps: []const panereg.PaneId) []panereg.PaneId {
        @memcpy(p[pi.* .. pi.* + ps.len], ps);
        defer pi.* += ps.len;
        return p[pi.* .. pi.* + ps.len];
    }
};
