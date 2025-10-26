const std = @import("std");
const graph = @import("graph");
const glID = graph.glID;
const c = graph.c;
const GL = graph.GL;
const Mat4 = graph.za.Mat4;
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;
const mesh = graph.meshutil;
const util3d = @import("util_3d.zig");

pub const DrawCall = struct {
    prim: GL.PrimitiveMode,
    num_elements: c_int,
    element_type: c_uint,
    vao: c_uint,
    //view: *const Mat4,
    diffuse: c_uint,
};
const SunQuadBatch = graph.NewBatch(packed struct { pos: graph.Vec3f, uv: graph.Vec2f }, .{ .index_buffer = false, .primitive_mode = .triangles });

pub const Renderer = struct {
    const Self = @This();
    shader: struct {
        csm: glID,
        forward: glID,
        gbuffer: glID,
        light: glID,
        spot: glID,
        sun: glID,
        decal: glID,
        hdr: glID,
    },
    mode: enum { forward, def } = .forward,
    gbuffer: GBuffer,
    hdrbuffer: HdrBuffer,
    csm: Csm,

    alloc: std.mem.Allocator,
    draw_calls: std.ArrayList(DrawCall) = .{},
    last_frame_view_mat: Mat4 = undefined,
    sun_batch: SunQuadBatch,
    point_light_batch: PointLightInstanceBatch,
    spot_light_batch: SpotLightInstanceBatch,
    decal_batch: DecalBatch,

    ambient: [4]f32 = [4]f32{ 1, 1, 1, 255 },
    ambient_scale: f32 = 1,
    exposure: f32 = 3.5,
    gamma: f32 = 1.45,
    pitch: f32 = 35,
    yaw: f32 = 165,
    sun_color: [4]f32 = [4]f32{ 1, 1, 1, 255 },
    do_lighting: bool = true,
    do_decals: bool = false,
    debug_light_coverage: bool = false,
    copy_depth: bool = true,
    light_render_dist: f32 = 1024 * 2,

    res_scale: f32 = 1,

    do_hdr_buffer: bool = true,

    pub fn init(alloc: std.mem.Allocator, shader_dir: std.fs.Dir) !Self {
        const shadow_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "shadow_map.vert", .t = .vert },
            .{ .path = "shadow_map.frag", .t = .frag },
            .{ .path = "shadow_map.geom", .t = .geom },
        });
        const forward = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "basic.vert", .t = .vert },
            .{ .path = "basic.frag", .t = .frag },
        });
        const gbuffer_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "gbuffer_model.vert", .t = .vert },
            .{ .path = "gbuffer_model.frag", .t = .frag },
        });
        const light_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "light.vert", .t = .vert },
            .{ .path = "light_debug.frag", .t = .frag },
        });
        const spot_light_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "spot_light.vert", .t = .vert },
            .{ .path = "spot_light.frag", .t = .frag },
        });
        const def_sun_shad = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "sun.vert", .t = .vert },
            .{ .path = "sun.frag", .t = .frag },
        });
        const decal_shad = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "decal.vert", .t = .vert },
            .{ .path = "decal.frag", .t = .frag },
        });
        const hdr_shad = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{ .{ .path = "hdr.vert", .t = .vert }, .{ .path = "hdr.frag", .t = .frag } });
        var sun_batch = SunQuadBatch.init(alloc);
        _ = sun_batch.clear();
        sun_batch.appendVerts(&.{
            .{ .pos = graph.Vec3f.new(-1, 1, 0), .uv = graph.Vec2f.new(0, 1) },
            .{ .pos = graph.Vec3f.new(-1, -1, 0), .uv = graph.Vec2f.new(0, 0) },
            .{ .pos = graph.Vec3f.new(1, 1, 0), .uv = graph.Vec2f.new(1, 1) },
            .{ .pos = graph.Vec3f.new(1, -1, 0), .uv = graph.Vec2f.new(1, 0) },
        });
        sun_batch.pushVertexData();
        return Self{
            .shader = .{
                .csm = shadow_shader,
                .forward = forward,
                .gbuffer = gbuffer_shader,
                .light = light_shader,
                .spot = spot_light_shader,
                .decal = decal_shad,
                .sun = def_sun_shad,
                .hdr = hdr_shad,
            },
            .point_light_batch = try PointLightInstanceBatch.init(alloc, shader_dir, "icosphere.obj"),
            .spot_light_batch = try SpotLightInstanceBatch.init(alloc, shader_dir, "cone.obj"),
            .decal_batch = try DecalBatch.init(alloc, shader_dir, "cube.obj"),
            .sun_batch = sun_batch,
            .alloc = alloc,
            .csm = Csm.createCsm(2048, Csm.CSM_COUNT, def_sun_shad),
            .gbuffer = GBuffer.create(100, 100),
            .hdrbuffer = HdrBuffer.create(100, 100),
        };
    }

    pub fn beginFrame(self: *Self) void {
        self.draw_calls.clearRetainingCapacity();
    }

    pub fn clearLights(self: *Self) void {
        self.point_light_batch.clear();
        self.spot_light_batch.clear();
        self.decal_batch.clear();
    }

    pub fn submitDrawCall(self: *Self, d: DrawCall) !void {
        try self.draw_calls.append(self.alloc, d);
    }

    pub fn draw(
        self: *Self,
        cam: graph.Camera3D,
        screen_area: graph.Rect,
        screen_dim: graph.Vec2f,
        param: struct {
            far: f32,
            near: f32,
            fac: f32,
            pad: f32,
            index: usize,
        },
        dctx: *DrawCtx,
        pl: anytype,
    ) !void {
        self.point_light_batch.pushVertexData();
        self.spot_light_batch.pushVertexData();
        self.decal_batch.pushVertexData();
        const view1 = cam.getMatrix(screen_area.w / screen_area.h, param.near, param.far);
        self.csm.pad = param.pad;
        switch (self.mode) {
            .forward => {
                const view = view1;
                const sh = self.shader.forward;
                c.glUseProgram(sh);
                GL.passUniform(sh, "view", view);
                for (self.draw_calls.items) |dc| {
                    if (dc.diffuse != 0) {
                        const diffuse_loc = c.glGetUniformLocation(sh, "diffuse_texture");

                        c.glUniform1i(diffuse_loc, 0);
                        c.glBindTextureUnit(0, dc.diffuse);
                    }
                    //GL.passUniform(sh, "model", model);
                    c.glBindVertexArray(dc.vao);
                    c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
                }
            },
            .def => {
                const view = if (param.index == 0) view1 else self.csm.mats[(param.index - 1) % self.csm.mats.len];
                self.last_frame_view_mat = cam.getViewMatrix();
                var light_dir = Vec3.new(@sin(std.math.degreesToRadians(35)), 0, @sin(std.math.degreesToRadians(165))).norm();
                {
                    light_dir = util3d.eulerToNormal(Vec3.new(self.pitch, self.yaw + 180, 0)).scale(1);
                }
                const far = param.far;
                const planes = [_]f32{
                    pl[0],
                    pl[1],
                    pl[2],
                };
                const last_plane = pl[3];
                self.csm.calcMats(cam.fov, screen_area.w / screen_area.h, param.near, far, self.last_frame_view_mat, light_dir, planes);
                self.csm.draw(self);
                self.gbuffer.updateResolution(@intFromFloat(screen_area.w * self.res_scale), @intFromFloat(screen_area.h * self.res_scale));
                if (self.do_hdr_buffer)
                    self.hdrbuffer.updateResolution(@intFromFloat(screen_area.w * self.res_scale), @intFromFloat(screen_area.h * self.res_scale));
                c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.gbuffer.buffer);
                c.glViewport(0, 0, self.gbuffer.scr_w, self.gbuffer.scr_h);
                c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
                { //Write to gbuffer
                    const sh = self.shader.gbuffer;
                    c.glUseProgram(sh);
                    const diffuse_loc = c.glGetUniformLocation(sh, "diffuse_texture");

                    c.glUniform1i(diffuse_loc, 0);
                    c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, self.csm.mat_ubo);
                    for (self.draw_calls.items) |dc| {
                        c.glBindTextureUnit(0, dc.diffuse);
                        GL.passUniform(sh, "view", view);
                        GL.passUniform(sh, "model", Mat4.identity());
                        c.glBindVertexArray(dc.vao);
                        c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
                    }
                }
                if (self.do_decals) {
                    self.drawDecal(cam, graph.Vec2i{ .x = self.gbuffer.scr_w, .y = self.gbuffer.scr_h }, view, .{ .x = 0, .y = 0 }, far);
                }
                const y_: i32 = @intFromFloat(screen_dim.y - (screen_area.y + screen_area.h));
                if (self.do_hdr_buffer) {
                    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.hdrbuffer.fb);
                    c.glClear(c.GL_COLOR_BUFFER_BIT);
                    c.glClearColor(0, 0, 0, 0);
                } else {
                    self.bindMainFramebufferAndVp(screen_area, screen_dim);
                }

                const scrsz = if (self.do_hdr_buffer) graph.Vec2i{ .x = self.gbuffer.scr_w, .y = self.gbuffer.scr_h } else graph.Vec2i{ .x = @intFromFloat(screen_area.w), .y = @intFromFloat(screen_area.h) };
                const win_offset = if (self.do_hdr_buffer) graph.Vec2i{ .x = 0, .y = 0 } else graph.Vec2i{ .x = @intFromFloat(screen_area.x), .y = y_ };
                { //Draw sun
                    c.glDepthMask(c.GL_FALSE);
                    defer c.glDepthMask(c.GL_TRUE);
                    //defer c.glDisable(c.GL_BLEND);
                    c.glClear(c.GL_DEPTH_BUFFER_BIT);

                    const sh1 = self.shader.sun;
                    c.glUseProgram(sh1);
                    c.glBindVertexArray(self.sun_batch.vao);
                    c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, self.csm.mat_ubo);
                    c.glBindTextureUnit(0, self.gbuffer.pos);
                    c.glBindTextureUnit(1, self.gbuffer.normal);
                    c.glBindTextureUnit(2, self.gbuffer.albedo);
                    c.glBindTextureUnit(3, self.csm.textures);
                    var ambient_scaled = self.ambient;
                    ambient_scaled[3] *= self.ambient_scale;
                    graph.GL.passUniform(sh1, "view_pos", cam.pos);
                    graph.GL.passUniform(sh1, "light_dir", light_dir);
                    graph.GL.passUniform(sh1, "screenSize", scrsz);
                    graph.GL.passUniform(sh1, "the_fucking_window_offset", win_offset);
                    graph.GL.passUniform(sh1, "ambient_color", ambient_scaled);
                    graph.GL.passUniform(sh1, "light_color", self.sun_color);
                    graph.GL.passUniform(sh1, "cascadePlaneDistances[0]", @as(f32, planes[0]));
                    graph.GL.passUniform(sh1, "cascadePlaneDistances[1]", @as(f32, planes[1]));
                    graph.GL.passUniform(sh1, "cascadePlaneDistances[2]", @as(f32, planes[2]));
                    graph.GL.passUniform(sh1, "cascadePlaneDistances[3]", @as(f32, last_plane));
                    const cam_mat = cam.getViewMatrix();
                    graph.GL.passUniform(sh1, "cam_view", cam_mat);
                    graph.GL.passUniform(sh1, "cam_view_inv", cam_mat.inv());

                    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, @as(c_int, @intCast(self.sun_batch.vertices.items.len)));

                    c.glEnable(c.GL_BLEND);
                    c.glBlendFunc(c.GL_ONE, c.GL_ONE);
                    defer c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
                    c.glBlendEquation(c.GL_FUNC_ADD);

                    if (self.do_lighting) {
                        self.drawLighting(cam, scrsz, view, win_offset);
                    }
                }

                if (self.do_hdr_buffer) {
                    self.bindMainFramebufferAndVp(screen_area, screen_dim);

                    const sh1 = self.shader.hdr;
                    c.glUseProgram(sh1);
                    c.glBindVertexArray(self.sun_batch.vao);
                    graph.GL.passUniform(sh1, "exposure", self.exposure);
                    graph.GL.passUniform(sh1, "gamma", self.gamma);
                    c.glBindTextureUnit(0, self.hdrbuffer.color);
                    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, @as(c_int, @intCast(self.sun_batch.vertices.items.len)));
                }

                if (self.copy_depth) {
                    const y: i32 = @intFromFloat(screen_dim.y - (screen_area.y + screen_area.h));
                    const x: i32 = @intFromFloat(screen_area.x);
                    c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, self.gbuffer.buffer);
                    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
                    c.glBlitFramebuffer(
                        0,
                        0,
                        self.gbuffer.scr_w,
                        self.gbuffer.scr_h,
                        x,
                        y,
                        x + @as(i32, @intFromFloat(screen_area.w)),
                        y + @as(i32, @intFromFloat(screen_area.h)),
                        c.GL_DEPTH_BUFFER_BIT,
                        c.GL_NEAREST,
                    );
                    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
                }
                _ = dctx;
            },
        }
        self.last_frame_view_mat = cam.getViewMatrix();
    }

    fn drawDecal(self: *Self, cam: graph.Camera3D, wh: anytype, view: anytype, window_offset: anytype, far_clip: f32) void {
        {
            c.glDepthMask(c.GL_FALSE);
            defer c.glDepthMask(c.GL_TRUE);
            _ = window_offset;
            const sh = self.shader.decal;
            c.glUseProgram(sh);
            c.glBindVertexArray(self.decal_batch.vao);
            c.glBindTextureUnit(0, self.gbuffer.pos);
            c.glBindTextureUnit(1, self.gbuffer.normal);
            c.glBindTextureUnit(2, self.gbuffer.depth);
            graph.GL.passUniform(sh, "view_pos", cam.pos);
            graph.GL.passUniform(sh, "exposure", self.exposure);
            graph.GL.passUniform(sh, "gamma", self.gamma);
            graph.GL.passUniform(sh, "screenSize", wh);
            graph.GL.passUniform(sh, "draw_debug", self.debug_light_coverage);
            graph.GL.passUniform(sh, "far_clip", far_clip);

            graph.GL.passUniform(sh, "cam_view", cam.getViewMatrix());
            graph.GL.passUniform(sh, "view", view);

            self.decal_batch.draw();
        }
    }

    fn drawLighting(self: *Self, cam: graph.Camera3D, wh: anytype, view: anytype, window_offset: anytype) void {
        if (!self.debug_light_coverage)
            graph.c.glCullFace(graph.c.GL_FRONT);
        defer graph.c.glCullFace(graph.c.GL_BACK);
        { //point lights
            const sh = self.shader.light;
            c.glUseProgram(sh);
            c.glBindVertexArray(self.point_light_batch.vao);
            c.glBindTextureUnit(0, self.gbuffer.pos);
            c.glBindTextureUnit(1, self.gbuffer.normal);
            c.glBindTextureUnit(2, self.gbuffer.albedo);
            graph.GL.passUniform(sh, "view_pos", cam.pos);
            graph.GL.passUniform(sh, "exposure", self.exposure);
            graph.GL.passUniform(sh, "gamma", self.gamma);
            graph.GL.passUniform(sh, "screenSize", wh);
            graph.GL.passUniform(sh, "the_fucking_window_offset", window_offset);
            graph.GL.passUniform(sh, "draw_debug", self.debug_light_coverage);

            graph.GL.passUniform(sh, "cam_view", cam.getViewMatrix());
            graph.GL.passUniform(sh, "view", view);

            self.point_light_batch.draw();
        }
        {
            const sh = self.shader.spot;
            c.glUseProgram(sh);
            c.glBindVertexArray(self.spot_light_batch.vao);
            c.glBindTextureUnit(0, self.gbuffer.pos);
            c.glBindTextureUnit(1, self.gbuffer.normal);
            c.glBindTextureUnit(2, self.gbuffer.albedo);
            graph.GL.passUniform(sh, "view_pos", cam.pos);
            graph.GL.passUniform(sh, "exposure", self.exposure);
            graph.GL.passUniform(sh, "gamma", self.gamma);
            graph.GL.passUniform(sh, "screenSize", wh);
            graph.GL.passUniform(sh, "the_fucking_window_offset", window_offset);
            graph.GL.passUniform(sh, "draw_debug", self.debug_light_coverage);

            graph.GL.passUniform(sh, "cam_view", cam.getViewMatrix());
            graph.GL.passUniform(sh, "view", view);

            self.spot_light_batch.draw();
        }
    }

    pub fn deinit(self: *Self) void {
        self.draw_calls.deinit(self.alloc);
        self.sun_batch.deinit();
        self.point_light_batch.deinit();
        self.spot_light_batch.deinit();
        self.decal_batch.deinit();
    }

    fn bindMainFramebufferAndVp(_: *Self, screen_area: graph.Rect, screen_dim: graph.Vec2f) void {
        const y_: i32 = @intFromFloat(screen_dim.y - (screen_area.y + screen_area.h));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(
            @intFromFloat(screen_area.x),
            y_,
            @intFromFloat(screen_area.w),
            @intFromFloat(screen_area.h),
        );
    }
};
//In forward, we just do the draw call
//otherwise, we need to draw that and the next
//then draw it again later? yes

