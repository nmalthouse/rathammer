//// Define's a zig struct equivalent of a vmf file
const std = @import("std");
const vdf = @import("vdf.zig");
const graph = @import("graph");

pub const Vmf = struct {
    world: World = .{},
    entity: []const Entity = &.{},
    viewsettings: ViewSettings = .{},
    visgroups: VisGroup = .{},
};

pub const VersionInfo = struct {
    editorversion: u32 = 0,
    editorbuild: u32 = 0,
    mapversion: u32 = 0,
    formatversion: u32 = 0,
    prefab: u32 = 0,
};

pub const VisGroup = struct {
    name: []const u8 = "",
    visgroupid: i32 = -1,
    color: StringVec = .{},

    visgroup: []const VisGroup = &.{},
};

pub const ViewSettings = struct {
    bSnapToGrid: i32 = 0,
    bShowGrid: i32 = 0,
    nGridSpacing: i32 = 0,
    bShow3DGrid: i32 = 0,
};

pub const EditorInfo = struct {
    color: StringVec = .{},
    visgroupid: []const i32 = &.{},
    groupid: i32 = -1,
    visgroupshown: i8 = 1,
    visgroupautoshown: i8 = 1,
    comments: []const u8 = "",
};

pub const Connection = struct {
    listen_event: []const u8 = "",
    target: []const u8 = "",
    input: []const u8 = "",
    value: []const u8 = "",
    delay: f32 = 0,
    fire_count: i32 = 0,
};

pub const Connections = struct {
    is_init: bool = false,
    list: std.ArrayList(Connection) = undefined,

    pub fn parseVdf(val: *const vdf.KV.Value, alloc: std.mem.Allocator, _: anytype) !@This() {
        if (val.* != .obj) return error.notGood;

        var ret = try std.ArrayList(Connection).initCapacity(alloc, val.obj.list.items.len);
        for (val.obj.list.items) |conn| {
            if (conn.val != .literal) return error.invalidConnection;
            var it = std.mem.tokenizeAny(u8, conn.val.literal, ",\x1b");
            try ret.append(.{
                .listen_event = conn.key,
                .target = it.next() orelse "",
                .input = it.next() orelse "",
                .value = it.next() orelse "",
                .delay = if (it.next()) |t| try std.fmt.parseFloat(f32, t) else 0,
                .fire_count = if (it.next()) |t| try std.fmt.parseInt(i32, t, 10) else -1,
            });
        }
        return .{ .list = ret, .is_init = true };
    }
};

pub const World = struct {
    id: u32 = 0,
    mapversion: u32 = 0,
    skyname: []const u8 = "",
    solid: []const Solid = &.{},
    classname: []const u8 = "",
    sounds: []const u8 = "",
    MaxRange: []const u8 = "",
    startdark: []const u8 = "",
    gametitle: []const u8 = "",
    newunit: []const u8 = "",
    defaultteam: []const u8 = "",
    fogenable: []const u8 = "",
    fogblend: []const u8 = "",
    fogcolor: []const u8 = "",
    fogcolor2: []const u8 = "",
    fogdir: []const u8 = "",
    fogstart: []const u8 = "",
    fogend: []const u8 = "",
    light: []const u8 = "",
    ResponseContext: []const u8 = "",
    maxpropscreenwidth: []const u8 = "",

    editor: EditorInfo = .{},
};

pub const Solid = struct {
    id: u32 = 0,
    side: []const Side = &.{},

    editor: EditorInfo = .{},
};

pub const DispInfo = struct {
    power: i32 = -1, //Hack, this is used to see if vdf has initilized dispinfo
    elevation: f32 = undefined,
    subdiv: i32 = undefined,
    startposition: StringVecBracket = undefined,

    normals: DispVectorRow = .{},
    offsets: DispVectorRow = .{},
    offset_normals: DispVectorRow = .{},
    distances: DispRow = .{},
    alphas: DispRow = .{},
    //triangle_tags: DispRow = .{},
};
pub fn DispRowG(comptime T: type) type {
    return struct {
        rows: std.ArrayList(T) = undefined,
        was_init: bool = false,

        pub fn clone(self: *const @This(), alloc: std.mem.Allocator) !std.ArrayList(T) {
            var ret = std.ArrayList(T).init(alloc);
            if (self.was_init)
                try ret.appendSlice(self.rows.items);
            return ret;
        }

        pub fn parseVdf(val: *const vdf.KV.Value, alloc: std.mem.Allocator, _: anytype) !@This() {
            if (val.* == .literal)
                return error.notgood;
            var ret = try std.ArrayList(T).initCapacity(alloc, val.obj.list.items.len);
            var num_norm_def: usize = 0;
            for (val.obj.list.items, 0..) |row, i| {
                if (row.val != .literal)
                    return error.invalidDispNormal;
                const num_norm = val.obj.list.items.len;
                var it = std.mem.splitScalar(u8, row.val.literal, ' ');
                if (i == 0) {
                    num_norm_def = num_norm;
                    try ret.resize(num_norm * num_norm);
                }
                if (num_norm != num_norm_def)
                    return error.invalidNormalsCount;

                if (!std.mem.startsWith(u8, row.key, "row"))
                    return error.invalidNormalKey;
                const row_index = try std.fmt.parseInt(u32, row.key["row".len..], 10);

                for (0..num_norm) |norm_i| {
                    const g_i = row_index * num_norm + norm_i;
                    if (g_i >= ret.items.len) return error.invalidRowIndex;
                    switch (T) {
                        f32 => {
                            const x = it.next() orelse return error.notEnoughNormals;
                            ret.items[g_i] = try std.fmt.parseFloat(f32, x);
                        },
                        graph.za.Vec3 => {
                            const x = it.next() orelse return error.notEnoughNormals;
                            const y = it.next() orelse return error.notEnoughNormals;
                            const z = it.next() orelse return error.notEnoughNormals;
                            ret.items[g_i] = graph.za.Vec3.new(
                                try std.fmt.parseFloat(f32, x),
                                try std.fmt.parseFloat(f32, y),
                                try std.fmt.parseFloat(f32, z),
                            );
                        },
                        else => @compileError("please add the type here"),
                    }
                }
            }
            return .{ .rows = ret, .was_init = true };
        }
    };
}
pub const DispRow = DispRowG(f32);
pub const DispVectorRow = DispRowG(graph.za.Vec3);

