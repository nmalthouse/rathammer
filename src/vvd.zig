const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;
const mdl = @import("mdl.zig");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const vpk = @import("vpk.zig");
const edit = @import("editor.zig");
const load_pool = @import("thread_pool.zig");

const VVD_MAGIC_STRING = "IDSV";
const MAX_LODS = 8;
const VertexHeader_1 = struct {
    id: [4]u8, // MODEL_VERTEX_FILE_ID
    version: u32, // MODEL_VERTEX_FILE_VERSION
    checksum: u32, // same as studiohdr_t, ensures sync      ( Note: maybe long instead of int in versions other than 4. )
    numLODs: u32, // num of valid lods
    numLODVertexes: [MAX_LODS]u32, // num verts for desired root lod
    numFixups: u32, // num of vertexFileFixup_t
    fixupTableStart: u32, // offset from base to fixup table
    vertexDataStart: u32, // offset from base to vertex block
    tangentDataStart: u32, // offset from base to tangent block
};

const FIXUP_SIZE = 4 * 4;
const FixupEntry = struct {
    lod: i32,
    source_vertex_id: u32,
    num_vertex: u32,
};

const V3 = struct { x: f32, y: f32, z: f32 };
const V2 = struct { x: f32, y: f32 };

const BoneWeightLen = 16;
const Vertex = struct {
    boneweight: [BoneWeightLen]u8,
    pos: V3,
    norm: V3,
    uv: V2,
};

const Vtx = struct {
    // this structure is in <mod folder>/src/public/optimize.h
    const VtxHeader = struct {
        // file version as defined by OPTIMIZED_MODEL_FILE_VERSION (currently 7)
        version: u32,

        // hardware params that affect how the model is to be optimized.
        vertCacheSize: u32,
        maxBonesPerStrip: u16,
        maxBonesPerTri: u16,
        maxBonesPerVert: u32,

        // must match checkSum in the .mdl
        checkSum: u32,

        numLODs: u32, // Also specified in ModelHeader_t's and should match

        // Offset to materialReplacementList Array. one of these for each LOD, 8 in total
        materialReplacementListOffset: u32,

        //Defines the size and location of the body part array
        numBodyParts: u32,
        bodyPartOffset: u32,
    };

    pub const BodyPart_h1 = struct {
        num_model: u32,
        model_offset: u32,
    };

    pub const Model_h1 = struct {
        num_lods: u32,
        lod_offset: u32,
    };

    pub const ModelLod_h1 = struct {
        num_mesh: u32,
        mesh_offset: u32,
        switch_point: f32,
    };

    pub const Mesh_h1 = struct {
        num_strip_group: u32,
        sg_offset: u32,
        flags: u8,
    };

    pub const StripGroup = struct {
        num_verts: u32,
        vert_offset: u32,
        num_index: u32,
        index_offset: u32,

        num_strips: u32,
        strip_offset: u32,
        flags: u8,
        //num_topo: u32,
        //topo_offset: u32,
    };

    pub const StripHeader = struct {
        pub const Flags = enum(u8) {
            none = 0x0,
            trilist = 0x1,
            tristrip = 0x2,
        };

        num_index: u32,
        index_offset: u32,
        num_verts: u32,
        vert_offset: u32,
        bones: u16,
        flags: u8,
        num_bone_state: u32,
        bone_state_offset: u32,
    };

    pub const Vertex = struct {
        bone_weight_index: [3]u8,
        num_bones: u8,
        orig_mesh_vert_id: u16,

        bone_id: [3]u8,
    };

    pub const MaterialReplacmentHdr = struct {
        num: u32,
        offset: u32,
    };

    pub const MaterialReplacment = struct {
        matid: u16,
        name_offset: u32,
    };
};

fn dummyPrint(_: []const u8, _: anytype) void {}

pub const MeshDeferred = struct {
    mesh: *MultiMesh, //Allocated, so vtables work
    res_id: vpk.VpkResId,
    texture_ids: std.ArrayList(vpk.VpkResId),
};

fn setFbs(fbs: *std.io.FixedBufferStream([]const u8), pos: usize) !void {
    if (pos >= fbs.buffer.len) return error.outOfBounds;
    fbs.pos = pos;
}