const GBuffer = struct {
    buffer: c_uint = 0,
    depth: c_uint = 0,
    pos: c_uint = 0,
    normal: c_uint = 0,
    albedo: c_uint = 0,

    scr_w: i32 = 0,
    scr_h: i32 = 0,

    pub fn updateResolution(self: *@This(), new_w: i32, new_h: i32) void {
        if (new_w != self.scr_w or new_h != self.scr_h) {
            c.glDeleteTextures(1, &self.pos);
            c.glDeleteTextures(1, &self.normal);
            c.glDeleteTextures(1, &self.albedo);
            c.glDeleteRenderbuffers(1, &self.depth);
            c.glDeleteFramebuffers(1, &self.buffer);
            self.* = create(new_w, new_h);
        }
    }

    pub fn create(scrw: i32, scrh: i32) @This() {
        var ret: GBuffer = .{};
        ret.scr_w = scrw;
        ret.scr_h = scrh;
        c.glGenFramebuffers(1, &ret.buffer);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, ret.buffer);
        const pos_fmt = c.GL_RGBA32F;
        const norm_fmt = c.GL_RGBA16F;

        c.glGenTextures(1, &ret.pos);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.pos);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, pos_fmt, scrw, scrh, 0, c.GL_RGBA, c.GL_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, ret.pos, 0);

        c.glGenTextures(1, &ret.normal);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.normal);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, norm_fmt, scrw, scrh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT1, c.GL_TEXTURE_2D, ret.normal, 0);

        c.glGenTextures(1, &ret.albedo);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.albedo);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, scrw, scrh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT2, c.GL_TEXTURE_2D, ret.albedo, 0);

        const attachments = [_]c_int{ c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT1, c.GL_COLOR_ATTACHMENT2, 0 };
        c.glDrawBuffers(3, @ptrCast(&attachments[0]));

        c.glGenTextures(1, &ret.depth);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.depth);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_DEPTH_COMPONENT, scrw, scrh, 0, c.GL_DEPTH_COMPONENT, c.GL_FLOAT, null);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, ret.depth, 0);

        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE)
            std.debug.print("gbuffer FBO not complete\n", .{});
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        return ret;
    }
};

