const std = @import("std");
const graph = @import("graph");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;
const ImageFormat = enum(i32) {
    IMAGE_FORMAT_NONE = -1,
    IMAGE_FORMAT_RGBA8888 = 0,
    IMAGE_FORMAT_ABGR8888,
    IMAGE_FORMAT_RGB888,
    IMAGE_FORMAT_BGR888,
    IMAGE_FORMAT_RGB565,
    IMAGE_FORMAT_I8,
    IMAGE_FORMAT_IA88,
    IMAGE_FORMAT_P8,
    IMAGE_FORMAT_A8,
    IMAGE_FORMAT_RGB888_BLUESCREEN,
    IMAGE_FORMAT_BGR888_BLUESCREEN,
    IMAGE_FORMAT_ARGB8888,
    IMAGE_FORMAT_BGRA8888,
    IMAGE_FORMAT_DXT1,
    IMAGE_FORMAT_DXT3,
    IMAGE_FORMAT_DXT5,
    IMAGE_FORMAT_BGRX8888,
    IMAGE_FORMAT_BGR565,
    IMAGE_FORMAT_BGRX5551,
    IMAGE_FORMAT_BGRA4444,
    IMAGE_FORMAT_DXT1_ONEBITALPHA,
    IMAGE_FORMAT_BGRA5551,
    IMAGE_FORMAT_UV88,
    IMAGE_FORMAT_UVWQ8888,
    IMAGE_FORMAT_RGBA16161616F,
    IMAGE_FORMAT_RGBA16161616,
    IMAGE_FORMAT_UVLX8888,

    pub fn bitPerPixel(self: @This()) u32 {
        return switch (self) {
            .IMAGE_FORMAT_NONE => 0,
            .IMAGE_FORMAT_DXT1 => 4,
            .IMAGE_FORMAT_DXT3 => 8,
            .IMAGE_FORMAT_DXT5 => 8,
            .IMAGE_FORMAT_A8 => 8,
            .IMAGE_FORMAT_I8 => 8,
            .IMAGE_FORMAT_P8 => 8,
            .IMAGE_FORMAT_BGR565 => 16,
            .IMAGE_FORMAT_BGRA4444 => 16,
            .IMAGE_FORMAT_BGRA5551 => 16,
            .IMAGE_FORMAT_BGRX5551 => 16,
            .IMAGE_FORMAT_IA88 => 16,
            .IMAGE_FORMAT_RGB565 => 16,
            .IMAGE_FORMAT_UV88 => 16,
            .IMAGE_FORMAT_BGR888 => 24,
            .IMAGE_FORMAT_BGR888_BLUESCREEN => 24,
            .IMAGE_FORMAT_RGB888 => 24,
            .IMAGE_FORMAT_RGB888_BLUESCREEN => 24,

            .IMAGE_FORMAT_RGBA8888 => 32,
            .IMAGE_FORMAT_ABGR8888 => 32,
            .IMAGE_FORMAT_ARGB8888 => 32,
            .IMAGE_FORMAT_BGRA8888 => 32,
            .IMAGE_FORMAT_BGRX8888 => 32,
            .IMAGE_FORMAT_DXT1_ONEBITALPHA => 32,
            .IMAGE_FORMAT_UVWQ8888 => 32,
            .IMAGE_FORMAT_RGBA16161616F => 64,
            .IMAGE_FORMAT_RGBA16161616 => 64,
            .IMAGE_FORMAT_UVLX8888 => 32,
        };
    }
    //TODO one more function that ouptuts gl type,
    //GL_BYTE, or  GL_UNSIGNED_SHORT_5_6_5 etc
    pub fn toOpenGLType(self: @This()) !graph.c.GLenum {
        return switch (self) {
            .IMAGE_FORMAT_RGBA8888, .IMAGE_FORMAT_ABGR8888, .IMAGE_FORMAT_RGB888, .IMAGE_FORMAT_BGR888, .IMAGE_FORMAT_I8, .IMAGE_FORMAT_IA88, .IMAGE_FORMAT_P8, .IMAGE_FORMAT_A8, .IMAGE_FORMAT_RGB888_BLUESCREEN, .IMAGE_FORMAT_BGR888_BLUESCREEN, .IMAGE_FORMAT_ARGB8888, .IMAGE_FORMAT_BGRA8888, .IMAGE_FORMAT_DXT1, .IMAGE_FORMAT_DXT3, .IMAGE_FORMAT_DXT5, .IMAGE_FORMAT_BGRX8888, .IMAGE_FORMAT_UVLX8888, .IMAGE_FORMAT_UV88, .IMAGE_FORMAT_UVWQ8888 => graph.c.GL_UNSIGNED_BYTE,

            //All that follow have not been tested,
            //most vtf's in the wild don't use these.
            .IMAGE_FORMAT_RGB565, .IMAGE_FORMAT_BGR565 => graph.c.GL_UNSIGNED_SHORT_5_6_5,
            .IMAGE_FORMAT_BGRA5551, .IMAGE_FORMAT_BGRX5551 => graph.c.GL_UNSIGNED_SHORT_5_5_5_1,

            .IMAGE_FORMAT_BGRA4444 => graph.c.GL_UNSIGNED_SHORT_4_4_4_4,
            .IMAGE_FORMAT_RGBA16161616F => graph.c.GL_HALF_FLOAT,
            .IMAGE_FORMAT_RGBA16161616 => graph.c.GL_UNSIGNED_SHORT,
            //.IMAGE_FORMAT_DXT1_ONEBITALPHA,

            else => error.formatNotSupported,
        };
    }

    pub fn toOpenGLFormat(self: @This()) !graph.c.GLenum {
        return switch (self) {
            .IMAGE_FORMAT_DXT5 => graph.c.GL_COMPRESSED_RGBA_S3TC_DXT5_EXT,
            .IMAGE_FORMAT_DXT1 => graph.c.GL_COMPRESSED_RGBA_S3TC_DXT1_EXT,
            .IMAGE_FORMAT_DXT3 => graph.c.GL_COMPRESSED_RGBA_S3TC_DXT3_EXT,
            .IMAGE_FORMAT_BGRA8888 => graph.c.GL_BGRA,
            .IMAGE_FORMAT_RGBA8888 => graph.c.GL_RGBA,
            .IMAGE_FORMAT_BGR888 => graph.c.GL_BGR,
            .IMAGE_FORMAT_RGB888 => graph.c.GL_RGB,
            .IMAGE_FORMAT_UV88 => graph.c.GL_RG,
            .IMAGE_FORMAT_I8 => graph.c.GL_RED,
            .IMAGE_FORMAT_RGBA16161616F => graph.c.GL_RGBA,
            .IMAGE_FORMAT_RGBA16161616 => graph.c.GL_RGBA,
            .IMAGE_FORMAT_A8 => graph.c.GL_RED,

            .IMAGE_FORMAT_ABGR8888 => graph.c.GL_RGBA, //These are wrong but I don't care
            .IMAGE_FORMAT_ARGB8888 => graph.c.GL_RGBA,
            .IMAGE_FORMAT_IA88 => graph.c.GL_RG,
            .IMAGE_FORMAT_RGB888_BLUESCREEN => graph.c.GL_RGB,
            .IMAGE_FORMAT_BGR888_BLUESCREEN => graph.c.GL_RGB,

            .IMAGE_FORMAT_BGRX8888 => graph.c.GL_BGRA,

            .IMAGE_FORMAT_RGB565 => return error.formatNotSupported,
            .IMAGE_FORMAT_BGR565 => return error.formatNotSupported,
            .IMAGE_FORMAT_BGRX5551 => return error.formatNotSupported,
            .IMAGE_FORMAT_BGRA4444 => return error.formatNotSupported,
            .IMAGE_FORMAT_DXT1_ONEBITALPHA => return error.formatNotSupported,
            .IMAGE_FORMAT_BGRA5551 => return error.formatNotSupported,
            .IMAGE_FORMAT_UVWQ8888 => return error.formatNotSupported,
            .IMAGE_FORMAT_UVLX8888 => return error.formatNotSupported,

            .IMAGE_FORMAT_P8 => return error.formatNotSupported,
            .IMAGE_FORMAT_NONE => return error.formatNotSupported,
            //else => {
            //    std.debug.print("FORMAT {s}\n", .{@tagName(self)});
            //    return error.formatNotSupported;
            //}, //Most formats can be supported trivially by adding the correct mapping to gl enums
        };
    }

    pub fn isCompressed(self: @This()) bool {
        return switch (self) {
            else => false,
            .IMAGE_FORMAT_DXT1 => true,
            .IMAGE_FORMAT_DXT3 => true,
            .IMAGE_FORMAT_DXT5 => true,
            .IMAGE_FORMAT_BGRA8888 => false, //This is not always true, depends on flags
        };
    }
};
const CompiledVtfFlags = enum(u32) {
    // Flags from the *.txt config file
    TEXTUREFLAGS_POINTSAMPLE = 0x00000001,
    TEXTUREFLAGS_TRILINEAR = 0x00000002,
    TEXTUREFLAGS_CLAMPS = 0x00000004,
    TEXTUREFLAGS_CLAMPT = 0x00000008,
    TEXTUREFLAGS_ANISOTROPIC = 0x00000010,
    TEXTUREFLAGS_HINT_DXT5 = 0x00000020,
    TEXTUREFLAGS_PWL_CORRECTED = 0x00000040,
    TEXTUREFLAGS_NORMAL = 0x00000080,
    TEXTUREFLAGS_NOMIP = 0x00000100,
    TEXTUREFLAGS_NOLOD = 0x00000200,
    TEXTUREFLAGS_ALL_MIPS = 0x00000400,
    TEXTUREFLAGS_PROCEDURAL = 0x00000800,

    // These are automatically generated by vtex from the texture data.
    TEXTUREFLAGS_ONEBITALPHA = 0x00001000,
    TEXTUREFLAGS_EIGHTBITALPHA = 0x00002000,

    // Newer flags from the *.txt config file
    TEXTUREFLAGS_ENVMAP = 0x00004000,
    TEXTUREFLAGS_RENDERTARGET = 0x00008000,
    TEXTUREFLAGS_DEPTHRENDERTARGET = 0x00010000,
    TEXTUREFLAGS_NODEBUGOVERRIDE = 0x00020000,
    TEXTUREFLAGS_SINGLECOPY = 0x00040000,
    TEXTUREFLAGS_PRE_SRGB = 0x00080000,

    TEXTUREFLAGS_UNUSED_00100000 = 0x00100000,
    TEXTUREFLAGS_UNUSED_00200000 = 0x00200000,
    TEXTUREFLAGS_UNUSED_00400000 = 0x00400000,

    TEXTUREFLAGS_NODEPTHBUFFER = 0x00800000,

    TEXTUREFLAGS_UNUSED_01000000 = 0x01000000,

    TEXTUREFLAGS_CLAMPU = 0x02000000,
    TEXTUREFLAGS_VERTEXTEXTURE = 0x04000000,
    TEXTUREFLAGS_SSBUMP = 0x08000000,

    TEXTUREFLAGS_UNUSED_10000000 = 0x10000000,

    TEXTUREFLAGS_BORDER = 0x20000000,

    TEXTUREFLAGS_UNUSED_40000000 = 0x40000000,
    TEXTUREFLAGS_UNUSED_80000000 = 0x80000000,

    pub fn printFlags(in: u32) void {
        for (0..32) |i| {
            const ii: u5 = @intCast(31 - i);
            const j = @as(u32, 1) << ii;
            if (j ^ in == 0)
                std.debug.print("{s}\n", .{@tagName(@as(@This(), @enumFromInt(ii)))});
        }
    }
};

