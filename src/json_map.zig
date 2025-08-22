const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const ecs = @import("ecs.zig");
const vdf = @import("vdf.zig");
const vpk = @import("vpk.zig");
const version = @import("version.zig");
const StringStorage = @import("string.zig").StringStorage;

/// Dummy vpkctx that provides enough of the interface to parse json files.
/// When we load json to serialize to vmf, we don't want to have to mount vpk's.
pub const VpkMapper = struct {
    str_map: std.StringHashMap(vpk.VpkResId),
    arena: std.heap.ArenaAllocator,
    strings: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .str_map = std.StringHashMap(vpk.VpkResId).init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .strings = std.ArrayList([]const u8).init(alloc),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.str_map.deinit();
        self.arena.deinit();
    }

    pub fn getResourceIdString(self: *@This(), str: []const u8, san: bool) !?vpk.VpkResId {
        if (self.str_map.get(str)) |id| return id;
        _ = san;

        const duped = try self.arena.allocator().dupe(u8, str);

        const id = self.strings.items.len;
        try self.strings.append(duped);
        try self.str_map.put(duped, id);
        return id;
    }

    pub fn getResource(self: *@This(), id: vpk.VpkResId) ?[]const u8 {
        if (id >= self.strings.items.len) return null;
        return self.strings.items[id];
    }
};

pub const VisGroup = struct {
    name: []const u8,
    color: u32,
    id: u8,
    children: []const VisGroup,
};

pub const JsonCamera = struct {
    yaw: f32,
    pitch: f32,
    move_speed: f32,
    fov: f32,
    pos: Vec3,

    pub fn fromCam(cam: graph.Camera3D) @This() {
        return .{
            .yaw = cam.yaw,
            .pitch = cam.pitch,
            .move_speed = cam.move_speed,
            .fov = cam.fov,
            .pos = cam.pos,
        };
    }

    pub fn setCam(self: @This(), cam: *graph.Camera3D) void {
        const info = @typeInfo(@This());
        inline for (info.@"struct".fields) |f| {
            @field(cam, f.name) = @field(self, f.name);
        }
    }
};

pub const CURRENT_MAP_VERSION = "0.0.2";
pub const JsonEditor = struct {
    map_json_version: []const u8 = "0.0.0",
    map_version: u64 = 0,
    editor_version: []const u8 = "0.0.0",
    cam: JsonCamera,
};

/// This defines the .json map format
pub const JsonMap = struct {
    editor: JsonEditor,
    sky_name: []const u8,
    objects: []const std.json.Value,
    visgroup: ?VisGroup = null,
    /// Random crap that might change format and is not vital to parse the map is put in extra
    /// Currently holds recently used textures
    extra: std.json.Value = .{ .null = {} },
};

pub const InitFromJsonCtx = struct {
    alloc: std.mem.Allocator,
    str_store: *StringStorage,
};