const Csm = struct {
    const CSM_COUNT = 4;
    fbo: c_uint,
    textures: c_uint,
    res: i32,

    mat_ubo: c_uint = 0,

    mats: [CSM_COUNT]Mat4 = undefined,
    pad: f32 = 15 * 32,

    fn createCsm(resolution: i32, cascade_count: i32, light_shader: c_uint) Csm {
        var fbo: c_uint = 0;
        var textures: c_uint = 0;
        c.glGenFramebuffers(1, &fbo);
        c.glGenTextures(1, &textures);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, textures);
        c.glTexImage3D(
            c.GL_TEXTURE_2D_ARRAY,
            0,
            c.GL_DEPTH_COMPONENT32F,
            resolution,
            resolution,
            cascade_count,
            0,
            c.GL_DEPTH_COMPONENT,
            c.GL_FLOAT,
            null,
        );
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_BORDER);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_BORDER);

        const border_color = [_]f32{1} ** 4;
        c.glTexParameterfv(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_BORDER_COLOR, &border_color);

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glFramebufferTexture(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, textures, 0);
        c.glDrawBuffer(c.GL_NONE);
        c.glReadBuffer(c.GL_NONE);

        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        if (status != c.GL_FRAMEBUFFER_COMPLETE)
            std.debug.print("Framebuffer is broken\n", .{});

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        var lmu: c_uint = 0;
        {
            c.glGenBuffers(1, &lmu);
            c.glBindBuffer(c.GL_UNIFORM_BUFFER, lmu);
            c.glBufferData(c.GL_UNIFORM_BUFFER, @sizeOf([4][4]f32) * CSM_COUNT, null, c.GL_DYNAMIC_DRAW);
            c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, lmu);
            c.glBindBuffer(c.GL_UNIFORM_BUFFER, 0);

            const li = c.glGetUniformBlockIndex(light_shader, "LightSpaceMatrices");
            c.glUniformBlockBinding(light_shader, li, 0);
        }

        return .{
            .fbo = fbo,
            .textures = textures,
            .res = resolution,
            .mat_ubo = lmu,
        };
    }

    pub fn calcMats(self: *Csm, fov: f32, aspect: f32, near: f32, far: f32, last_frame_view_mat: Mat4, sun_dir: Vec3, planes: [CSM_COUNT - 1]f32) void {
        self.mats = self.getLightMatrices(fov, aspect, near, far, last_frame_view_mat, sun_dir, planes);
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, self.mat_ubo);
        for (self.mats, 0..) |mat, i| {
            const ms = @sizeOf([4][4]f32);
            c.glBufferSubData(c.GL_UNIFORM_BUFFER, @as(c_long, @intCast(i)) * ms, ms, &mat.data[0][0]);
        }
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, 0);
    }

    pub fn draw(csm: *Csm, rend: *const Renderer) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, csm.fbo);
        c.glDisable(graph.c.GL_SCISSOR_TEST); //BRUH
        c.glViewport(0, 0, csm.res, csm.res);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);

        const sh = rend.shader.csm;
        c.glUseProgram(sh);
        for (rend.draw_calls.items) |dc| {
            c.glBindVertexArray(dc.vao);
            c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
        }
    }

    fn getLightMatrices(self: *const Csm, fov: f32, aspect: f32, near: f32, far: f32, cam_view: Mat4, light_dir: Vec3, planes: [CSM_COUNT - 1]f32) [CSM_COUNT]Mat4 {
        var ret: [CSM_COUNT]Mat4 = undefined;
        //fov, aspect, near, far, cam_view, light_Dir
        for (0..CSM_COUNT) |i| {
            if (i == 0) {
                ret[i] = self.getLightMatrix(fov, aspect, near, planes[i], cam_view, light_dir);
            } else if (i < CSM_COUNT - 1) {
                ret[i] = self.getLightMatrix(fov, aspect, planes[i - 1], planes[i], cam_view, light_dir);
            } else {
                ret[i] = self.getLightMatrix(fov, aspect, planes[i - 1], far, cam_view, light_dir);
            }
        }
        return ret;
    }

    fn getLightMatrix(self: *const Csm, fov: f32, aspect: f32, near: f32, far: f32, cam_view: Mat4, light_dir: Vec3) Mat4 {
        const cam_persp = graph.za.perspective(fov, aspect, near, far);
        const corners = getFrustumCornersWorldSpace(cam_persp.mul(cam_view));
        var center = Vec3.zero();
        for (corners) |corner| {
            center = center.add(corner.toVec3());
        }
        center = center.scale(1.0 / @as(f32, @floatFromInt(corners.len)));
        const lview = graph.za.lookAt(
            center.add(light_dir),
            center,
            Vec3.new(0, 1, 0),
        );
        var min_x = std.math.floatMax(f32);
        var min_y = std.math.floatMax(f32);
        var min_z = std.math.floatMax(f32);

        var max_x = -std.math.floatMax(f32);
        var max_y = -std.math.floatMax(f32);
        var max_z = -std.math.floatMax(f32);
        for (corners) |corner| {
            const trf = lview.mulByVec4(corner);
            min_x = @min(min_x, trf.x());
            min_y = @min(min_y, trf.y());
            min_z = @min(min_z, trf.z());

            max_x = @max(max_x, trf.x());
            max_y = @max(max_y, trf.y());
            max_z = @max(max_z, trf.z());
        }

        const tw = self.pad;
        min_z = if (min_z < 0) min_z * tw else min_z / tw;
        max_z = if (max_z < 0) max_z / tw else max_z * tw;

        //const ortho = graph.za.orthographic(-20, 20, -20, 20, 0.1, 300).mul(lview);
        const ortho = graph.za.orthographic(min_x, max_x, min_y, max_y, min_z, max_z).mul(lview);
        return ortho;
    }

    fn getFrustumCornersWorldSpace(frustum: Mat4) [8]graph.za.Vec4 {
        const inv = frustum.inv();
        var corners: [8]graph.za.Vec4 = undefined;
        var i: usize = 0;
        for (0..2) |x| {
            for (0..2) |y| {
                for (0..2) |z| {
                    const pt = inv.mulByVec4(graph.za.Vec4.new(
                        2 * @as(f32, @floatFromInt(x)) - 1,
                        2 * @as(f32, @floatFromInt(y)) - 1,
                        2 * @as(f32, @floatFromInt(z)) - 1,
                        1.0,
                    ));
                    corners[i] = pt.scale(1 / pt.w());
                    i += 1;
                }
            }
        }
        if (i != 8)
            unreachable;

        return corners;
    }
};