const VtfHeader01 = struct {
    width: u16,
    height: u16,
    flags: u32,
    frames: u16,
    first_frame: u16,
    padding: [4]u8,
    reflectivity: [3]f32,
    padding1: [4]u8,
    bumpmap_scale: f32,
    highres_fmt: ImageFormat,
    mipmap_count: u8,
    lowres_fmt: ImageFormat,
    lowres_w: u8,
    lowres_h: u8,
};

const VtfHeader03 = struct {
    padding2: [3]u8 = undefined,
    num_res: u32 = 0,
    padding3: [8]u8 = undefined,
};

const VtfResource = struct {
    tag: [3]u8,
    flags: u8,
    offset: u32,
};

fn mipResolution(mip_factor: u16, full_size: u32, is_comp: bool) u32 {
    if (full_size % mip_factor != 0) {
        if (!is_comp)
            return 1;
        return 4;
    }
    const r = full_size / mip_factor;
    if (is_comp)
        return @max(r, 4);
    return r;
}

fn mipResActual(mip_factor: u16, full_size: u32) u32 {
    if (mip_factor == 0) return 1;
    return @max(full_size / mip_factor, 1);
}

pub fn loadTexture(buf: []const u8, alloc: std.mem.Allocator) !graph.Texture {
    var dat = try loadBuffer(buf, alloc);
    return dat.deinitToTexture(alloc);
}