const log = std.log.scoped(.json_map);
pub fn loadJson(
    ctx: InitFromJsonCtx,
    slice: []const u8,
    loadctx: anytype,
    ecs_p: *ecs.EcsT,
    vpkctx: anytype,
    groups: *ecs.Groups,
) !std.json.Parsed(JsonMap) {
    var aa = std.heap.ArenaAllocator.init(ctx.alloc);
    defer aa.deinit();
    const parsed = try std.json.parseFromSlice(JsonMap, ctx.alloc, slice, .{ .ignore_unknown_fields = true });
    loadctx.cb("json parsed");

    const cv = try version.parseSemver(CURRENT_MAP_VERSION);
    const this_v = try version.parseSemver(parsed.value.editor.map_json_version);
    if (cv[0] != this_v[0]) {
        log.err("Incompatible map json major version current: {s} map: {s}", .{
            CURRENT_MAP_VERSION, parsed.value.editor.map_json_version,
        });
        return error.versionMismatch;
    }

    const obj_o = parsed.value.objects;

    loadctx.addExpected(obj_o.len + 10);
    for (obj_o, 0..) |val, i| {
        if (val != .object) return error.invalidMap;
        const id = (val.object.get("id") orelse return error.invalidMap).integer;
        if (val.object.get("owned_group")) |owg| {
            const gid = owg.integer;
            try groups.setOwner(@intCast(gid), @intCast(id));
        }
        var it = val.object.iterator();
        var origin = Vec3.zero();
        outer: while (it.next()) |data| {
            if (std.mem.eql(u8, "id", data.key_ptr.*)) continue;
            if (std.mem.eql(u8, "owned_group", data.key_ptr.*)) continue;
            inline for (ecs.EcsT.Fields, 0..) |field, f_i| {
                if (std.mem.eql(u8, field.name, data.key_ptr.*)) {
                    const comp = try readComponentFromJson(ctx, data.value_ptr.*, field.ftype, vpkctx);
                    var should_attach = true;

                    switch (field.ftype) {
                        ecs.Entity => {
                            origin = comp.origin;
                        },
                        ecs.Solid => {
                            should_attach = comp.isValid();
                            if (!should_attach)
                                std.debug.print("omitting invalid solid id: {d}\n", .{id});
                        },
                        ecs.Groups.Group => {
                            try groups.ensureUnownedPresent(comp.id);
                        },
                        else => {},
                    }
                    if (should_attach)
                        try ecs_p.attachComponentAndCreate(@intCast(id), @enumFromInt(f_i), comp);

                    continue :outer;
                }
            }

            log.err("Invalid key : {s}", .{data.key_ptr.*});
            return error.invalidKey;
        }
        var bb = ecs.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
        bb.setFromOrigin(origin);
        try ecs_p.attachComponentAndCreate(@intCast(id), .bounding_box, bb);
        loadctx.printCb("Ent parsed {d} / {d}", .{ i, obj_o.len });
    }
    loadctx.cb("Building meshes");
    return parsed;
    //try self.rebuildAllMeshes();
}

fn readComponentFromJson(ctx: InitFromJsonCtx, v: std.json.Value, T: type, vpkctx: anytype) !T {
    const info = @typeInfo(T);
    switch (T) {
        []const u8 => {
            if (v != .string) return error.value;
            return try ctx.str_store.store(v.string);
        },
        Vec3 => {
            if (v != .string) return error.value;
            var it = std.mem.splitScalar(u8, v.string, ' ');
            const x = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const y = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const z = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            return Vec3.new(x, y, z);
        },
        ecs.Side.UVaxis => {
            if (v != .string) return error.value;
            var it = std.mem.splitScalar(u8, v.string, ' ');
            const x = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const y = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const z = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const tr = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            const sc = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
            return .{
                .axis = Vec3.new(x, y, z),
                .trans = tr,
                .scale = sc,
            };
        },
        vpk.VpkResId => {
            if (v != .string) {
                log.warn("invalid vpk id: {}", .{v});
                return 0;
            }
            const id = try vpkctx.getResourceIdString(v.string, false);
            return id orelse return error.unknownId;
        },
        else => {},
    }
    switch (info) {
        .bool, .float, .int => return try std.json.innerParseFromValue(T, ctx.alloc, v, .{}),
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "initFromJson")) {
                return try T.initFromJson(v, ctx);
            }
            if (vdf.getArrayListChild(T)) |child| {
                var ret = std.ArrayList(child).init(ctx.alloc);
                if (child == u8 and v == .string) {
                    try ret.appendSlice(v.string);
                    return ret;
                }
                if (v == .null)
                    return ret;
                if (v != .array) return error.value;
                for (v.array.items) |item|
                    try ret.append(try readComponentFromJson(ctx, item, child, vpkctx));

                return ret;
            }
            if (v != .object) return error.value;
            var ret: T = .{};
            inline for (s.fields) |field| {
                if (v.object.get(field.name)) |val| {
                    @field(ret, field.name) = try readComponentFromJson(ctx, val, field.type, vpkctx);
                } else {
                    if (vdf.getArrayListChild(field.type)) |child| {
                        @field(ret, field.name) = std.ArrayList(child).init(ctx.alloc);
                    }
                    //@field(ret, field.name) = try readComponentFromJson(ctx, .{ .null = {} }, field.type, vpkctx);
                }
            }
            return ret;
        },
        .optional => |o| {
            if (v == .null)
                return null;
            return try readComponentFromJson(ctx, v, o.child, vpkctx);
        },
        else => {},
    }
    @compileError("not sup " ++ @typeName(T));
}
