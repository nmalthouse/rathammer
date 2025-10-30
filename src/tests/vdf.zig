const std = @import("std");
const vdf_serial = @import("../vdf_serial.zig");
const vdf = @import("../vdf.zig");
const util = @import("../util.zig");
const VdfWriter = vdf_serial.VdfWriter;

test {
    const alloc = std.testing.allocator;

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    var s = VdfWriter.init(alloc, &out.writer);
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
        std.debug.print("{s}\n", .{out.written()});
        std.debug.print("{s}\n", .{expected});
    }
    try std.testing.expectEqualDeep(expected, out.written());
}

const parse = vdf.parse;
const fromValue = vdf.fromValue;
const Tokenizer = vdf.Tokenizer;
const Tag = vdf.Tag;
const print = vdf.print;
const ErrorInfo = vdf.ErrorInfo;
const Parsed = vdf.Parsed;

const TestExpected = struct {
    slice: []const u8,
    tok: []const Tag,
};

test "basic" {
    const ex = std.testing.expectEqual;

    const tt = [_]TestExpected{
        .{ .slice = "hello world", .tok = &.{ .string, .string } },
        .{ .slice = "this is{ not valid }", .tok = &.{ .string, .string, .open_bracket, .string, .string, .close_bracket } },
        .{ .slice = "this is{ not valid \"u { } a b \"}", .tok = &.{ .string, .string, .open_bracket, .string, .string, .quoted_string, .close_bracket } },
        .{ .slice = "this is{ not valid \"u { } a b \" }", .tok = &.{ .string, .string, .open_bracket, .string, .string, .quoted_string, .close_bracket } },
        .{ .slice = "hello world //comment", .tok = &.{ .string, .string, .comment } },
        .{ .slice = 
        \\ test { //multi
        \\ dict item 
        \\ }
        , .tok = &.{ .string, .open_bracket, .comment, .newline, .string, .string, .newline, .close_bracket } },
    };
    print("START\n", .{});
    if (false) {
        const crass = tt[1];
        var tok = Tokenizer{ .slice = crass.slice };
        while (try tok.next()) |ttt|
            print("{any}\n", .{ttt});
    }
    for (tt) |test1| {
        var tok = Tokenizer{ .slice = test1.slice };
        for (test1.tok) |t| {
            const tag = (try tok.next()).?.tag;
            print("TAG {s}\n", .{@tagName(tag)});
            try ex(t, tag);
        }
    }
}

const TestCtx = struct {
    const ex = std.testing.expectEqual;
    tok: Tokenizer,

    fn nextString(self: *@This(), str: []const u8) !void {
        const a = (try self.tok.next()) orelse return error.endOfStream;
        if (a.tag == .string or a.tag == .quoted_string) {
            const sl = self.tok.getSlice(a);
            if (std.mem.eql(u8, str, sl)) {
                return;
            }
            print("Expected \"{s}\" found \"{s}\"\n", .{ str, sl });
            return error.stringMismatch;
        }
        return error.expectedString;
    }

    fn nextTag(self: *@This(), tag: Tag) !void {
        const a = (try self.tok.next()) orelse return error.endOfStream;
        try ex(tag, a.tag);
    }

    fn nextTagC(self: *@This(), tag: Tag, str: []const u8) !void {
        const a = (try self.tok.next()) orelse return error.endOfStream;
        try ex(tag, a.tag);
        const sl = self.tok.getSlice(a);
        if (std.mem.eql(u8, str, sl)) {
            return;
        }
        print("Expected \"{s}\" found \"{s}\"\n", .{ str, sl });
        return error.stringMismatch;
    }
};
const test_slice1 =
    \\just literal
    \\hello     {
    \\ world " this " //comment
    \\}
    \\this{is commpact}
    \\line//comment
;

const test_slice2 =
    \\hello world
    \\this {
    \\  key1 value1
    \\  key2 value2
    \\}
;

test "correct strings" {
    var ct = TestCtx{
        .tok = Tokenizer{ .slice = test_slice1 },
    };
    try ct.nextString("just");
    try ct.nextString("literal");
    try ct.nextTag(.newline);
    try ct.nextString("hello");
    try ct.nextTag(.open_bracket);
    try ct.nextTag(.newline);
    try ct.nextString("world");
    try ct.nextString(" this ");
    try ct.nextTagC(.comment, "comment");
    try ct.nextTag(.newline);
    try ct.nextTag(.close_bracket);
    try ct.nextTag(.newline);
    try ct.nextString("this");
    try ct.nextTag(.open_bracket);
    try ct.nextString("is");
    try ct.nextString("commpact");
    try ct.nextTag(.close_bracket);
    try ct.nextTag(.newline);
    try ct.nextString("line");
    try ct.nextTagC(.comment, "comment");
}

test "correct 2" {
    const slice =
        \\ focus_search "ctrl+keycode:f"
        \\ "test"     key2
    ;
    var ct = TestCtx{
        .tok = Tokenizer{ .slice = slice },
    };
    try ct.nextString("focus_search");
    try ct.nextString("ctrl+keycode:f");
    try ct.nextTag(.newline);
    try ct.nextString("test");
    try ct.nextString("key2");

    const alloc = std.testing.allocator;
    var p = try parse(alloc, slice, null, .{});
    defer p.deinit();
}