/// Note: On linux, mesa with both an amdgpu and intel, mipmap generation is around 200x slower than on Windows.
pub const VtfBuf = struct {
    pub const MipLevel = struct {
        w: u32,
        h: u32,
        buf: []const u8,
    };

    width: u32,
    height: u32,
    pixel_format: graph.c.GLenum,
    compressed: bool,
    pixel_type: graph.c.GLenum,

    /// Caller must free, mip levels, smallest to largest
    /// When (width or height)  / buffers.len != 1, only the last MipLevel is used and mipmaps are generated
    alloc: std.mem.Allocator,
    buffers: std.ArrayList(MipLevel),

    pub fn deinitToTexture(self: *@This(), alloc: std.mem.Allocator) !graph.Texture {
        _ = alloc;
        defer self.deinit();
        const last = if (self.buffers.items.len > 0) self.buffers.items[self.buffers.items.len - 1] else return error.brokentexture;
        if (last.buf.len == 0 or self.width > 0x1000 or self.height > 0x1000) {
            std.debug.print("broken texture\n", .{});
            return error.brokentexture;
        }
        // setMipLevel(self: *const Texture, w: i32, h: i32, buffer: ?[]const u8, o: Options, level: c.GLint) void {

        const tex = graph.Texture.initMipped(@intCast(self.width), @intCast(self.height), .{
            .pixel_format = self.pixel_format,
            .is_compressed = self.compressed,
            .pixel_type = self.pixel_type,
            .min_filter = graph.c.GL_LINEAR_MIPMAP_LINEAR,
        });
        const mip_count: u64 = @intCast(self.buffers.items.len);
        if (mip_count == 0 or mip_count > 64) return error.noTexture;

        const mip_factor = std.math.pow(u64, 2, mip_count - 1);

        // All mip levels must be specified to 1x1, otherwise mips are generated by opengl
        if ((self.width / mip_factor != 1 and self.height / mip_factor != 1)) {
            tex.setMipLevel(@intCast(last.w), @intCast(last.h), last.buf, .{
                .generate_mipmaps = false,
                .pixel_format = self.pixel_format,
                .is_compressed = self.compressed,
                .pixel_type = self.pixel_type,
                .min_filter = graph.c.GL_LINEAR_MIPMAP_LINEAR,
            }, @intCast(0));
            graph.c.glBindTexture(graph.c.GL_TEXTURE_2D, tex.id);
            graph.c.glGenerateMipmap(graph.c.GL_TEXTURE_2D);
        } else {
            for (self.buffers.items, 0..) |buf, mi| {
                const level = mip_count - mi - 1;

                //std.debug.print("{d} {d}    {d}\n", .{ buf.w, buf.h, level });
                tex.setMipLevel(@intCast(buf.w), @intCast(buf.h), buf.buf, .{
                    .generate_mipmaps = false,
                    .pixel_format = self.pixel_format,
                    .is_compressed = self.compressed,
                    .pixel_type = self.pixel_type,
                    .min_filter = graph.c.GL_LINEAR,
                    //.min_filter = graph.c.GL_LINEAR_MIPMAP_LINEAR,
                }, @intCast(level));
            }
        }
        return tex;
    }

    pub fn deinit(self: *VtfBuf) void {
        for (self.buffers.items) |buf|
            self.alloc.free(buf.buf);
        self.buffers.deinit(self.alloc);
    }
};