pub fn LightBatchGeneric(comptime vertT: type) type {
    return struct {
        pub const Vertex = packed struct {
            pos: graph.Vec3f,
        };

        vbo: c_uint = 0,
        vao: c_uint = 0,
        ebo: c_uint = 0,
        ivbo: c_uint = 0,

        alloc: std.mem.Allocator,
        vertices: std.ArrayList(Vertex) = .{},
        indicies: std.ArrayList(u32) = .{},
        inst: std.ArrayList(vertT) = .{},

        pub fn init(alloc: std.mem.Allocator, asset_dir: std.fs.Dir, obj_name: []const u8) !@This() {
            var ret = @This(){
                .alloc = alloc,
            };

            c.glGenVertexArrays(1, &ret.vao);
            c.glGenBuffers(1, &ret.vbo);
            c.glGenBuffers(1, &ret.ebo);
            graph.GL.generateVertexAttributes(ret.vao, ret.vbo, Vertex);
            c.glBindVertexArray(ret.vao);
            c.glGenBuffers(1, &ret.ivbo);
            c.glEnableVertexAttribArray(1);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, ret.ivbo);
            graph.GL.generateVertexAttributesEx(ret.vao, ret.ivbo, vertT, 1);
            c.glBindVertexArray(ret.vao);
            const count = @typeInfo(vertT).@"struct".fields.len;
            for (1..count + 1) |i|
                c.glVertexAttribDivisor(@intCast(i), 1);

            var obj = try mesh.loadObj(alloc, asset_dir, obj_name, 1);
            defer obj.deinit();
            if (obj.meshes.items.len == 0) return error.invalidIcoSphere;
            for (obj.meshes.items[0].vertices.items) |v| {
                try ret.vertices.append(ret.alloc, .{ .pos = graph.Vec3f.new(v.x, v.y, v.z) });
            }
            try ret.indicies.appendSlice(ret.alloc, obj.meshes.items[0].indicies.items);
            ret.pushVertexData();

            return ret;
        }

        pub fn deinit(self: *@This()) void {
            self.vertices.deinit(self.alloc);
            self.indicies.deinit(self.alloc);
            self.inst.deinit(self.alloc);
        }

        pub fn pushVertexData(self: *@This()) void {
            c.glBindVertexArray(self.vao);
            graph.GL.bufferData(c.GL_ARRAY_BUFFER, self.vbo, Vertex, self.vertices.items);
            graph.GL.bufferData(c.GL_ELEMENT_ARRAY_BUFFER, self.ebo, u32, self.indicies.items);
            graph.GL.bufferData(c.GL_ARRAY_BUFFER, self.ivbo, vertT, self.inst.items);
        }

        pub fn clear(self: *@This()) void {
            self.inst.clearRetainingCapacity();
        }

        pub fn draw(self: *@This()) void {
            c.glDrawElementsInstanced(
                c.GL_TRIANGLES,
                @intCast(self.indicies.items.len),
                c.GL_UNSIGNED_INT,
                null,
                @intCast(self.inst.items.len),
            );
            c.glBindVertexArray(0);
        }
    };
}