//it sucks but it works
//there is very little version checking.
pub fn loadModelCrappy(
    pool_state: *load_pool.Context,
    res_id: vpk.VpkResId,
    mdl_name: []const u8,
    vpkctx: *vpk.Context,
) !MeshDeferred {
    const thread_state = try pool_state.getState();
    const mdln = blk: {
        if (std.mem.endsWith(u8, mdl_name, ".mdl"))
            break :blk mdl_name[0 .. mdl_name.len - 4];
        break :blk mdl_name;
    };

    const print = dummyPrint;
    const alloc = pool_state.alloc;
    //const print = std.debug.print;
    var info = try mdl.doItCrappy(pool_state.alloc, try vpkctx.getFileTempFmtBuf(
        "mdl",
        "{s}",
        .{mdln},
        .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc },
        true,
    ) orelse return error.nomdl, print);
    defer {
        for (info.texture_paths.items) |item|
            alloc.free(item);
        for (info.texture_names.items) |item|
            alloc.free(item);
        info.texture_paths.deinit(alloc);
        info.texture_names.deinit(alloc);
        info.vert_offsets.deinit(alloc);
    }
    var scratch: std.ArrayList(u8) = .{};
    defer scratch.deinit(alloc);
    var texts: std.ArrayList(vpk.VpkResId) = .{};
    outer: for (info.texture_names.items) |tname| {
        inner: for (info.texture_paths.items) |tpath| {
            scratch.clearRetainingCapacity();
            var real_tpath = tpath;
            if (std.mem.startsWith(u8, tname, tpath)) {
                // This is an example from black mesa. WTF??
                //tpath = models\props_pipes\
                //tname = models/props_pipes/pipesystem01a_skin1
                //
                //Not only do we have to do this dumb workaround, we have to sanitize the strings before passing into vpk

                //std.debug.print("Your model has activated something stupid!\n", .{});
                real_tpath = "";
            }

            try scratch.print(alloc, "{s}{s}", .{ real_tpath, tname });
            const tex_res_id = try vpkctx.getResourceIdFmt("vmt", "materials/{s}", .{scratch.items}, true) orelse continue :inner;
            try pool_state.loadTexture(tex_res_id, vpkctx);
            try texts.append(alloc, tex_res_id);
            continue :outer;
        }
        try texts.append(alloc, 0); //Put missing
    }
    var mmesh = try pool_state.alloc.create(MultiMesh);
    errdefer pool_state.alloc.destroy(mmesh);
    mmesh.* = MultiMesh.init(alloc);
    mmesh.hull_min = info.hull_min;
    mmesh.hull_max = info.hull_max;
    const w = std.io.null_writer;
    {
        const slice_vvd = try vpkctx.getFileTempFmtBuf(
            "vvd",
            "{s}",
            .{mdln},
            .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc },
            true,
        ) orelse return error.notFound;
        var fbs_vvd = std.io.FixedBufferStream([]const u8){ .buffer = slice_vvd, .pos = 0 };
        const r = fbs_vvd.reader();
        const h1 = try parseStruct(VertexHeader_1, .little, r);
        if (!std.mem.eql(u8, VVD_MAGIC_STRING, &h1.id))
            return error.invalidVVD;
        print("{}\n", .{h1});

        fbs_vvd.pos = h1.fixupTableStart;
        var fixups: std.ArrayList(FixupEntry) = .{};
        defer fixups.deinit(alloc);
        for (0..h1.numFixups) |_| {
            const fu = try parseStruct(FixupEntry, .little, r);
            print("{}\n", .{fu});
            try fixups.append(alloc, fu);
        }

        var verts: std.ArrayList(Vertex) = .{};
        defer verts.deinit(alloc);
        fbs_vvd.pos = h1.vertexDataStart;
        for (0..h1.numLODVertexes[0]) |_| {
            const vert = try parseStruct(Vertex, .little, r);
            try verts.append(alloc, vert);
        }
        var total: usize = 0;
        if (fixups.items.len > 0) {
            for (fixups.items) |fu| {
                for (verts.items[fu.source_vertex_id .. fu.source_vertex_id + fu.num_vertex]) |v| {
                    try mmesh.vertices.append(mmesh.alloc, .{
                        .x = v.pos.x,
                        .y = v.pos.y,
                        .z = v.pos.z,
                        .u = v.uv.x,
                        .v = v.uv.y,
                        .nx = v.norm.x,
                        .ny = v.norm.y,
                        .nz = v.norm.z,
                        .color = 0xff_ff_ff_ff,
                    });
                    try w.print("v {d} {d} {d}\n", .{ v.pos.x, v.pos.y, v.pos.z });
                }
                total += fu.num_vertex;
            }
            print("TOTAL VERCTS FIXED {d}\n", .{total});
        } else {
            for (verts.items) |v| {
                try w.print("v {d} {d} {d}\n", .{ v.pos.x, v.pos.y, v.pos.z });
                try mmesh.vertices.append(mmesh.alloc, .{
                    .x = v.pos.x,
                    .y = v.pos.y,
                    .z = v.pos.z,
                    .u = v.uv.x,
                    .v = v.uv.y,
                    .nx = 0,
                    .ny = 0,
                    .nz = 0,
                    .color = 0xff_ff_ff_ff,
                });
            }
        }
    }
    {

        //Load vtx
        const slice = try vpkctx.getFileTempFmtBuf(
            "vtx",
            "{s}.dx90",
            .{mdln},

            .{ .list = &thread_state.vtf_file_buffer, .alloc = thread_state.alloc },
            true,
        ) orelse return error.broken;
        var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
        const r1 = fbs.reader();
        const header_pos = fbs.pos;
        const hv1 = try parseStruct(Vtx.VtxHeader, .little, r1);
        if (hv1.version >= 49)
            print("NEW VERSION {d}\n", .{hv1.version});
        print("{}\n", .{hv1});
        try setFbs(&fbs, header_pos + hv1.bodyPartOffset);
        //if (hv1.bodyPartOffset != 36) return error.crappyVtxParser;

        var max: u32 = 0;
        const bpstart = fbs.pos;
        for (0..hv1.numBodyParts) |bpi| {
            if (bpi > 0)
                break; //Only do the first, there is some bug with bounds
            const BP_SIZE = 8;
            var st = bpstart + bpi * BP_SIZE;
            try setFbs(&fbs, st);

            const bp = try parseStruct(Vtx.BodyPart_h1, .little, r1);
            print("{}\n", .{bp});
            try setFbs(&fbs, st + bp.model_offset);
            st = fbs.pos;
            {
                const mh = try parseStruct(Vtx.Model_h1, .little, r1);
                //We only read the first lod for now
                try setFbs(&fbs, st + mh.lod_offset);
                print("{}\n", .{mh});

                st = fbs.pos;
                var mesh_offset: u16 = 0;
                {
                    const mlod = try parseStruct(Vtx.ModelLod_h1, .little, r1);
                    print("{}\n", .{mlod});
                    try setFbs(&fbs, st + mlod.mesh_offset);
                    const mesh_start = fbs.pos;
                    for (0..mlod.num_mesh) |mi| {
                        const MESH_SIZE = 9;
                        st = mesh_start + mi * MESH_SIZE;
                        try setFbs(&fbs, st);
                        const mhh = try parseStruct(Vtx.Mesh_h1, .little, r1);

                        print("{}\n", .{mhh});

                        var strip_vert_count: u16 = 0;

                        const mesh_h_start = st + mhh.sg_offset;
                        for (0..mhh.num_strip_group) |si| {
                            const STRIP_GROUP_SIZE = 25;
                            st = mesh_h_start + si * STRIP_GROUP_SIZE;
                            try setFbs(&fbs, st);
                            const SG = try parseStruct(Vtx.StripGroup, .little, r1);
                            print("{}\n", .{SG});

                            const sg_start = st;

                            var vert_table: std.ArrayList(u16) = .{};
                            defer vert_table.deinit(alloc);
                            try setFbs(&fbs, sg_start + SG.vert_offset);
                            for (0..SG.num_verts) |_| {
                                const v = try parseStruct(Vtx.Vertex, .little, r1);
                                try vert_table.append(alloc, mesh_offset + v.orig_mesh_vert_id);
                            }
                            var indices: std.ArrayList(u16) = .{};
                            try indices.ensureTotalCapacity(alloc, SG.num_index);
                            defer indices.deinit(alloc);
                            try setFbs(&fbs, sg_start + SG.index_offset);
                            for (0..SG.num_index) |_| {
                                try indices.append(alloc, try r1.readInt(u16, .little));
                            }

                            try setFbs(&fbs, sg_start + SG.strip_offset);
                            st = fbs.pos;
                            const vtt = vert_table.items;
                            const newm = try mmesh.newMesh(texts.items[mi]);
                            for (0..SG.num_strips) |sii| {
                                try w.print("o mod_{d}_{d}_{d}\n", .{ mi, si, sii });
                                const hh = try parseStruct(Vtx.StripHeader, .little, r1);
                                print("{}\n", .{hh});
                                const index_pos = hh.index_offset;
                                if (index_pos >= indices.items.len or index_pos + hh.num_index > indices.items.len)
                                    return error.invalidIndex;
                                const sl = indices.items[hh.index_offset .. hh.num_index + hh.index_offset];
                                const vttt = vtt;
                                //const vttt = vtt[hh.vert_offset .. hh.vert_offset + hh.num_verts];
                                strip_vert_count += @intCast(hh.num_verts);
                                const fl: Vtx.StripHeader.Flags = std.meta.intToEnum(
                                    Vtx.StripHeader.Flags,
                                    hh.flags,
                                ) catch {
                                    std.debug.print("Invalid vtx flags: {x} \n", .{hh.flags});
                                    return error.invalidFlags;
                                };
                                switch (fl) {
                                    .trilist, .none => {
                                        for (0..@divFloor(sl.len, 3)) |i| {
                                            const j = i * 3;
                                            try newm.indicies.appendSlice(newm.alloc, &.{
                                                vttt[sl[j + 2]],
                                                vttt[sl[j + 1]],
                                                vttt[sl[j]],
                                            });
                                            max = @max(max, vttt[sl[j]] + 1);
                                            max = @max(max, vttt[sl[j + 1]] + 1);
                                            max = @max(max, vttt[sl[j + 2]] + 1);
                                            try w.print("f {d} {d} {d}\n", .{
                                                vttt[sl[j]] + 1,
                                                vttt[sl[j + 1]] + 1,
                                                vttt[sl[j + 2]] + 1,
                                            });
                                        }
                                    },
                                    else => return error.unsupportedVertexStrip,
                                }
                            }
                        }
                        if (mi >= info.vert_offsets.items.len) {
                            std.debug.print("too many models\n", .{});
                            break;
                        }
                        mesh_offset += info.vert_offsets.items[mi];
                    }

                    //try r1.skipBytes(mhh.sg_offset - 9, .{}); //36 = mlod.offset - Sizeof(ModelLod_h1

                    if (false) {
                        fbs.pos = header_pos + hv1.materialReplacementListOffset;
                        const mathdr = try parseStruct(Vtx.MaterialReplacmentHdr, .little, r1);
                        print("{}\n", .{mathdr});
                        for (0..mathdr.num) |_| {
                            const start = fbs.pos;
                            const rep = try parseStruct(Vtx.MaterialReplacment, .little, r1);
                            print("{}\n", .{rep});
                            const str: [*c]const u8 = &slice[start + rep.name_offset];
                            print("{s}\n", .{str});
                        }
                    }
                }
                //break; //Read the first only
            }
        }
    }
    //mmesh.initGl();
    //mmesh.setData();
    return .{ .mesh = mmesh, .res_id = res_id, .texture_ids = texts };
}