const log = std.log.scoped(.vtf);
pub fn loadBuffer(buffer: []const u8, alloc: std.mem.Allocator) !VtfBuf {
    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = buffer, .pos = 0 };
    var r = fbs.reader();
    const VtfSig = 0x00465456;
    const sig = try r.readInt(u32, .little);
    if (sig != VtfSig) return error.notVtf;

    const version_maj = try r.readInt(u32, .little);
    const version_min = try r.readInt(u32, .little);
    if (version_maj != 7) return error.unsupportedVersion;
    const header_size = try r.readInt(u32, .little);

    const h1 = try parseStruct(VtfHeader01, .little, r);
    errdefer log.err("{}\n", .{h1});

    //var flags = std.enums.EnumSet(CompiledVtfFlags).initEmpty();
    //flags.bits.mask = h1.flags;
    //var it = flags.iterator();
    //while (it.next()) |item| {
    //    std.debug.print("{s}\n", .{@tagName(item)});
    //}

    errdefer log.err("TOKEN POS {d} {d}", .{ fbs.pos, buffer.len });
    errdefer log.err("Version {d}.{d}", .{ version_maj, version_min });
    if (version_min > 5) { // versions 3, 4, 5 are bitwise equiv
        log.err("Vtf version {d}.{d}, not supported", .{ version_maj, version_min });
        return error.unsupportedVersion;
    }

    var depth: u16 = 0;
    if (version_min >= 2) {
        depth = try r.readInt(u16, .little);
        if (depth != 1) {
            log.err("Depth {d}", .{depth});
            return error.depthNotSupported;
        }
    }
    const h3: VtfHeader03 = if (version_min >= 4) try parseStruct(VtfHeader03, .little, r) else .{}; //Versions 3 and 4 are bit equivalent
    //FIXME actually try to parse the resources in v3,v4
    for (0..h3.num_res) |_| {
        const re = try parseStruct(VtfResource, .little, r);
        _ = re;
        //std.debug.print("RE {s} {}\n", .{ re.tag, re });
    }

    fbs.pos = header_size; //Ensure we are in the correct position
    { //Low res first
        const bpp = h1.lowres_fmt.bitPerPixel();
        //const low_res = try alloc.alloc(u8, @divExact(bpp * h1.lowres_w * h1.lowres_h, 8));
        //defer alloc.free(low_res);
        const count = bpp * h1.lowres_w * h1.lowres_h;
        const ac = if (count % 8 != 0) 8 else @divExact(count, 8);
        try r.skipBytes(ac, .{});
    }

    var ret = VtfBuf{
        .alloc = alloc,
        .width = h1.width,
        .height = h1.height,
        .buffers = .{},
        .pixel_format = try h1.highres_fmt.toOpenGLFormat(),
        .compressed = h1.highres_fmt.isCompressed(),
        .pixel_type = try h1.highres_fmt.toOpenGLType(),
    };
    errdefer {
        ret.deinit();
    }

    const bpp: u32 = @intCast(h1.highres_fmt.bitPerPixel());
    for (0..h1.mipmap_count) |mi| {
        for (0..h1.frames) |fi| {
            const mip_factor = std.math.pow(u16, 2, h1.mipmap_count - @as(u16, @intCast(mi)) - 1);
            const is_comp = h1.highres_fmt.isCompressed();

            const mw = mipResolution(mip_factor, h1.width, is_comp);
            const mh = mipResolution(mip_factor, h1.height, is_comp);
            const bytes = blk: {
                if (bpp * mw * mw % 8 != 0) {
                    if (is_comp)
                        break :blk 0;
                    break :blk 4;
                }
                break :blk @divExact(bpp * mw * mh, 8);
            };

            if (fi > 0) {
                //Skip the remaining frames
                try r.skipBytes(bytes, .{});
            } else {
                const am_w = mipResActual(mip_factor, h1.width);
                const am_h = mipResActual(mip_factor, h1.height);
                const imgdata = try alloc.alloc(u8, bytes);
                try r.readNoEof(imgdata);
                try ret.buffers.append(ret.alloc, .{
                    .buf = imgdata,
                    .w = am_w,
                    .h = am_h,
                });
            }
        }
    }

    return ret;
}
