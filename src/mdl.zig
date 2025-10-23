const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const vpk = @import("vpk.zig");
const util = @import("util.zig");

const MdlVector = struct {
    x: f32,
    y: f32,
    z: f32,
    pub fn toZa(self: @This()) Vec3 {
        return Vec3.new(self.x, self.y, self.z);
    }
};

const MDL_MAGIC_STRING = "IDST";
const Studiohdr_01 = struct {
    id: [4]u8,
    version: u32,
};

const Studiohdr_02 = struct {
    checksum: u32,
    name: [64]u8,
    data_length: u32, //Size of entire mdl file in bytes, should match slice.len from vpkctx
    eye_pos: MdlVector,
    illumposition: MdlVector,
    hull_min: MdlVector,
    hull_max: MdlVector,
    view_bb_min: MdlVector,
    view_bb_max: MdlVector,

    flags: u32,
};

const AnimDesc = struct {
    bp: u32,
    name_offset: u32,
    fps: f32,
    flags: u32,
    num_frame: u32,
    num_movement: u32,
    movement_offset: u32,

    padding: [6]u32,

    anim_block: u32,
    anim_offset: u32,
    num_ik_rule: u32,
    ik_rule_offset: u32,
    anim_block_ik_rule_index: u32,

    num_local_hier: u32,
    local_hier_offset: u32,

    section_offset: u32,
    section_frames: u32,

    frame_span: u16,
    frame_count: u16,
    frame_offset: u32,

    frame_stalltime: f32,
};

const Anim = struct {
    bone: u8,
    flags: u8,

    next_offset: u16,
};

const Studiohdr_03 = struct {
    bone_count: u32, // Number of data sections (of type mstudiobone_t)
    bone_offset: u32, // Offset of first data section

    bonecontroller_count: u32,
    bonecontroller_offset: u32,

    hitbox_count: u32,
    hitbox_offset: u32,

    localanim_count: u32,
    localanim_offset: u32,

    localseq_count: u32,
    localseq_offset: u32,

    activitylistversion: u32,
    eventsindexed: u32,

    texture_count: u32,
    texture_offset: u32,

    // This offset points to a series of ints.
    // Each int value, in turn, is an offset relative to the start of this header/the-file,
    // At which there is a null-terminated string.
    texturedir_count: u32,
    texturedir_offset: u32,

    skinreference_count: u32,
    skinrfamily_count: u32,
    skinreference_index: u32,

    bodypart_count: u32,
    bodypart_offset: u32,

    attachment_count: u32,
    attachment_offset: u32,

    localnode_count: u32,
    localnode_index: u32,
    localnode_name_index: u32,

    flexdesc_count: u32,
    flexdesc_index: u32,

    flexcontroller_count: u32,
    flexcontroller_index: u32,

    flexrules_count: u32,
    flexrules_index: u32,

    ikchain_count: u32,
    ikchain_index: u32,

    mouths_count: u32,
    mouths_index: u32,

    localposeparam_count: u32,
    localposeparam_index: u32,

    surfaceprop_index: u32,

    keyvalue_index: u32,
    keyvalue_count: u32,

    iklock_count: u32,
    iklock_index: u32,

    mass: f32,

    contents: u32,
    includemodel_count: u32,
    includemodel_index: u32,

    virtualModel: u32,

    animblocks_name_index: u32,
    animblocks_count: u32,
    animblocks_index: u32,

    animblockModel: u32,

    bonetablename_index: u32,

    vertex_base: u32,
    offset_base: u32,

    directionaldotproduct: i8,

    rootLod: u8,

    numAllowedRootLods: u8,

    unused0: u8,
    unused1: u32,

    flexcontrollerui_count: u32,
    flexcontrollerui_index: u32,

    vertAnimFixedPointScale: f32, // ??
    unused2: u32,

    studiohdr2index: u32,

    unused3: u32, // ??

};

pub const StudioTexture = struct {
    name_offset: u32,
    flags: u32,
    used: u32,
    unused: u32,

    material: u32,
    client_mat: u32,
    unused2: [10]u32,
};

pub const BodyPart = struct {
    name_index: u32,
    num_model: u32,
    base: u32,
    model_index: u32,
};

pub const Model = struct {
    name: [64]u8,
    type: u32,
    bounding_rad: f32,
    num_mesh: u32,
    mesh_index: u32,
    num_verts: u32,
    vert_index: u32,
    tangent_index: u32,

    num_attach: u32,
    attach_index: u32,
    num_eyeballs: u32,
    eyeball_index: u32,
    unused: [8]u32,
};

pub const Mesh = struct {
    material: i32,
    model_index: i32,
    num_vert: i32,
    vert_offset: i32,
    num_flex: i32,
    flex_index: i32,

    padding: [1]u32, //??????? Determined experimentally. Does not match what sdk public/studio.h says

    mat_type: i32,
    mat_param: i32,
    mesh_id: i32,
    center: MdlVector,

    num_lod_verts: [8]i32,
    unused: [8]i32,
};

//12 * 4 + 8 * 4

pub const ModelInfo = struct {
    alloc: std.mem.Allocator,
    vert_offsets: std.ArrayList(u16) = .{},
    texture_paths: std.ArrayList([]const u8) = .{},
    texture_names: std.ArrayList([]const u8) = .{},
    hull_min: Vec3,
    hull_max: Vec3,
};

fn setFbs(fbs: *std.io.FixedBufferStream([]const u8), pos: usize) !void {
    if (pos >= fbs.buffer.len) return error.outOfBounds;
    fbs.pos = pos;
}