const HdrBuffer = struct {
    fb: c_uint = 0,
    color: c_uint = 0,

    scr_w: i32 = 0,
    scr_h: i32 = 0,

    pub fn updateResolution(self: *@This(), new_w: i32, new_h: i32) void {
        if (new_w != self.scr_w or new_h != self.scr_h) {
            c.glDeleteTextures(1, &self.color);
            c.glDeleteFramebuffers(1, &self.fb);
            self.* = create(new_w, new_h);
        }
    }

    pub fn create(scrw: i32, scrh: i32) @This() {
        var ret: HdrBuffer = .{};
        ret.scr_w = scrw;
        ret.scr_h = scrh;

        c.glGenFramebuffers(1, &ret.fb);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, ret.fb);

        c.glGenTextures(1, &ret.color);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.color);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, scrw, scrh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, ret.color, 0);

        const attachments = [_]c_int{ c.GL_COLOR_ATTACHMENT0, 0 };
        c.glDrawBuffers(1, @ptrCast(&attachments[0]));

        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE)
            std.debug.print("gbuffer FBO not complete\n", .{});
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        return ret;
    }
};

pub const PointLightVertex = packed struct {
    light_pos: graph.Vec3f,
    ambient: graph.Vec3f = graph.Vec3f.new(0.1, 0.1, 0.1),
    diffuse: graph.Vec3f = graph.Vec3f.new(1, 1, 1),
    specular: graph.Vec3f = graph.Vec3f.new(4, 4, 4),

    constant: f32 = 1,
    linear: f32 = 0.7,
    quadratic: f32 = 1.8,
};

pub const SpotLightVertex = packed struct {
    pos: graph.Vec3f,

    ambient: graph.Vec3f = graph.Vec3f.new(0.1, 0.1, 0.1),
    diffuse: graph.Vec3f = graph.Vec3f.new(1, 1, 1),
    specular: graph.Vec3f = graph.Vec3f.new(4, 4, 4),

    constant: f32 = 1,
    linear: f32 = 0.7,
    quadratic: f32 = 1.8,

    cutoff: f32,
    cutoff_outer: f32,

    dir: graph.Vec3f, //These form a quat lol
    w: f32,
};

pub const DecalVertex = packed struct {
    pos: graph.Vec3f,
    ext: graph.Vec3f,
};

pub const PointLightInstanceBatch = LightBatchGeneric(PointLightVertex);
pub const SpotLightInstanceBatch = LightBatchGeneric(SpotLightVertex);
pub const DecalBatch = LightBatchGeneric(DecalVertex);
