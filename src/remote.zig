const std = @import("std");
const RatApp = enum {
    mapbuilder,
    convert,
    remote,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const exe_name = arg_it.next() orelse return error.invalidArgIt;
    _ = exe_name;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const app = std.meta.stringToEnum(RatApp, arg_it.next() orelse "") orelse {
        try stdout.print("Expected name of app to run: \n", .{});
        inline for (@typeInfo(RatApp).@"enum".fields) |field| {
            try stdout.print("\t{s}\n", .{field.name});
        }
        try stdout.flush();

        return;
    };

    switch (app) {
        .mapbuilder => try @import("map_builder.zig").main(&arg_it, alloc, stdout),
        .convert => try @import("jsonToVmf.zig").main(&arg_it, alloc, stdout),
        .remote => try @import("rpc/remote.zig").remote(&arg_it, alloc, stdout),
    }

    try stdout.flush();
}
