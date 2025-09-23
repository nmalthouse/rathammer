const std = @import("std");
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

    var wr = stream.writer();
    const stdin = std.io.getStdIn();
    var r = stdin.reader();
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var rbuf = std.ArrayList(u8).init(alloc);

    const read_thread = try std.Thread.spawn(.{}, readThread, .{ stream, &rbuf });
    _ = read_thread;
    while (true) {
        buf.clearRetainingCapacity();

        try r.readUntilDelimiterArrayList(&buf, '\n', std.math.maxInt(usize));

        //try wr.writeInt(u32, @intCast(buf.items.len), .big);
        //try wr.writeInt(u16, 0, .big);

        try wr.print("{d}:{s},", .{ buf.items.len, buf.items });
    }
}

fn readThread(stream: std.net.Stream, msg_buf: *std.ArrayList(u8)) !void {
    var r = stream.reader();
    while (true) {
        msg_buf.clearRetainingCapacity();
        r.streamUntilDelimiter(msg_buf.writer(), ':', null) catch break;

        const length = try std.fmt.parseInt(u32, msg_buf.items, 10);
        try msg_buf.resize(length);
        try r.readNoEof(msg_buf.items);

        std.debug.print("{s}\n", .{msg_buf.items});
        const expect_comma = try r.readByte();
        if (expect_comma != ',') return error.expectedComma;
    }
}
