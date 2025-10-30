const std = @import("std");
const vpk = @import("../vpk.zig");
const LoadCtx = @import("../util.zig").LoadCtxDummy;

test {
    //This leaks because of a bug in 0.15.2 std reader.appendRemaining
    const alloc = std.testing.allocator;
    var ctx = try vpk.Context.init(alloc);
    defer ctx.deinit();

    var loadctx = LoadCtx{};
    var extra = try std.fs.cwd().openDir("extra", .{});
    defer extra.close();
    try ctx.addDir(extra, "vpktest.vpk", &loadctx);
    try ctx.addLooseDir(std.fs.cwd(), "rat_custom/asset");
    try ctx.addLooseDir(std.fs.cwd(), ".");
    try ctx.slowIndexOfLooseDirSubPath("materials");

    const f = try ctx.getFileTempFmt("txt", "dir2/test", .{}, false) orelse return error.notFound;
    std.debug.print("{s}\n", .{f});
    try std.testing.expectEqualDeep("testcontents\n", f);

    const loose_img = try ctx.getFileTempFmt("png", "materials/splash", .{}, false) orelse return error.notFound;
    _ = loose_img;

    const id = try ctx.getResourceIdString("extra/vmf_ex.vdf", false) orelse return error.notId;
    const loose_unindexed = try ctx.getFileFromRes(id, .{ .list = &ctx.filebuf, .alloc = ctx.alloc }) orelse return error.notFound;
    _ = loose_unindexed;
}
