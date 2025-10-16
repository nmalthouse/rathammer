const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const tools = @import("tools.zig");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const views = @import("editor_views.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const gridutil = @import("grid.zig");
const G = graph.RGui;
const iWindow = G.iWindow;
const iArea = G.iArea;
const Gui = G.Gui;
const DrawState = G.DrawState;

pub const Ctx2dView = struct {
    pub const Axis = enum { x, y, z };
    vt: iWindow,
    area: iArea,

    cam: graph.Camera2D = .{
        .cam_area = graph.Rec(0, 0, 1000, 1000),
        .screen_area = graph.Rec(0, 0, 0, 0),
    },
    drawctx: *graph.ImmediateDrawingContext,
    ed: *Context,

    axis: Axis,

    pub fn create(ed: *Context, gui: *G.Gui, drawctx: *graph.ImmediateDrawingContext, axis: Axis) !*G.iWindow {
        var self = try gui.alloc.create(@This());
        self.* = .{
            .area = .{ .area = graph.Rec(0, 0, 0, 0), .deinit_fn = area_deinit, .draw_fn = drawfn },
            .vt = iWindow.init(&@This().build, gui, &@This().deinit, &self.area),
            .drawctx = drawctx,
            .axis = axis,
            .ed = ed,
        };
        self.vt.update_fn = update;

        return &self.vt;
    }

    pub fn update(vt: *iWindow, gui: *Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.updateErr(gui) catch {};
    }

    pub fn updateErr(self: *@This(), gui: *Gui) !void {
        const screen_area = self.area.area;
        const draw = self.drawctx;
        const ed = self.ed;
        self.cam.screen_area = screen_area;
        self.cam.syncAspect();
        //graph.c.glViewport(x, y, w, h);
        //graph.c.glScissor(x, y, w, h);
        draw.setViewport(screen_area);
        const old_screen_dim = draw.screen_dimensions;
        defer draw.screen_dimensions = old_screen_dim;
        draw.screen_dimensions = .{ .x = screen_area.w, .y = screen_area.h };

        //graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
        //defer graph.c.glDisable(graph.c.GL_SCISSOR_TEST);
        const can_grab = gui.canGrabMouseOverride(&self.vt);
        self.ed.stack_owns_input = can_grab;
        defer self.ed.stack_owns_input = false;

        const mouse = ed.mouseState();
        if (can_grab) {
            self.ed.edit_state.lmouse = gui.sdl_win.mouse.left;
            self.ed.edit_state.rmouse = gui.sdl_win.mouse.right;
        } else {
            self.ed.edit_state.lmouse = .low;
            self.ed.edit_state.rmouse = .low;
        }

        var capture: bool = false;
        if (can_grab and (mouse.middle == .high or ed.isBindState(ed.config.keys.cam_pan.b, .high))) {
            capture = true;
            self.cam.pan(mouse.delta.scale(ed.config.window.sensitivity_2d));
        }
        ed.handleMisc3DKeys();

        gui.setGrabOverride(&self.vt, capture, .{ .hide_pointer = capture });
        self.ed.stack_grabbed_mouse = capture;
        defer self.ed.stack_grabbed_mouse = false;

        const zoom_bounds = graph.Vec2f{ .x = 16, .y = 1 << 16 };
        if (mouse.wheel_delta.y != 0) {
            self.cam.zoom(mouse.wheel_delta.y * 0.1, mouse.pos, zoom_bounds, zoom_bounds);
        }

        const cb = self.cam.cam_area;
        draw.rect(cb, 0x1111_11ff);
        const view_2d = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, -100000, 1);
        const near = -4096;
        const far = 4096;
        const view_pre = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, near, far);
        const view_3d = switch (self.axis) {
            .y => view_pre.mul(graph.za.lookAt(Vec3.zero(), Vec3.new(0, 1, 0), Vec3.new(0, 0, -1))),
            .z => view_pre,
            .x => view_pre.rotate(90, Vec3.new(0, 1, 0)).rotate(90, Vec3.new(1, 0, 0)),
        };
        try draw.flushCustomMat(view_2d, view_3d);
        graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
        defer graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_FILL);

        {
            var ent_it = ed.ecs.iterator(.entity);
            while (ent_it.next()) |ent| {
                try ent.drawEnt(ed, view_3d, draw, draw, .{ .screen_area = screen_area });
            }
        }
        const grid_color = 0x4444_44ff;
        gridutil.drawGrid2DAxis('x', cb, 50, ed.grid.s.x(), draw, .{ .color = grid_color });
        gridutil.drawGrid2DAxis('y', cb, 50, ed.grid.s.y(), draw, .{ .color = grid_color });

        var it = ed.meshmap.iterator();
        const c = graph.c;
        const model = graph.za.Mat4.identity();
        while (it.next()) |mesh| {
            graph.c.glUseProgram(ed.draw_state.basic_shader);
            graph.GL.passUniform(ed.draw_state.basic_shader, "view", view_3d);
            graph.GL.passUniform(ed.draw_state.basic_shader, "model", model);
            graph.c.glBindVertexArray(mesh.value_ptr.*.lines_vao);
            const diffuse_loc = c.glGetUniformLocation(ed.draw_state.basic_shader, "diffuse_texture");

            c.glUniform1i(diffuse_loc, 0);
            c.glBindTextureUnit(0, mesh.value_ptr.*.mesh.diffuse_texture);
            graph.c.glDrawElements(c.GL_LINES, @as(c_int, @intCast(mesh.value_ptr.*.lines_index.items.len)), graph.c.GL_UNSIGNED_INT, null);
            //mesh.value_ptr.*.mesh.drawSimple(view_3d, mat, ed.draw_state.basic_shader);
        }
        const draw_nd = &ed.draw_state.ctx;

        const td = tools.ToolData{
            .screen_area = screen_area,
            .view_3d = &view_3d,
            .cam2d = &self.cam,
            .draw = draw,
            .text_param = .{ .px_size = 10, .color = 0xffff_ffff, .font = gui.font },
        };
        if (ed.getCurrentTool()) |tool_vt| {
            const selected = ed.getSelected();
            for (selected) |sel| {
                if (ed.getComponent(sel, .solid)) |solid| {
                    solid.drawEdgeOutline(draw, Vec3.zero(), .{
                        .point_color = tool_vt.selected_solid_point_color,
                        .edge_color = tool_vt.selected_solid_edge_color,
                        .edge_size = 2,
                        .point_size = ed.config.dot_size,
                    });
                }
            }
            if (tool_vt.runTool_2d_fn) |run2d|
                try run2d(tool_vt, td, ed);
        }

        try draw.flushCustomMat(view_2d, view_3d);
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        try draw_nd.flushCustomMat(view_2d, view_3d);
    }

    pub fn build(vt: *iWindow, gui: *Gui, area: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = gui;
        self.area.area = area;
    }

    pub fn area_deinit(_: *iArea, _: *Gui, _: *iWindow) void {}

    pub fn drawfn(_: *iArea, _: DrawState) void {}

    pub fn deinit(vt: *G.iWindow, gui: *G.Gui) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        gui.alloc.destroy(self);
    }
};
