const std = @import("std");
const rpc = @import("rpc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    _ = args.next() orelse return error.broken;

    const stream = try std.net.connectUnixSocket(args.next() orelse {
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

    const read_thread = try std.Thread.spawn(.{}, readThread, .{ stream, &readbuf });
    _ = read_thread;
    while (true) {
        const command = try stdin.takeDelimiter('\n') orelse break;
        var it = std.mem.tokenizeScalar(u8, command, ' ');
        const method = it.next() orelse break;

        arg_buf.clearRetainingCapacity();
        while (it.next()) |arg| {
            try arg_buf.append(.{ .string = arg });
        }

        //--> {"jsonrpc": "2.0", "method": "subtract", "params": {"minuend": 42, "subtrahend": 23}, "id": 3}
        buf.clearRetainingCapacity();
        try std.json.Stringify.value(rpc.JsonRpcRequest{
            .jsonrpc = "2.0",
            .method = method,
            .params = .{ .array = arg_buf },
            .id = 0,
        }, .{}, &buf.writer);

        const slice = buf.written();
        try wr.interface.print("{d}:{s},", .{ slice.len, slice });
        try wr.interface.flush();
    }
}

fn readThread(stream: std.net.Stream, msg_buf: *std.Io.Writer.Allocating) !void {
    var read_buf: [1024]u8 = undefined;
    var read = stream.reader(&read_buf);
    const r = read.interface();

    while (true) {
        const length_str = (r.takeDelimiter(':') catch null) orelse break;
        const length = try std.fmt.parseInt(u32, length_str, 10);
        msg_buf.clearRetainingCapacity();
        _ = try r.stream(&msg_buf.writer, .limited(length));

        if (try r.takeByte() != ',') return error.expectedComma;

        std.debug.print("{s}\n", .{msg_buf.written()});
    }
}