pub fn doItCrappy(alloc: std.mem.Allocator, slice: []const u8, print: anytype) !ModelInfo {
    const log = std.log.scoped(.mdl);
    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
    const r = fbs.reader();
    const o1 = try parseStruct(Studiohdr_01, .little, r);
    if (!std.mem.eql(u8, &o1.id, MDL_MAGIC_STRING))
        return error.notMdl;
    const supported = [_]u32{ 44, 48 }; //This is bullshit lol
    if (std.mem.indexOfScalar(u32, &supported, o1.version) == null) {
        log.warn("Unsupported mdl version {d} , attempting to parse", .{o1.version});
    }

    const h2 = try parseStruct(Studiohdr_02, .little, r);
    print("Name: {s} {d}\n", .{ h2.name, h2.data_length });
    print("{}\n", .{h2});
    const h3 = try parseStruct(Studiohdr_03, .little, r);
    print("{}\n", .{h3});

    var info = ModelInfo{
        .alloc = alloc,
        .hull_min = h2.hull_min.toZa(),
        .hull_max = h2.hull_max.toZa(),
    };
    errdefer {
        info.vert_offsets.deinit(info.alloc);
        for (info.texture_paths.items) |item|
            alloc.free(item);
        for (info.texture_names.items) |item|
            alloc.free(item);
        info.texture_paths.deinit(info.alloc);
        info.texture_names.deinit(info.alloc);
    }

    try setFbs(&fbs, h3.texture_offset);
    for (0..h3.texture_count) |_| {
        const start = fbs.pos;
        const tex = try parseStruct(StudioTexture, .little, r);
        const name: [*c]const u8 = &slice[start + tex.name_offset];

        const name_fixed = util.ensurePathRelative(std.mem.span(name), true);

        const duped_name = try alloc.dupe(u8, name_fixed);
        vpk.sanatizeVpkString(duped_name);

        try info.texture_names.append(info.alloc, duped_name);
        print("{s} {}\n", .{ name, tex });
    }

    try setFbs(&fbs, h3.texturedir_offset);
    for (0..h3.texturedir_count) |_| {
        const int = try r.readInt(u32, .little);
        const name: [*c]const u8 = &slice[int];
        const name_fixed = util.ensurePathRelative(std.mem.span(name), true);
        const duped_name = try alloc.dupe(u8, name_fixed);
        vpk.sanatizeVpkString(duped_name);
        try info.texture_paths.append(info.alloc, duped_name);
        print("NAME {s}\n", .{name});
    }

    try setFbs(&fbs, h3.skinreference_index);
    for (0..h3.skinreference_count) |_| {
        print("crass {d}\n", .{try r.readInt(i16, .little)});
    }

    if (false) {
        std.debug.print("NUMBER OF ANIMDESC {d}\n", .{h3.localanim_count});
        try setFbs(&fbs, h3.localanim_offset);
        for (0..h3.localanim_count) |_| {
            const start = fbs.pos;
            const animdesc = try parseStruct(AnimDesc, .little, r);
            const name: [*c]const u8 = &slice[start + animdesc.name_offset];
            std.debug.print("ANIM_NAME {s} and index: {d}\n", .{ name, animdesc.anim_offset });
            std.debug.print("NUM MOVEMENT {d}, {d}\n", .{ animdesc.num_movement, animdesc.movement_offset });
            const st = fbs.pos;
            defer fbs.pos = st;

            //TODO support other methods of anim storage
            if (animdesc.anim_offset != 0) {
                try setFbs(&fbs, animdesc.anim_offset);
                const anim = try parseStruct(Anim, .little, r);
                try setFbs(&fbs, @sizeOf(Anim)); //fbs is now at pData
                const V = struct {
                    x: f32,
                    y: f32,
                    z: f32,
                };
                std.debug.print("FLAGS {b}\n", .{anim.flags});
                const a = try parseStruct(V, .little, r);
                std.debug.print("vec {any}\n", .{a});
            }
        }
    }

    try setFbs(&fbs, h3.bodypart_offset);
    for (0..h3.bodypart_count) |_| {
        const o2 = fbs.pos;
        const bp = try parseStruct(BodyPart, .little, r);
        const st = fbs.pos;
        defer fbs.pos = st;
        print("{}\n", .{bp});
        try setFbs(&fbs, bp.model_index + o2);
        for (0..bp.num_model) |_| {
            const o3 = fbs.pos;
            const mm = try parseStruct(Model, .little, r);
            print("{}\n", .{mm});
            print("{s}\n", .{@as([*c]const u8, @ptrCast(&mm.name[0]))});
            const stt = fbs.pos;
            defer fbs.pos = stt;
            try setFbs(&fbs, mm.mesh_index + o3);
            for (0..mm.num_mesh) |_| {
                const mesh = try parseStruct(Mesh, .little, r);
                print("BIG DOG {d}\n", .{mesh.num_vert});
                if (mesh.num_vert > std.math.maxInt(u16)) {
                    std.debug.print("holy hell thats a lot of verticies {d}\n", .{mesh.num_vert});
                    return error.TooManyVerts;
                }
                try info.vert_offsets.append(info.alloc, @intCast(mesh.num_vert));
                print("{}\n", .{mesh});
            }
        }
    }
    //shortpSkinref( int i ) const { return (short *)(((byte *)this) + skinindex) + i; };
    return info;
}
