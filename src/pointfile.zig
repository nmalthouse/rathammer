const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const vmf = @import("vmf.zig");

pub const PointFile = struct {
    verts: std.array_list.Managed(Vec3),
};

pub const PortalFile = struct {
    // taken 4 at a time these are portals
    verts: std.array_list.Managed(Vec3),
};

pub fn loadPointfile(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !PointFile {
    var pf = PointFile{ .verts = .init(alloc) };

    const slice = try graph.readFile(alloc, dir, name);
    defer alloc.free(slice);
    var it = std.mem.tokenizeAny(u8, slice, "\n\r");

    while (it.next()) |line| {
        var vec = std.mem.tokenizeAny(u8, line, " \t");

        const x = try std.fmt.parseFloat(f32, vec.next() orelse return error.invalidPointFile);
        const y = try std.fmt.parseFloat(f32, vec.next() orelse return error.invalidPointFile);
        const z = try std.fmt.parseFloat(f32, vec.next() orelse return error.invalidPointFile);

        try pf.verts.append(Vec3.new(x, y, z));
    }

    return pf;
}

const log = std.log.scoped(.pointfile);
pub fn loadPortalfile(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !PortalFile {
    var pf = PortalFile{ .verts = .init(alloc) };

    const slice = try graph.readFile(alloc, dir, name);
    defer alloc.free(slice);
    var it = std.mem.tokenizeAny(u8, slice, "\n\r");
    const head = it.next() orelse return error.invalidPortalFile;
    if (!std.mem.eql(u8, head, "PTR1"))
        log.err("does not look like a portal file!", .{});

    _ = it.next() orelse return error.invalidPortalFile; // leaf count
    _ = it.next() orelse return error.invalidPortalFile; // portal count

    while (it.next()) |line| {
        var vec = std.mem.tokenizeAny(u8, line, " \t");
        _ = vec.next() orelse return error.invalidPortalFile; //vcount
        _ = vec.next() orelse return error.invalidPortalFile; //leaf a
        _ = vec.next() orelse return error.invalidPortalFile; //leaf b

        var i: usize = 0;
        const rest = vec.rest();
        for (0..4) |_| {
            const v = try vmf.parseVec(rest, &i, 3, '(', ')', f32);
            try pf.verts.append(Vec3.new(v[0], v[1], v[2]));
        }
    }

    return pf;
}
