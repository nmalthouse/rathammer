const std = @import("std");
const graph = @import("graph");
const parse = @import("parse_common.zig");
const eql = std.mem.eql;

fn rgbExp(r: u8, exp: i8) u8 {
    //if (true) return r;
    if (@abs(exp) >= 8) return r;
    if (exp > 0) {
        return r <<| @as(u4, @intCast(exp));
    }
    return r >> @intCast(-exp);
}

const HEADER_LUMPS = 64;
const BSP_STRING = "VPSP";

const Header = struct {
    ident: [4]u8,
    version: i32,
    header_lumps: [HEADER_LUMPS]HeaderLump,
    revision: u32,
};

const HeaderLump = struct {
    file_offset: i32,
    length: i32,
    version: i32,
    ident: [4]u8,
};

/// From public/bspfile.h
const Lump_index = enum(u8) {
    entities = 0,
    planes = 1,
    texdata = 2,
    vertexes = 3,
    visibility = 4,
    nodes = 5,
    texinfo = 6,
    faces = 7,
    lighting = 8,
    occlusion = 9,
    leafs = 10,
    faceids = 11,
    edges = 12,
    surfedges = 13,
    models = 14,
    worldlights = 15,
    leaffaces = 16,
    leafbrushes = 17,
    brushes = 18,
    brushsides = 19,
    areas = 20,
    areaportals = 21,
    unused0 = 22,
    unused1 = 23,
    unused2 = 24,
    unused3 = 25,
    dispinfo = 26,
    originalfaces = 27,
    physdisp = 28,
    physcollide = 29,
    vertnormals = 30,
    vertnormalindices = 31,
    disp_lightmap_alphas = 32,
    disp_verts = 33,
    disp_lightmap_sample_positions = 34,
    game_lump = 35,
    leafwaterdata = 36,
    primitives = 37,
    primverts = 38,
    primindices = 39,
    pakfile = 40,
    clipportalverts = 41,
    cubemaps = 42,
    texdata_string_data = 43,
    texdata_string_table = 44,
    overlays = 45,
    leafmindisttowater = 46,
    face_macro_texture_info = 47,
    disp_tris = 48,
    physcollidesurface = 49,
    wateroverlays = 50,
    leaf_ambient_index_hdr = 51,
    leaf_ambient_index = 52,
    lighting_hdr = 53,
    worldlights_hdr = 54,
    leaf_ambient_lighting_hdr = 55,
    leaf_ambient_lighting = 56,
    xzippakfile = 57,
    faces_hdr = 58,
    map_flags = 59,
    overlay_fades = 60,
};

const NUM_LIGHTMAP = 4;
const Face = struct {
    plane_num: u16,
    side: u8,
    on_node: u8,
    first_edge: i32,
    num_edge: i16,
    tex_info: i16,
    disp_info: i16,
    surface_fog: i16,
    styles: [NUM_LIGHTMAP]u8,
    light_offset: i32,
    area: f32,
    lightmap_tex_min_luxel: [2]i32,
    lightmap_tex_size_luxel: [2]i32,

    orig_face: i32,

    num_prim: u16,
    first_prim: u16,
    smoothing_groups: u32,
};

fn getSlice(file_slice: []const u8, start: usize, length: usize) !std.io.FixedBufferStream([]const u8) {
    if (start >= file_slice.len or start + length >= file_slice.len) return error.outOfBounds;

    return std.io.FixedBufferStream([]const u8){ .buffer = file_slice[start .. start + length], .pos = 0 };
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const path = "/tmp/dump.bsp";
    const in = try std.fs.cwd().openFile(path, .{});
    var read_buf: [4096]u8 = undefined;
    var re = in.reader(&read_buf);

    const slice = try re.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(slice);

    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
    const r_tl = fbs.reader();

    var bmps = std.ArrayList(graph.Bitmap){};
    defer {
        for (bmps.items) |item|
            item.deinit();
        bmps.deinit(alloc);
    }
    var rpack = graph.RectPack.init(alloc);
    defer rpack.deinit();

    const h = try parse.parseStruct(Header, .little, r_tl);
    if (eql(u8, &h.ident, BSP_STRING)) return error.notAbsp;
    std.debug.print("BSP file version {d}, len {d}\n", .{ h.version, slice.len });

    for (h.header_lumps) |lump| {
        std.debug.print("Ident {any}\n", .{lump.ident});
    }
    {
        //const SUPPORTED_LIGHT_VERSION = 1;
        const light_index: u8 = @intFromEnum(Lump_index.lighting);
        const face_index: u8 = @intFromEnum(Lump_index.faces);
        const lump = h.header_lumps[face_index];
        const light_lump = h.header_lumps[light_index];
        //if (lump.version != SUPPORTED_LIGHT_VERSION) return error.unsupportedLightVersion;
        std.debug.print("SIZE {d}  guesss len {d}\n", .{ lump.length, @divExact(lump.length, @sizeOf(Face)) });
        var lfbs = try getSlice(slice, @intCast(lump.file_offset), @intCast(lump.length));

        for (0..@intCast(@divExact(lump.length, @sizeOf(Face)))) |_| {
            const face = try parse.parseStruct(Face, .little, lfbs.reader());
            const sz = face.lightmap_tex_size_luxel;
            const chan = 4;
            if (face.light_offset > 0) {
                const width = sz[0] + 1;
                const height = sz[1] + 1;
                //std.debug.print("lm {d} x {d} offset {d}\n", .{ face.lightmap_tex_size_luxel[0], face.lightmap_tex_size_luxel[1], face.light_offset });
                var light_fbs = try getSlice(slice, @intCast(light_lump.file_offset + face.light_offset), @intCast(width * height * chan));
                _ = &light_fbs;

                const temp = try alloc.alloc(u8, @intCast(width * height * 3));
                defer alloc.free(temp);
                for (0..@divExact(light_fbs.buffer.len, 4)) |p_i| {
                    const r: u8 = light_fbs.buffer[p_i * 4 + 0];
                    const g: u8 = light_fbs.buffer[p_i * 4 + 1];
                    const b: u8 = light_fbs.buffer[p_i * 4 + 2];
                    const exp: i8 = std.math.clamp(@as(i8, @bitCast(light_fbs.buffer[p_i * 4 + 3])), -7, 7);

                    temp[p_i * 3 + 0] = rgbExp(r, exp);
                    temp[p_i * 3 + 1] = rgbExp(g, exp);
                    temp[p_i * 3 + 2] = rgbExp(b, exp);
                }

                const bmp = try graph.Bitmap.initFromBuffer(alloc, temp, width, height, .rgb_8);
                const b_id = bmps.items.len;
                try bmps.append(alloc, bmp);

                try rpack.appendRect(b_id, width, height);
            }
        }

        //const r = lfbs.reader();
    }

    { //do the pack
        const size = try rpack.packOptimalSize();
        var out_bmp = try graph.Bitmap.initBlank(alloc, size.x, size.y, .rgb_8);
        defer out_bmp.deinit();

        for (rpack.rects.items) |rect| {
            try out_bmp.copySubR(@intCast(rect.x), @intCast(rect.y), &bmps.items[@intCast(rect.id)], 0, 0, @intCast(rect.w), @intCast(rect.h));
        }

        try out_bmp.writeToPngFile(std.fs.cwd(), "/tmp/lightmap.png");
    }
}