pub const Entity = struct {
    id: u32 = 0,
    classname: []const u8 = "",
    solid: []const Solid = &.{},
    origin: StringVec = .{},
    angles: StringVec = .{},
    editor: EditorInfo = .{},
    connections: Connections = .{},

    rest_kvs: vdf.KVMap,
};
pub const Side = struct {
    pub const UvCoord = struct {
        axis: graph.za.Vec3 = graph.za.Vec3.up(),
        translation: f64 = 0,
        scale: f64 = 0,

        pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
            if (val.* != .literal)
                return error.notgood;

            const str = val.literal;
            var i: usize = 0;
            const ax = try parseVec(str, &i, 4, '[', ']', f32);
            const scale = try std.fmt.parseFloat(f64, std.mem.trimLeft(u8, str[i..], " "));

            return .{
                .axis = graph.za.Vec3.new(ax[0], ax[1], ax[2]),
                .translation = ax[3],
                .scale = scale,
            };
        }
    };
    id: u32 = 0,
    plane: struct {
        pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
            if (val.* != .literal)
                return error.notgood;

            const str = val.literal;
            var self: @This() = undefined;
            var i: usize = 0;
            for (0..3) |j| {
                const r1 = try parseVec(str, &i, 3, '(', ')', f64);
                self.tri[j] = vdf.Vec3.new(r1[0], r1[1], r1[2]);
            }

            return self;
        }
        tri: [3]vdf.Vec3,
    },

    uaxis: UvCoord = .{},
    vaxis: UvCoord = .{},
    material: []const u8 = "",
    lightmapscale: i32 = 16,
    rotation: f32 = 0,
    smoothing_groups: i32 = 0,
    dispinfo: DispInfo = .{},
};

pub fn parseVec(
    str: []const u8,
    i: *usize,
    comptime count: usize,
    comptime start: u8,
    comptime end: u8,
    comptime ft: type,
) ![count]ft {
    var ret: [count]ft = undefined;
    var in_num: bool = false;
    var vert_index: i64 = -1;
    var comp_index: usize = 0;

    while (i.* < str.len) : (i.* += 1) {
        if (str[i.*] != ' ')
            break;
    }
    var num_start_index: usize = i.*;
    const slice = str[i.*..];
    for (slice) |char| {
        switch (char) {
            else => {
                if (!in_num)
                    num_start_index = i.*;
                in_num = true;
            },
            start => {
                vert_index += 1;
            },
            ' ', end => {
                const s = str[num_start_index..i.*];
                if (in_num) {
                    const f = std.fmt.parseFloat(ft, s) catch {
                        std.debug.print("IT BROKE {s}: {s}\n", .{ s, slice });
                        return error.fucked;
                    };
                    if (vert_index < 0)
                        return error.invalid;
                    ret[comp_index] = f;
                    comp_index += 1;
                }
                in_num = false;
                if (char == end) {
                    if (comp_index != count)
                        return error.notEnoughComponent;
                    i.* += 1;
                    return ret;
                }
            },
        }
        i.* += 1;
    }
    return ret;
}

/// Parse a vector "0.0 1.0 2"
const StringVec = struct {
    v: graph.za.Vec3 = graph.za.Vec3.zero(),

    pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
        if (val.* != .literal)
            return error.notgood;
        var it = std.mem.splitScalar(u8, val.literal, ' ');
        var ret: @This() = undefined;
        ret.v.data[0] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        ret.v.data[1] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        ret.v.data[2] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        return ret;
    }
};

/// Parse a vector "[0.0 2.0 3.0]"
const StringVecBracket = struct {
    v: graph.za.Vec3,

    pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
        if (val.* != .literal)
            return error.notgood;
        var i: usize = 0;
        const a = try parseVec(val.literal, &i, 3, '[', ']', f32);
        return .{ .v = graph.za.Vec3.new(a[0], a[1], a[2]) };
    }
};

test "parse vec" {
    const str = "(0 12 12.3   ) (0 12E3 88)  ";
    var i: usize = 0;

    const a = try parseVec(str, &i, 3, '(', ')', f32);
    const b = try parseVec(str, &i, 3, '(', ')', f32);
    try std.testing.expectEqual(a[0], 0);
    try std.testing.expectEqual(b[0], 0);
    try std.testing.expectEqual(b[2], 88);
}

test "parse big" {
    const str = "[0 0 0 0] 0.02";
    var i: usize = 0;
    const a = try parseVec(str, &i, 4, '[', ']', f32);
    std.debug.print("{any}\n", .{a});
    std.debug.print("{s}\n", .{str[i..]});
    const scale = try std.fmt.parseFloat(f64, std.mem.trimLeft(u8, str[i..], " "));
    std.debug.print("{d}\n", .{scale});
}
