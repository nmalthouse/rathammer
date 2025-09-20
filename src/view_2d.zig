const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const tools = @import("tools.zig");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const views = @import("editor_views.zig");
const panereg = @import("pane.zig");
const iPane = panereg.iPane;
const DrawCtx = graph.ImmediateDrawingContext;
const gridutil = @import("grid.zig");

pub const Ctx2dView = struct {
    pub const Axis = enum { x, y, z };
    vt: iPane,

    cam: graph.Camera2D = .{
        .cam_area = graph.Rec(0, 0, 1000, 1000),
        .screen_area = graph.Rec(0, 0, 0, 0),
    },
    font: *graph.FontUtil.PublicFontInterface,

    axis: Axis,

    pub fn draw_fn(vt: *iPane, screen_area: graph.Rect, editor: *Context, d: panereg.ViewDrawState, pane_id: panereg.PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.draw2dView(editor, screen_area, d.draw, pane_id) catch return;
    }

    pub fn create(alloc: std.mem.Allocator, axis: Axis, font: *graph.FontUtil.PublicFontInterface) !*iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .draw_fn = &@This().draw_fn,
            },
            .font = font,
            .axis = axis,
        };
        return &ret.vt;
    }

    pub fn deinit(vt: *iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn draw2dView(self: *@This(), ed: *Context, screen_area: graph.Rect, draw: *DrawCtx, pane_id: panereg.PaneId) !void {
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
        const mouse = ed.mouseState();

        //draw.rect(screen_area, 0xffff);
        if (mouse.middle == .high or ed.isBindState(ed.config.keys.cam_pan.b, .high)) {
            _ = ed.panes.grab.trySetGrab(pane_id, true);
            self.cam.pan(mouse.delta.scale(ed.config.window.sensitivity_2d));
        }
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
                try ent.drawEnt(ed, view_3d, draw, draw, .{});
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
            .text_param = .{ .px_size = 10, .color = 0xffff_ffff, .font = self.font },
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
};

pub const CrapCam = struct {
    area: graph.Rect,
    pub fn getMatrix(self: @This(), aspect_ratio: f32, near: f32, far: f32) graph.za.Mat4 {
        _ = aspect_ratio;
        const cb = self.area;
        const view = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, near, far);
        return view;
    }
};
