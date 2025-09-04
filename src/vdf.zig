const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const TEST_DEBUG_OUTPUT = false;
fn dummyPrint(_: []const u8, _: anytype) void {}
const print = if (TEST_DEBUG_OUTPUT) std.debug.print else dummyPrint;

const graph = @import("graph");
pub const Vec3 = graph.za.Vec3_f64;
pub const StringKey = u32;
pub const KV = struct {
    pub const Value = union(enum) { literal: []const u8, obj: *Object };
    key: StringKey,
    val: Value,
};

pub const Object = struct {
    const Self = @This();
    list: ArrayList(KV) = .{},

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }

    pub fn append(self: *Self, alloc: std.mem.Allocator, kv: KV) !void {
        try self.list.append(alloc, kv);
    }

    pub fn getFirst(self: *Self, id: StringKey) ?KV.Value {
        for (self.list.items) |item| {
            if (id == item.key)
                return item.val;
        }
        return null;
    }

    /// Given a string: first.second.third
    pub fn recursiveGetFirst(self: *Self, p: *Parsed, keys: []const []const u8) !KV.Value {
        if (keys.len == 0)
            return error.invalid;

        const id = try p.stringId(keys[0]);
        const n = self.getFirst(id) orelse return error.invalidKey;
        if (keys.len == 1)
            return n;
        if (n != .obj)
            return error.invalid;
        return n.obj.recursiveGetFirst(p, keys[1..]);
    }
};

pub const Parsed = struct {
    const Opts = struct {
        strict_one_kv_per_line: bool = false,
    };
    const Self = @This();
    value: Object,
    strings: ArrayList([]const u8) = .{},
    string_map: std.StringHashMap(StringKey),
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    opts: Opts = .{},

    pub fn deinit(self: *@This()) void {
        self.strings.deinit(self.alloc);
        self.string_map.deinit();
        self.arena.deinit();
    }

    pub fn stringFromId(self: *Self, id: StringKey) ?[]const u8 {
        if (id >= self.strings.items.len) return null;
        return self.strings.items[id];
    }

    pub fn stringId(self: *Self, str: []const u8) !StringKey {
        if (self.string_map.get(str)) |id|
            return id;
        const id: StringKey = @intCast(self.strings.items.len);
        const dupe = try self.arena.allocator().dupe(u8, str);
        try self.strings.append(self.alloc, dupe);
        try self.string_map.put(dupe, id);
        return id;
    }
};

//Pass a pointer to this
pub const ErrorInfo = struct {
    line_number: usize = 0,
    char_number: usize = 0,
    line_start: usize = 0,
    slice: []const u8 = "",

    pub fn printError(self: @This(), print_func: fn (comptime []const u8, anytype) void, err: anyerror) void {
        print_func("{!} {d}:{d}\n", .{ err, self.line_number, self.char_number });
        var tok = std.mem.tokenizeScalar(u8, self.slice[self.line_start..], '\n');
        if (tok.next()) |line| {
            print_func("{s}\n", .{line});
            for (0..self.char_number) |_|
                print_func(" ", .{});
            print_func("^\n", .{});
        }
    }
};

