const std = @import("std");
const vdf_serial = @import("../vdf_serial.zig");
const WriteVdf = vdf_serial.WriteVdf;

test {
    const alloc = std.testing.allocator;
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(alloc);
    const wr = out.writer(alloc);
    var s = WriteVdf(@TypeOf(wr)).init(alloc, wr);
    defer s.deinit();
    try s.writeKey("hello");
    try s.beginObject();
    {
        try s.writeKey("key1");
        try s.writeValue("val1");

        try s.printKey("key{d}", .{3});
        try s.printValue("val{d}", .{3});

        try s.writeKey("big key with  {} stuff");
        try s.writeValue("another valuehLL");

        try s.writeKey("bv");
        {
            try s.beginValue();
            try s.printInnerValue("{d}", .{3});
            try s.endValue();
        }

        try s.writeKey("My object");
        try s.beginObject();
        try s.writeComment("hello", .{});
        {
            try s.writeKey("Hello");
            try s.writeValue("world");
            try s.writeKv("myint", .{ .a = @as(i32, 3), .b = @as(f32, 2) });
        }
        try s.endObject();
    }
    try s.endObject();

    const expected =
        \\hello {
        \\    key1 val1
        \\    key3 val3
        \\    "big key with  {} stuff" "another valuehLL"
        \\    bv "3"
        \\    "My object" {
        \\        //hello
        \\        Hello world
        \\        myint {
        \\            a "3"
        \\            b "2"
        \\        }
        \\    }
        \\}
        \\
    ;

    if (false) {
        std.debug.print("\n", .{});
        std.debug.print("{s}\n", .{out.items});
        std.debug.print("{s}\n", .{expected});
    }
    try std.testing.expectEqualDeep(expected, out.items);
}