//One vertex buffer, many index buffers
pub const MultiMesh = struct {
    const c = graph.c;
    const GL = graph.GL;
    const Self = @This();
    const MeshVert = graph.meshutil.MeshVert;
    pub const Mesh = struct {
        indicies: std.ArrayList(u16),
        ebo: c_uint,
        vao: c_uint,
        texture_id: c_uint,
        tex_res_id: vpk.VpkResId,
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator, tex_res: vpk.VpkResId) @This() {
            return .{
                .ebo = 0,
                .vao = 0,
                .alloc = alloc,
                .indicies = .{},
                .texture_id = 0,
                .tex_res_id = tex_res,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.indicies.deinit(self.alloc);
        }
    };

    vbo: c_uint,
    vertices: std.ArrayList(MeshVert),
    meshes: std.ArrayList(Mesh),
    alloc: std.mem.Allocator,

    hull_min: Vec3 = Vec3.zero(),
    hull_max: Vec3 = Vec3.zero(),

    notify_vt: load_pool.DeferredNotifyVtable,

    pub fn init(alloc: std.mem.Allocator) @This() {
        return Self{
            .vertices = .{},
            .meshes = .{},
            .alloc = alloc,
            .vbo = 0,
            .notify_vt = .{ .notify_fn = &notify },
        };

        //c.glGenBuffers(1, &ret.vbo);

        //GL.bufferData(c.GL_ELEMENT_ARRAY_BUFFER, ret.ebo, u32, ret.indicies.items);
    }

    pub fn notify(vt: *load_pool.DeferredNotifyVtable, id: vpk.VpkResId, editor: *edit.Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("notify_vt", vt));
        for (self.meshes.items) |*mesh| {
            if (mesh.tex_res_id == id) {
                mesh.texture_id = (editor.textures.get(id) orelse continue).id;
            }
        }
    }

    /// This should only be called from the active gl thread;
    pub fn initGl(self: *Self) void {
        c.glGenBuffers(1, &self.vbo);
        for (self.meshes.items) |*mesh| {
            c.glGenBuffers(1, &mesh.ebo);
            c.glGenVertexArrays(1, &mesh.vao);
            GL.floatVertexAttrib(mesh.vao, self.vbo, 0, 3, MeshVert, "x"); //XYZ
            GL.floatVertexAttrib(mesh.vao, self.vbo, 1, 2, MeshVert, "u"); //RGBA
            GL.floatVertexAttrib(mesh.vao, self.vbo, 2, 3, MeshVert, "nx"); //RGBA
            GL.intVertexAttrib(mesh.vao, self.vbo, 3, 1, MeshVert, "color", c.GL_UNSIGNED_INT);
            GL.floatVertexAttrib(mesh.vao, self.vbo, 4, 3, MeshVert, "tx");
        }

        self.setData();
    }

    pub fn newMesh(self: *Self, tex: vpk.VpkResId) !*Mesh {
        try self.meshes.append(self.alloc, Mesh.init(self.alloc, tex));
        return &self.meshes.items[self.meshes.items.len - 1];
    }

    pub fn setData(self: *Self) void {
        for (self.meshes.items) |mesh| {
            c.glBindVertexArray(mesh.vao);
            GL.bufferData(c.GL_ARRAY_BUFFER, self.vbo, MeshVert, self.vertices.items);
            GL.bufferData(c.GL_ELEMENT_ARRAY_BUFFER, mesh.ebo, u16, mesh.indicies.items);
        }
    }

    pub fn deinit(self: *Self) void {
        self.vertices.deinit(self.alloc);
        for (self.meshes.items) |*mesh| {
            mesh.deinit();
        }
        self.meshes.deinit(self.alloc);
    }

    pub fn drawSimple(self: *Self, view: graph.za.Mat4, model: graph.za.Mat4, shader: c_uint) void {
        c.glUseProgram(shader);
        GL.passUniform(shader, "view", view);
        GL.passUniform(shader, "model", model);
        const diffuse_loc = c.glGetUniformLocation(shader, "diffuse_texture");
        for (self.meshes.items) |mesh| {
            c.glBindVertexArray(mesh.vao);
            c.glUniform1i(diffuse_loc, 0);
            c.glBindTextureUnit(0, mesh.texture_id);

            c.glDrawElements(c.GL_TRIANGLES, @as(c_int, @intCast(mesh.indicies.items.len)), c.GL_UNSIGNED_SHORT, null);
        }
    }
};
