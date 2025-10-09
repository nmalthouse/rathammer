const std = @import("std");
const pcom = @import("parse_common.zig");
const ecs = @import("ecs.zig");

const endian = std.builtin.Endian.little;

const Color = [3]u8;

const VisGroup = struct {
    name: [128]u8,
    color: Color,
    pad: u8,
    index: i32,
    visible: u8,
    pad2: [3]u8,
};

fn parseNString(r: anytype, buf: *[255]u8) ![]const u8 {
    const len = try r.readInt(u8, endian);
    if (len <= 0) return "";

    try r.readNoEof(buf[0..@intCast(len)]);
    if (buf[@intCast(len - 1)] != 0) {
        return error.invalidString;
    }
    return buf[0..@intCast(len - 1)]; //Omit the null
}

const SolidH1 = struct {
    visgroup_id: i32,
    color: Color,
    pad: [4]u8,
};

const Vector = struct { x: f32, y: f32, z: f32 };

const FaceH1 = struct {
    tex_name: [256]u8,
    pad1: u32,
    tex_uaxis: Vector,
    x_shift: f32,
    tex_vaxis: Vector,
    y_shift: f32,
    tex_rot: f32,
    tex_sx: f32,
    tex_sy: f32,
    pad2: [16]u8,
};

const EntityH1 = struct {
    visgroup_id: i32,
    color: [3]u8,
};

const eql = std.mem.eql;

fn parseSolid(r: anytype) !void {
    const h1 = try pcom.parseStruct(SolidH1, endian, r);
    _ = h1;
    const num_face = try parseLen(r);
    for (0..num_face) |_| {
        const fh1 = try pcom.parseStruct(FaceH1, endian, r);
        _ = fh1;
        const num_vert = try parseLen(r);
        for (0..num_vert) |_| {
            _ = try pcom.parseStruct(Vector, endian, r);
        }
        _ = try pcom.parseStruct(Vector, endian, r); //Get plane
        _ = try pcom.parseStruct(Vector, endian, r);
        _ = try pcom.parseStruct(Vector, endian, r);
    }
}

fn parseEnt(r: anytype) anyerror!void {
    const h1 = try pcom.parseStruct(EntityH1, endian, r);
    _ = h1;
    const num_brush = try parseLen(r);
    for (0..num_brush) |_| {
        try parseObj(r);
    }
    const class = try parseNString(r, &nbuf);
    std.debug.print("CLASS {s}\n", .{class});
    try r.skipBytes(4, .{}); //pad
    const flags = try r.readInt(i32, endian);
    _ = flags;
    const num_kv = try parseLen(r);
    for (0..num_kv * 2) |_| {
        const kv = try parseNString(r, &nbuf);
        std.debug.print("    kv {s}\n", .{kv});
    }
    try r.skipBytes(14, .{}); //pad
    const pos = try pcom.parseStruct(Vector, endian, r);
    _ = pos;
    try r.skipBytes(4, .{}); //pad

}

fn parseGroup(r: anytype) anyerror!void {
    const visgroup_id = try r.readInt(i32, endian);
    _ = visgroup_id;
    const color = try pcom.parseStruct(Color, endian, r);
    _ = color;
    const num_obj = try parseLen(r);

    for (0..num_obj) |_| {
        try parseObj(r);
    }
}

fn parseObj(r: anytype) !void {
    const kind = try parseNString(r, &nbuf);
    if (eql(u8, kind, "CMapEntity")) {
        try parseEnt(r);
    } else if (eql(u8, kind, "CMapSolid")) {
        try parseSolid(r);
    } else if (eql(u8, kind, "CMapGroup")) {
        try parseGroup(r);
    } else {
        std.debug.print("KEY {s}\n", .{kind});
        return error.unknownObjectType;
    }
}

fn parsePath(r: anytype) !void {
    try r.readNoEof(nbuf[0..128]); //Name
    try r.readNoEof(nbuf[0..128]); //class
    const ptype = try r.readInt(i32, endian);
    _ = ptype;
    const num_corner = try parseLen(r);
    for (0..num_corner) |_| {
        try parseCorner(r);
    }
}