pub fn parse(alloc: std.mem.Allocator, slice: []const u8, err_info: ?*ErrorInfo, opts: Parsed.Opts) !Parsed {
    var parsed = Parsed{
        .value = .{},
        .string_map = std.StringHashMap(StringKey).init(alloc),
        .alloc = alloc,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .opts = opts,
    };
    errdefer parsed.deinit();
    const aa = parsed.arena.allocator();

    var object_stack = ArrayList(*Object){};
    defer object_stack.deinit(alloc);

    var root_object = Object.init();
    var root = &root_object;

    var it = Tokenizer{ .slice = slice };
    errdefer {
        if (err_info) |einfo| {
            einfo.line_number = it.line_counter;
            einfo.char_number = it.char_counter;
            einfo.line_start = it.line_start;
            einfo.slice = it.slice;
        }
    }
    var key: StringKey = 0;
    var key_buf: [256]u8 = undefined;

    var expected: enum { key, value, newline } = .key;
    while (try it.next()) |token| {
        const sl = it.getSlice(token);
        switch (expected) {
            .key => switch (token.tag) {
                .comment, .newline => {},
                .string, .quoted_string => {
                    const key_str = std.ascii.lowerString(&key_buf, sl);
                    key = try parsed.stringId(key_str);
                    expected = .value;
                },
                .close_bracket => {
                    root = object_stack.pop() orelse return error.invalidBraces;
                    expected = .key;
                    if (parsed.opts.strict_one_kv_per_line)
                        expected = .newline;
                },
                else => return error.expectedKey,
            },
            .value => switch (token.tag) {
                .string, .quoted_string => {
                    try root.append(aa, .{ .key = key, .val = .{ .literal = try aa.dupe(u8, sl) } });
                    expected = .key;
                    if (parsed.opts.strict_one_kv_per_line)
                        expected = .newline;
                },
                .open_bracket => {
                    const new_root = try aa.create(Object);
                    new_root.* = Object.init();
                    try root.append(aa, .{ .key = key, .val = .{ .obj = new_root } });
                    try object_stack.append(alloc, root);
                    root = new_root;
                    expected = .key;
                    if (parsed.opts.strict_one_kv_per_line)
                        expected = .newline;
                },
                .newline, .comment => {
                    if (parsed.opts.strict_one_kv_per_line)
                        return error.expectedValue;
                },
                else => return error.expectedValue,
            },
            .newline => switch (token.tag) {
                .comment, .newline => expected = .key,
                else => return error.expectedNewline,
            },
        }
        //switch (token.tag){}
    }
    parsed.value = root_object;
    return parsed;
}

pub const Tag = enum {
    newline,
    open_bracket,
    close_bracket,
    string,
    quoted_string,
    comment,
};

pub const Token = struct {
    pub const Pos = struct { start: usize, end: usize };
    tag: Tag,
    pos: Pos,
};

