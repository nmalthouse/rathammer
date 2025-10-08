const std = @import("std");
const jm = @import("../json_map.zig");
const Str = @import("../string.zig");
const Value = std.json.Value;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const ecs = @import("../ecs.zig");
const vpk = @import("../vpk.zig");

const Custom = struct {
    int: u32 = 0,
    pub fn initFromJson(v: Value, ctx: jm.InitFromJsonCtx) !@This() {
        _ = v;
        _ = ctx;
        return .{ .int = 4 };
    }
};

const ex = std.testing.expectEqualDeep;
test {
    const alloc = std.testing.allocator;

    var strings = try Str.StringStorage.init(alloc);
    defer strings.deinit();

    const ctx = jm.InitFromJsonCtx{ .alloc = alloc, .str_store = &strings };

    //TODO put arraylist
    const St = struct {
        _alloc: std.mem.Allocator, //The only field than does not need a default
        string: []const u8 = "",
        vec: Vec3 = Vec3.zero(),
        uv: ecs.Side.UVaxis = .{},
        uv2: ecs.Side.UVaxis = .{},
        id: vpk.VpkResId = 0,
        id2: vpk.VpkResId = 0,
        bo: bool = false,
        int: i32 = 0,
        cc: Custom = .{},
    };
    const sl =
        \\{
        \\ "string":"hello",
        \\ "vec":"1 2 3",
        \\ "uv2":"1 2 3 40 10",
        \\ "id": "myid",
        \\ "bo": true,
        \\ "int": 32,
        \\ "cc": {"int":1},
        \\
        \\
        \\ "id2":"id2"
        \\}
    ;

    var parsed = try std.json.parseFromSlice(Value, alloc, sl, .{});
    defer parsed.deinit();

    var vpkctx = jm.VpkMapper.init(alloc);
    defer vpkctx.deinit();

    const comp = try jm.readComponentFromJson(ctx, parsed.value, St, &vpkctx);
    try ex(St{
        ._alloc = ctx.alloc,
        .string = "hello",
        .vec = Vec3.new(1, 2, 3),
        .uv = .{},
        .uv2 = .{
            .axis = Vec3.new(1, 2, 3),
            .trans = 40,
            .scale = 10,
        },
        .id = 0,
        .id2 = 1,
        .bo = true,
        .int = 32,
        .cc = .{ .int = 4 },
    }, comp);
}

test "array list" {
    const alloc = std.testing.allocator;

    var strings = try Str.StringStorage.init(alloc);
    defer strings.deinit();

    const ctx = jm.InitFromJsonCtx{ .alloc = alloc, .str_store = &strings };
    const St = struct {
        _alloc: std.mem.Allocator, // <- allocates the array lists
        arr1: std.ArrayListUnmanaged(u32) = .{},
    };
    const sl =
        \\ {
        \\ "arr1": [1,2,3]
        \\
        \\
        \\
        \\ }
    ;

    var parsed = try std.json.parseFromSlice(Value, alloc, sl, .{});
    defer parsed.deinit();

    var vpkctx = jm.VpkMapper.init(alloc);
    defer vpkctx.deinit();
    var comp = try jm.readComponentFromJson(ctx, parsed.value, St, &vpkctx);
    try ex(&[_]u32{ 1, 2, 3 }, comp.arr1.items);

    comp.arr1.deinit(comp._alloc);
}