//TODO test thing with error
//test error message line and char numbers are correct.
test "parse basic" {
    const exd = std.testing.expectEqualDeep;
    const alloc = std.testing.allocator;
    var p = try parse(alloc, test_slice2, null, .{});
    defer p.deinit();

    try exd(p.value.getFirst(try p.stringId("hello")).?.literal, "world");
    const obj = p.value.getFirst(try p.stringId("this")).?.obj;
    try exd(obj.getFirst(try p.stringId("key1")).?.literal, "value1");
    try exd(obj.getFirst(try p.stringId("key2")).?.literal, "value2");
}

const test_slice_error =
    \\hello {
    \\  key1 key2 extra
    \\}
;

fn expectParseError(slice: []const u8, ex_err: anyerror, line_num: usize) !void {
    const exd = std.testing.expectEqual;
    const alloc = std.testing.allocator;
    var einfo = ErrorInfo{};
    var p = parse(alloc, slice, &einfo, .{ .strict_one_kv_per_line = true }) catch |err| {
        try exd(ex_err, err);
        try exd(line_num, einfo.line_number);

        print("{t} {d}:{d}\n", .{ err, einfo.line_number, einfo.char_number });
        var tok = std.mem.tokenizeScalar(u8, slice[einfo.line_start..], '\n');
        if (tok.next()) |line| {
            print("{s}\n", .{line});
            for (2..einfo.char_number) |_|
                print(" ", .{});
            print("^\n", .{});
        }
        return;
    };
    defer p.deinit();
}

test "parse errors" {
    try expectParseError("hello {\n  key1 key2 extra\n}", error.expectedNewline, 2);
    try expectParseError("hello {\n  key1\n}", error.expectedValue, 3);
}

fn testLoadVdf(dir: std.fs.Dir, filename: []const u8, opts: Parsed.Opts) !Parsed {
    const alloc = std.testing.allocator;

    const slice = try util.readFile(alloc, dir, filename);
    defer alloc.free(slice);

    var einfo = ErrorInfo{};
    return parse(alloc, slice, &einfo, opts) catch |err| {
        einfo.printError(std.debug.print, err);
        return err;
    };
}

test "conf2" {
    const vmf = @import("../vmf.zig");
    var a1 = try testLoadVdf(std.fs.cwd(), "config.vdf", .{});
    a1.deinit();
    var a2 = try testLoadVdf(std.fs.cwd(), "extra/sdk_materials.vmf", .{ .strict_one_kv_per_line = false });
    defer a2.deinit();

    const alloc = std.testing.allocator;
    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const vm = try fromValue(vmf.Vmf, &a2, &.{ .obj = &a2.value }, aa.allocator(), null);
    _ = vm;
}

test "parse vdf" {}

test "test_vmf" {
    const alloc = std.testing.allocator;
    const slice = try util.readFile(alloc, std.fs.cwd(), "extra/vmf_ex.vdf");
    defer alloc.free(slice);
    var ct = TestCtx{ .tok = Tokenizer{ .slice = slice } };

    try ct.nextString("versioninfo");
    try ct.nextTag(.newline);
    try ct.nextTag(.open_bracket);
}

const TestStructInner = struct {
    enum_: enum { one, two } = .one,
    a: i32 = 0,
    b: f32 = 0,
    is: bool = false,
    str: []const u8 = "",
    num: []const u32 = &.{},
};

const TestStruct = struct {
    hello: []const u8 = "",
    obj: TestStructInner = .{},
};

const test_slice_auto =
    \\hello world //Comment
    \\obj {
    \\enum_ two
    \\a 33
    \\b 1.1
    \\is true
    \\str cool
    \\num 1
    \\num 2
    \\num 3
    \\}
;

test "fromValue" {
    const ex = std.testing.expectEqualDeep;
    const alloc = std.testing.allocator;
    var p = try parse(alloc, test_slice_auto, null, .{});
    defer p.deinit();
    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const a = try fromValue(TestStruct, &p, &.{ .obj = &p.value }, aa.allocator(), null);
    try ex(TestStruct{ .hello = "world", .obj = .{
        .enum_ = .two,
        .a = 33,
        .b = 1.1,
        .is = true,
        .str = "cool",
        .num = &.{ 1, 2, 3 },
    } }, a);
}

test "fromValueArrayList" {
    const testsl =
        \\  a 1
        \\  a 2
        \\  a 3
    ;
    const ex = std.testing.expectEqualDeep;
    const alloc = std.testing.allocator;
    var p = try parse(alloc, testsl, null, .{});
    defer p.deinit();
    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const St = struct {
        a: std.ArrayListUnmanaged(u32) = .{},
        b: std.ArrayListUnmanaged(u32) = .{},
    };
    const a = try fromValue(St, &p, &.{ .obj = &p.value }, aa.allocator(), null);
    try ex(&[_]u32{ 1, 2, 3 }, a.a.items);
    try ex(&[_]u32{}, a.b.items);
    try ex(0, a.b.capacity);
}