pub const Tokenizer = struct {
    slice: []const u8,
    pos: usize = 0,

    line_start: usize = 0,
    line_counter: usize = 1,
    char_counter: usize = 1,

    opts: struct {
        allow_newline_in_string: bool = true,
    } = .{},

    pub fn getSlice(self: @This(), token: Token) []const u8 {
        return self.slice[token.pos.start..token.pos.end];
    }

    pub fn next(self: *@This()) !?Token {
        errdefer print("POS {d}\n", .{self.pos});

        var state: enum {
            start,
            quoted,
            string,
            comment,
        } = .start;
        var res = Token{ .pos = .{ .start = self.pos, .end = self.pos }, .tag = .newline };
        self.char_counter = self.pos;
        if (self.pos >= self.slice.len)
            return null;
        while (self.pos < self.slice.len) : (self.pos += 1) {
            const ch = self.slice[self.pos];
            print("st {c} {any}\n", .{ ch, res });

            switch (state) {
                .comment => switch (ch) {
                    '\n' => {
                        res.tag = .comment;
                        res.pos.end = self.pos;
                        return res;
                    },
                    else => {},
                },
                .start => switch (ch) {
                    '\n', '\r' => {
                        const other: u8 = if (ch == '\n') '\r' else '\n';
                        res.tag = .newline;
                        self.pos += 1;
                        if (self.pos < self.slice.len and self.slice[self.pos] == other)
                            self.pos += 1;

                        self.line_start = self.pos + 1;
                        self.line_counter += 1;
                        self.char_counter = 1;
                        return res;
                    },
                    ' '...'~', '\t' => {
                        switch (ch) {
                            '/' => {
                                if (self.pos + 1 < self.slice.len and self.slice[self.pos + 1] == '/') {
                                    res.pos.start = self.pos + 2;
                                    state = .comment;
                                }
                            },
                            '\"' => {
                                state = .quoted;
                                res.pos.start = self.pos + 1;
                            },
                            '{', '}' => {
                                res.tag = if (ch == '{') .open_bracket else .close_bracket;
                                self.pos += 1;
                                return res;
                            },
                            ' ', '\t' => {},
                            else => {
                                state = .string;
                                res.pos.start = self.pos;
                            },
                        }
                    },
                    else => return error.invalidChar,
                },
                .string => switch (ch) {
                    '\n', '\r' => {
                        res.tag = .string;
                        res.pos.end = self.pos;
                        return res;
                    },
                    ' '...'~', '\t' => {
                        switch (ch) {
                            '"' => return error.invalidString,
                            ' ', '\t' => {
                                res.tag = .string;
                                res.pos.end = self.pos;
                                self.pos += 1;
                                return res;
                            },
                            '/' => {
                                if (self.pos + 1 < self.slice.len and self.slice[self.pos + 1] == '/') {
                                    res.tag = .string;
                                    res.pos.end = self.pos;
                                    return res;
                                }
                            },
                            '{', '}' => {
                                res.tag = .string;
                                res.pos.end = self.pos;
                                return res;
                            },
                            else => {},
                        }
                    },
                    else => return error.invalidString,
                },
                .quoted => switch (ch) {
                    '\"' => {
                        res.tag = .quoted_string;
                        res.pos.end = self.pos;
                        self.pos += 1; // Eat the quote
                        return res;
                    },
                    '\n', '\r' => {
                        if (!self.opts.allow_newline_in_string)
                            return error.newlineInString;
                    },
                    else => {},
                },
            }
        }
        switch (state) {
            .comment => {
                res.tag = .comment;
                res.pos.end = self.pos;
                return res;
            },
            .start => return null,
            .quoted => return error.missingQuote,
            .string => {
                res.tag = .string;
                res.pos.end = self.pos;
                return res;
            },
        }
    }
};

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

        print("{!} {d}:{d}\n", .{ err, einfo.line_number, einfo.char_number });
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

fn testLoadVdf(dir: std.fs.Dir, filename: []const u8, opts: Parsed.Opts) !void {
    const alloc = std.testing.allocator;
    const conf = try dir.openFile(filename, .{});
    defer conf.close();

    const slice = try conf.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var einfo = ErrorInfo{};
    var p = parse(alloc, slice, &einfo, opts) catch |err| {
        einfo.printError(std.debug.print, err);
        return err;
    };
    defer p.deinit();
}

test "conf2" {
    try testLoadVdf(std.fs.cwd(), "config.vdf", .{});
    try testLoadVdf(std.fs.cwd(), "extra/sdk_materials.vmf", .{ .strict_one_kv_per_line = false });
}

test "test_vmf" {
    const alloc = std.testing.allocator;
    const sl = try std.fs.cwd().openFile("extra/vmf_ex.vdf", .{});
    const slice = try sl.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    sl.close();
    defer alloc.free(slice);
    var ct = TestCtx{ .tok = Tokenizer{ .slice = slice } };

    try ct.nextString("versioninfo");
    try ct.nextTag(.newline);
    try ct.nextTag(.open_bracket);
}

pub fn getArrayListChild(comptime T: type) ?type {
    const in = @typeInfo(T);
    if (in != .@"struct")
        return null;
    if (@hasDecl(T, "Slice")) {
        const info = @typeInfo(T.Slice);
        if (info == .pointer and info.pointer.size == .slice) {
            const t = std.ArrayListUnmanaged(info.pointer.child);
            const managed = std.ArrayList(info.pointer.child);
            if (T == t)
                return info.pointer.child;
            if (T == managed)
                @compileError("managed array list not supported " ++ @typeName(T));
        }
    }
    return null;
}

