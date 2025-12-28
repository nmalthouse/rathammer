const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;
const snapV3 = Editor.snapV3;
const util3d = graph.util_3d;
const cubeFromBounds = Editor.cubeFromBounds;
const Solid = Editor.Solid;
const AABB = Editor.AABB;
const raycast = @import("raycast_solid.zig");
const G = graph.RGui;
const fgd = @import("fgd.zig");
const undo = @import("undo.zig");
const tools = @import("tools.zig");
const ecs = @import("ecs.zig");
const eql = std.mem.eql;
const Window = graph.SDL.Window;
const action = @import("actions.zig");

pub const Main3DView = struct {
    const iWindow = G.iWindow;
    const iArea = G.iArea;
    const Gui = G.Gui;
    const DrawState = G.DrawState;

    vt: G.iWindow,

    ed: *Context,
    drawctx: *graph.ImmediateDrawingContext,

    // only used when grab_when == .toggle
    grab_toggled: bool = false,

    pub fn update(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const can_grab = gui.canGrabMouseOverride(vt);
        self.ed.stack_owns_input = can_grab;
        defer self.ed.stack_owns_input = false;

        const grab_when = self.ed.config.mouse_grab_when;
        const prev_grab_tog = self.grab_toggled;
        switch (grab_when) {
            .toggle => {
                if (self.ed.isBindState(self.ed.config.keys.mouse_capture.b, .rising)) {
                    self.grab_toggled = !self.grab_toggled;
                }
            },
            else => {},
        }

        //These are named wrt high shift uncapturing
        const should_grab = can_grab and switch (grab_when) {
            .key_low => !self.ed.isBindState(self.ed.config.keys.mouse_capture.b, .high),
            .key_high => self.ed.isBindState(self.ed.config.keys.mouse_capture.b, .high),
            .toggle => self.grab_toggled,
        };
        const ungrab_rising = switch (grab_when) {
            .key_low => self.ed.isBindState(self.ed.config.keys.mouse_capture.b, .rising),
            .key_high => self.ed.isBindState(self.ed.config.keys.mouse_capture.b, .falling),
            .toggle => !self.grab_toggled and self.grab_toggled != prev_grab_tog,
        };

        const win = gui.sdl_win;
        gui.setGrabOverride(vt, should_grab or (can_grab and win.mouse.left != .low), .{ .hide_pointer = should_grab });
        if (ungrab_rising and can_grab) {
            const center = self.vt.area.area.center();
            graph.c.SDL_WarpMouseInWindow(gui.sdl_win.win, center.x, center.y);
        }

        const cam_state = self.ed.getCam3DMove(should_grab);

        if (can_grab) {
            self.ed.edit_state.lmouse = win.mouse.left;
            self.ed.edit_state.rmouse = win.mouse.right;
        } else {
            self.ed.edit_state.lmouse = .low;
            self.ed.edit_state.rmouse = .low;
        }
        self.ed.draw_state.cam3d.updateDebugMove(cam_state);
        self.ed.stack_grabbed_mouse = should_grab;
        defer self.ed.stack_grabbed_mouse = false;
        self.ed.handleMisc3DKeys();
        draw3Dview(self.ed, vt.area.area, self.drawctx, gui.dstate.font, gui.dstate.style.config.text_h) catch return;
    }

    pub fn create(ed: *Context, gui: *G.Gui, drawctx: *graph.ImmediateDrawingContext) !*G.iWindow {
        var self = try gui.alloc.create(@This());
        self.* = .{
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, .{}, &self.vt),
            .drawctx = drawctx,
            .ed = ed,
        };
        self.vt.update_fn = update;

        return &self.vt;
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = gui;
        self.vt.area.area = area;
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn draw(_: *iArea, _: *Gui, _: *DrawState) void {}

    pub fn deinit(vt: *G.iWindow, gui: *G.Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        vt.deinit(gui);
        gui.alloc.destroy(self);
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

    const view_3d = self.draw_state.cam3d.getMatrix(screen_area.w / screen_area.h);
    self.renderer.beginFrame();
    self.renderer.clearLights();
    self.draw_state.active_lights = 0;
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

    var it = self.meshmap.iterator();
    while (it.next()) |mesh| {
        if (self.tool_res_map.contains(mesh.key_ptr.*))
            continue;
        try self.renderer.submitDrawCall(.{
            .prim = .triangles,
            .num_elements = @intCast(mesh.value_ptr.*.mesh.indicies.items.len),
            .element_type = graph.c.GL_UNSIGNED_INT,
            .vao = mesh.value_ptr.*.mesh.vao,
            .diffuse = mesh.value_ptr.*.mat.slots[0].id,
            .blend = mesh.value_ptr.*.mat.id(.blend),
            .bump = mesh.value_ptr.*.mat.id(.bump),
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
            try self.renderer.point_light_batch.inst.append(self.renderer.alloc, .{
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

            try self.renderer.spot_light_batch.inst.append(self.renderer.spot_light_batch.alloc, .{
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
            try self.renderer.decal_batch.inst.append(self.renderer.decal_batch.alloc, .{
                .pos = graph.Vec3f.new(ent.origin.x(), ent.origin.y(), ent.origin.z()),
                .ext = graph.Vec3f.new(16, 32, 24),
            });
        }
    }
    try self.renderer.decal_batch.inst.append(self.renderer.decal_batch.alloc, .{
        .pos = graph.Vec3f.new(0, 0, 0),
        .ext = graph.Vec3f.new(100, 100, 100),
    });

    {
        var tp = td.text_param;
        tp.background_rect = 0xff;
        var ent_it = self.editIterator(.entity);
        while (ent_it.next()) |ent| {
            try ent.drawEnt(self, view_3d, draw, draw_nd, .{
                .screen_area = screen_area,
                .text_param = &tp,
                .ent_id = ent_it.i,
            });
        }
    }

    try self.renderer.draw(self.draw_state.cam3d, screen_area, old_dim, .{
        .fac = self.draw_state.factor,
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

    graph.c.glEnable(graph.c.GL_BLEND);
    graph.c.glBlendFunc(graph.c.GL_SRC_ALPHA, graph.c.GL_ONE_MINUS_SRC_ALPHA);
    graph.c.glBlendEquation(graph.c.GL_FUNC_ADD);
    { //Draw all the tools after everything as many are transparent
        //TODO turn into alpha tested texture map

        const mat = graph.za.Mat4.identity();
        var tool_it = self.tool_res_map.iterator();
        while (tool_it.next()) |item| {
            const mesh = self.meshmap.get(item.key_ptr.*) orelse continue;
            mesh.mesh.drawSimple(view_3d, mat, self.renderer.shader.forward);
            self.renderer.countDCall();
        }
    }

    //Draw helpers for the selected entity
    if (self.selection.getGroupOwnerExclusive(&self.groups)) |sel_id| {
        blk: {
            const selection = self.getSelected();
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

    if (self.isBindState(self.config.keys.clear_selection.b, .rising)) {
        try action.clearSelection(self);
        //TODO the keybinding system sucks, if the user hits ctrl+E it matches the binding ctrl+E and just E
        //we have to have fallthrough for binds without modifiers though
        //implement a system which determines which actions happen
    } else if (self.isBindState(self.config.keys.select.b, .rising)) {
        try action.selectRaycast(self, screen_area, view_3d);
    }

    if (self.isBindState(self.config.keys.group_selection.b, .rising)) {
        try action.groupSelection(self);
    }

    if (self.isBindState(self.config.keys.delete_selected.b, .rising)) {
        try action.deleteSelected(self);
    }

    if (self.getCurrentTool()) |vt| {
        if (self.draw_state.draw_outlines) {
            const selected = self.getSelected();
            const edge_size = 2;
            const point_size = self.config.dot_size;

            vt.drawSelectedOutline(self, draw_nd, selected, edge_size, point_size, Vec3.zero());
        }
        try vt.runTool_fn(vt, td, self);
    }

    if (self.draw_state.skybox_textures) |txt| {
        self.renderer.drawSkybox(self.draw_state.cam3d, screen_area, txt);
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

        var mt = graph.MultiLineText.start(draw, .{ .x = 0, .y = 0 }, font);
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
            mt.textFmt("Selected: {d}", .{self.getSelected().len}, fh, col);
        if (self.edit_state.manual_hidden_count > 0) {
            mt.textFmt("{d} objects hidden", .{self.edit_state.manual_hidden_count}, fh, HIDDEN_COLOR);
        }
        if (self.draw_state.tog.debug_stats) {
            mt.textFmt("  nbatch, ", .{}, fh, col);
            mt.textFmt("draw  {d}    ", .{draw.batches.count()}, fh, col);
            mt.textFmt("drnd  {d}    ", .{draw_nd.batches.count()}, fh, col);
            mt.textFmt("dcall {d}    ", .{self.renderer.last_frame_draw_call_count}, fh, col);
        }
        {
            const notify_slice = try self.notifier.getSlice(self.draw_state.frame_time_ms);
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