fn parseCorner(r: anytype) !void {
    const pos = try pcom.parseStruct(Vector, endian, r);
    _ = pos;
    const index = try r.readInt(i32, endian);
    _ = index;
    try r.readNoEof(nbuf[0..128]); //name override
    const num_kv = try parseLen(r);
    for (0..num_kv * 2) |_| {
        const name1 = try parseNString(r, &nbuf);
        _ = name1;
    }
}

const MAX_LEN = 0x7fff_ffff;
fn parseLen(r: anytype) !u32 {
    const int = try r.readInt(i32, endian);
    if (int < 0 or int >= MAX_LEN) return error.invalidLength;
    return @intCast(int);
}

var nbuf: [255]u8 = undefined;

const IntermediateCtx = struct {
    const Solid = struct {
        const Side = struct {
            tex_name: []const u8,
            u: ecs.Side.UVaxis,
            v: ecs.Side.UVaxis,

            plane: [3]Vector,
        };

        sides: []const Side,
        vis_id: i32,
    };
};

test {
    const alloc = std.testing.allocator;

    const in = try std.fs.cwd().openFile("/home/rat/Downloads/c0a0.rmf", .{});

    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };

    const r = fbs.reader();

    const version: f32 = @bitCast(try r.readInt(u32, endian));
    std.debug.print("\nVERSION {d}\n", .{version});
    if (version != 2.2) return error.unsupportedVersion;

    errdefer std.debug.print("POSITION 0x{x}\n", .{fbs.pos});
    errdefer {
        std.debug.print("{any}\n", .{fbs.buffer[fbs.pos .. fbs.pos + 20]});
    }
    var magic_buf: [3]u8 = undefined;
    try r.readNoEof(&magic_buf);
    if (!std.mem.eql(u8, magic_buf[0..3], &[_]u8{ 'R', 'M', 'F' })) return error.invalidRmf;

    const num_vis = try parseLen(r);
    for (0..num_vis) |_| {
        const a = try pcom.parseStruct(VisGroup, endian, &r);
        const n = std.mem.sliceTo(&a.name, 0);
        std.debug.print("{s}\n", .{n});
    }

    const name1 = try parseNString(&r, &nbuf);
    std.debug.print("{s}\n", .{name1});
    if (!std.mem.eql(u8, name1, "CMapWorld")) return error.invalidRmf;

    try r.skipBytes(7, .{}); //Padding

    //Brush, ent, or group

    const num_obj = try parseLen(r);
    for (0..num_obj) |_| {
        try parseObj(&r);
    }

    const worldspawn = try parseNString(&r, &nbuf);
    if (!eql(u8, "worldspawn", worldspawn)) return error.notWorldspawn;
    try r.skipBytes(4, .{}); //pad
    _ = try r.readInt(i32, endian); //usused flags
    const num_kv = try parseLen(&r);
    for (0..num_kv * 2) |_| {
        const kv = try parseNString(&r, &nbuf);
        std.debug.print("    kv {s}\n", .{kv});
    }
    try r.skipBytes(12, .{}); //pad
    for (0..try parseLen(&r)) |_| { // PATH
        try parsePath(&r);
    }
    try r.readNoEof(nbuf[0..8]); //Doc info
    {
        const n = std.mem.sliceTo(nbuf[0..8], 0);
        if (!eql(u8, n, "DOCINFO")) return error.notDocInfo;
    }
    const cam_version: f32 = @bitCast(try r.readInt(u32, endian));
    _ = cam_version;
    const active_camera = try r.readInt(i32, endian);
    _ = active_camera;
    const num_camera = try parseLen(&r);
    for (0..num_camera) |_| {
        _ = try pcom.parseStruct(Vector, endian, &r); //eye pos
        _ = try pcom.parseStruct(Vector, endian, &r); //look pos
    }
}