pub const KVMap = std.AutoHashMap(StringKey, []const u8);
const MAX_KVS = 512;
const KVT = std.bit_set.StaticBitSet(MAX_KVS);
threadlocal var from_value_visit_tracker = KVT.initEmpty();
const StringStorage = @import("string.zig").StringStorage;
pub fn fromValue(comptime T: type, parsed: *Parsed, value: *const KV.Value, alloc: std.mem.Allocator, strings: ?*StringStorage) !T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "parseVdf")) {
                return try T.parseVdf(parsed, value, alloc, strings);
            }

            //IF hasField vdf_generic then
            //add any fields that were not visted to vdf_generic
            var ret: T = undefined;
            if (value.* != .obj) {
                return error.broken;
            }
            const DO_REST = @hasField(T, "rest_kvs");
            if (DO_REST) {
                ret.rest_kvs = KVMap.init(alloc);
                from_value_visit_tracker = KVT.initEmpty();
                if (value.obj.list.items.len > MAX_KVS)
                    return error.tooManyKeys;
            }
            inline for (s.fields) |f| {
                const f_id = try parsed.stringId(f.name);
                if (f.type == KVMap) {} else {
                    const child_info = @typeInfo(f.type);
                    const is_alist = getArrayListChild(f.type);
                    const do_many = (is_alist != null) or (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child != u8);
                    if (!do_many and f.default_value_ptr != null) {
                        @field(ret, f.name) = @as(*const f.type, @alignCast(@ptrCast(f.default_value_ptr.?))).*;
                    }
                    const ar_c = is_alist orelse if (do_many) child_info.pointer.child else void;
                    var vec = std.ArrayListUnmanaged(ar_c){};

                    for (value.obj.list.items, 0..) |*item, vi| {
                        if (f_id == item.key) {
                            if (do_many) {
                                const val = fromValue(ar_c, parsed, &item.val, alloc, strings) catch blk: {
                                    //std.debug.print("parse FAILED {any}\n", .{item.val});
                                    break :blk null;
                                };
                                if (val) |v| {
                                    try vec.append(alloc, v);
                                    if (DO_REST)
                                        from_value_visit_tracker.set(vi);
                                }
                            } else {
                                //A regular struct field
                                @field(ret, f.name) = fromValue(f.type, parsed, &item.val, alloc, strings) catch |err| {
                                    std.debug.print("KEY: {s}\n", .{f.name});
                                    return err;
                                };
                                if (DO_REST)
                                    from_value_visit_tracker.set(vi);
                                break;
                            }
                        }
                    }
                    if (do_many) {
                        @field(ret, f.name) = if (is_alist != null) vec else vec.items;
                    }
                }
            }
            if (DO_REST) {
                var it = from_value_visit_tracker.iterator(.{ .kind = .unset });
                while (it.next()) |bit_i| {
                    if (bit_i >= value.obj.list.items.len) break;
                    const v = &value.obj.list.items[bit_i];
                    if (v.val == .literal) {
                        try ret.rest_kvs.put(v.key, v.val.literal);
                    }
                }
            }

            return ret;
        },
        .@"enum" => |en| {
            return std.meta.stringToEnum(T, value.literal) orelse {
                std.debug.print("Not a value for enum {s}\n", .{value.literal});
                std.debug.print("Possible values:\n", .{});
                inline for (en.fields) |fi| {
                    std.debug.print("    {s}\n", .{fi.name});
                }

                return error.invalidEnumValue;
            };
        },
        .int => return try std.fmt.parseInt(T, value.literal, 0),
        .float => return try std.fmt.parseFloat(T, value.literal),
        .bool => {
            if (std.mem.eql(u8, "true", value.literal))
                return true;
            if (std.mem.eql(u8, "false", value.literal))
                return false;
            return error.invalidBool;
        },
        .pointer => |p| {
            if (p.size != .slice or p.child != u8) @compileError("no ptr");
            if (strings) |strs|
                return try strs.store(value.literal);
            return value.literal;
        },
        else => @compileError("not supported " ++ @typeName(T) ++ " " ++ @tagName(info)),
    }
    return undefined;
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
