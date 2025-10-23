const graph = @import("graph");
const vpk = @import("vpk.zig");
const vtf = @import("vtf.zig");
const std = @import("std");
pub const Skybox = struct {
    const Self = @This();
    const SkyBatch = graph.NewBatch(graph.ImmediateDrawingContext.VtxFmt.Textured_3D_NC, .{ .index_buffer = true, .primitive_mode = .triangles });
    meshes: std.ArrayList(SkyBatch),
    textures: std.ArrayList(graph.Texture),
    shader: c_uint,
    alloc: std.mem.Allocator,
    sky_name: []const u8,

    pub fn init(alloc: std.mem.Allocator, shader_dir: std.fs.Dir) !Self {
        const sky_shad = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "cubemap.vert", .t = .vert },
            .{ .path = "cubemap.frag", .t = .frag },
        });
        return Self{
            .alloc = alloc,
            .meshes = .{},
            .textures = .{},
            .shader = sky_shad,
            .sky_name = "",
        };
    }

    pub fn loadSky(self: *Self, sky_name: []const u8, vpkctx: *vpk.Context) !void {
        //TODO clear out the old ones;
        self.sky_name = sky_name;
        const a = 1;
        const t = 1;
        const b = 0.006; //Inset the uv sligtly to prevent seams from showing
        //Maybe use clamptoedge?
        const o = 1 - b;
        const uvs = [4]graph.Vec2f{
            .{ .x = b, .y = b },
            .{ .x = o, .y = b },
            .{ .x = o, .y = o },
            .{ .x = b, .y = o },
        };
        const verts = [_]SkyBatch.VtxType{
            .{ .uv = uvs[3], .pos = .{ .y = -a, .z = -a, .x = t } },
            .{ .uv = uvs[2], .pos = .{ .y = a, .z = -a, .x = t } },
            .{ .uv = uvs[1], .pos = .{ .y = a, .z = a, .x = t } },
            .{ .uv = uvs[0], .pos = .{ .y = -a, .z = a, .x = t } },

            .{ .uv = uvs[1], .pos = .{ .y = -a, .z = a, .x = -t } },
            .{ .uv = uvs[0], .pos = .{ .y = a, .z = a, .x = -t } },
            .{ .uv = uvs[3], .pos = .{ .y = a, .z = -a, .x = -t } },
            .{ .uv = uvs[2], .pos = .{ .y = -a, .z = -a, .x = -t } },

            .{ .uv = uvs[1], .pos = .{ .x = -a, .z = a, .y = t } },
            .{ .uv = uvs[0], .pos = .{ .x = a, .z = a, .y = t } },
            .{ .uv = uvs[3], .pos = .{ .x = a, .z = -a, .y = t } },
            .{ .uv = uvs[2], .pos = .{ .x = -a, .z = -a, .y = t } },

            .{ .uv = uvs[3], .pos = .{ .x = -a, .z = -a, .y = -t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .z = -a, .y = -t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .z = a, .y = -t } },
            .{ .uv = uvs[0], .pos = .{ .x = -a, .z = a, .y = -t } },

            //top and bottom
            .{ .uv = uvs[3], .pos = .{ .x = -a, .y = -a, .z = t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .y = -a, .z = t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .y = a, .z = t } },
            .{ .uv = uvs[0], .pos = .{ .x = -a, .y = a, .z = t } },

            .{ .uv = uvs[0], .pos = .{ .x = -a, .y = a, .z = -t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .y = a, .z = -t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .y = -a, .z = -t } },
            .{ .uv = uvs[3], .pos = .{ .x = -a, .y = -a, .z = -t } },
        };
        const ind = [_]u32{
            2, 1, 0, 3, 2, 0,
        };
        const endings = [_][]const u8{ "ft", "bk", "lf", "rt", "up", "dn" };
        for (endings, 0..) |end, i| {
            const vtf_buf = try vpkctx.getFileTempFmt("vtf", "materials/skybox/{s}{s}", .{ sky_name, end }, true) orelse {
                std.debug.print("Cant find sky {s}{s}\n", .{ sky_name, end });
                continue;
            };
            const tex = vtf.loadTexture(vtf_buf, self.alloc) catch |err| {
                std.debug.print("Had an oopis {t}\n", .{err});
                continue;
            };
            var skybatch = SkyBatch.init(self.alloc);
            skybatch.appendVerts(verts[i * 4 .. i * 4 + 4]);
            skybatch.appendIndex(&ind);
            skybatch.pushVertexData();
            try self.meshes.append(self.alloc, skybatch);
            try self.textures.append(self.alloc, tex);
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.meshes.items) |*i|
            i.deinit();
        for (self.textures.items) |*t|
            t.deinit();
        self.meshes.deinit(self.alloc);
        self.textures.deinit(self.alloc);
    }
};
