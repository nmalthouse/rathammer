const std = @import("std");
const rpc = @import("rpc.zig");
const graph = @import("graph");
const prompt = ">>> ";
const Arg = graph.ArgGen.Arg;
const Kind = enum {
    command,
    raw,
};
pub const Args = [_]graph.ArgGen.ArgItem{
    Arg("crap", .string, "vmf or json to load"),
    Arg("socket", .string, "socket to connect"),
    graph.ArgGen.ArgCustom("kind", Kind, "type of session to start"),
};

pub fn remote(arg_it: *std.process.ArgIterator, alloc: std.mem.Allocator, stdout: *std.io.Writer) !void {
    const args = try graph.ArgGen.parseArgs(&Args, arg_it);
    const kind = args.kind orelse .command;

    const stream = try std.net.connectUnixSocket(args.socket orelse {
        std.debug.print("Expected name of socket to open\n", .{});
        return;
    });
    defer stream.close();

    var write_buf: [1024]u8 = undefined;

    var wr = stream.writer(&write_buf);
    var stdin_buf: [1024]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var readbuf: std.Io.Writer.Allocating = .init(alloc);

    var arg_buf = std.array_list.Managed(std.json.Value).init(alloc);
    defer arg_buf.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    //const read_thread = try std.Thread.spawn(.{}, readThread, .{ stream, &readbuf, alloc });
    //_ = read_thread;
    switch (kind) {
        .command => {
            var read_buf: [1024]u8 = undefined;
            var read = stream.reader(&read_buf);
            const r = read.interface();
            while (true) {
                try stdout.print("{s}", .{prompt});
                try stdout.flush();

                const command = try stdin.takeDelimiter('\n') orelse break;
                var it = std.mem.tokenizeScalar(u8, command, ' ');

                arg_buf.clearRetainingCapacity();
                while (it.next()) |arg| {
                    try arg_buf.append(.{ .string = arg });
                }

                buf.clearRetainingCapacity();
                try std.json.Stringify.value(rpc.JsonRpcRequest{
                    .jsonrpc = "2.0",
                    .method = "shell",
                    .params = .{ .array = arg_buf },
                    .id = 0,
                }, .{}, &buf.writer);

                const slice = buf.written();
                try wr.interface.print("{d}:{s},", .{ slice.len, slice });
                try wr.interface.flush();

                _ = arena.reset(.retain_capacity);

                try awaitResponse(stdout, arena.allocator(), r, &readbuf);
            }
        },
        else => return error.notImplemented,
    }
}

fn readThread(stream: std.net.Stream, msg_buf: *std.Io.Writer.Allocating, alloc: std.mem.Allocator) !void {
    var read_buf: [1024]u8 = undefined;
    var read = stream.reader(&read_buf);
    const r = read.interface();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    while (true) {
        _ = arena.reset(.retain_capacity);

        const parsed = rpc.parseSafe(arena.allocator(), r, msg_buf, rpc.JsonRpcResponse) catch |err| switch (err) {
            error.invalidStream => return,
            error.invalidJson => {
                std.debug.print("recieved invalid response\n", .{});
                continue;
            },
        };

        for (parsed) |pa| {
            switch (pa.result) {
                else => {},
                .string => |str| {
                    //TODO properly convert all escapes
                    var it = std.mem.tokenizeSequence(u8, str, "\n");
                    while (it.next()) |item| {
                        try stdout.print("{s}\n", .{item});
                    }

                    try stdout.flush();
                },
            }
        }
    }
}

fn awaitResponse(stdout: *std.Io.Writer, alloc: std.mem.Allocator, r: *std.Io.Reader, msg_buf: *std.Io.Writer.Allocating) !void {
    const parsed = rpc.parseSafe(alloc, r, msg_buf, rpc.JsonRpcResponse) catch |err| switch (err) {
        error.invalidStream => return,
        error.invalidJson => {
            std.debug.print("recieved invalid response\n", .{});
            return;
        },
    };

    for (parsed) |pa| {
        switch (pa.result) {
            else => {},
            .string => |str| {
                //TODO properly convert all escapes
                var it = std.mem.tokenizeSequence(u8, str, "\n");
                while (it.next()) |item| {
                    try stdout.print("{s}\n", .{item});
                }

                try stdout.flush();
            },
        }
    }
}
