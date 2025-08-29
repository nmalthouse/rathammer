const std = @import("std");
const graph = @import("graph");
const StringStorage = @import("string.zig").StringStorage;
const ArrayList = std.ArrayListUnmanaged;

//TODO Specify a strict version of vdf where:
// space and tab are only valid whitespace
// newline is only valid line seperator.
// key and value must be on the same line. Only one kv pair per line.

const track_visited = false;
pub const Vec3 = graph.za.Vec3_f64;
pub const KV = struct {
    pub const Value = union(enum) { literal: []const u8, obj: *Object };
    key: []const u8,
    val: Value,

    debug_visited: if (track_visited) bool else void = if (track_visited) false else {},
};

pub const Object = struct {
    const Self = @This();
    list: ArrayList(KV) = .{},

    debug_visited: if (track_visited) bool else void = if (track_visited) false else {},

    pub fn init() @This() {
        return .{};
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }

    pub fn append(self: *Self, alloc: std.mem.Allocator, kv: KV) !void {
        try self.list.append(alloc, kv);
    }

    pub fn getFirst(self: *Self, key: []const u8) ?KV.Value {
        for (self.list.items) |item| {
            if (std.mem.eql(u8, key, item.key))
                return item.val;
        }
        return null;
    }

    /// Given a string: first.second.third
    pub fn recursiveGetFirst(self: *Self, keys: []const []const u8) !KV.Value {
        if (keys.len == 0)
            return error.invalid;

        const n = self.getFirst(keys[0]) orelse return error.invalidKey;
        if (keys.len == 1)
            return n;
        if (n != .obj)
            return error.invalid;
        return n.obj.recursiveGetFirst(keys[1..]);
    }
};

pub const KVMap = std.StringHashMap([]const u8);

//pub fn fromValue(comptime T: type, value : *const KV.Value, alloc: std.mem.Allocator)
pub const ValueCtx = struct {
    strings: ?StringStorage,
    alloc: std.mem.Allocator,
};

pub fn getArrayListChild(comptime T: type) ?type {
    const in = @typeInfo(T);
    if (in != .@"struct")
        return null;
    if (@hasDecl(T, "Slice")) {
        const info = @typeInfo(T.Slice);
        if (info == .pointer and info.pointer.size == .slice) {
            const t = std.ArrayList(info.pointer.child);
            if (T == t)
                return info.pointer.child;
        }
    }
    return null;
}

test "is array list" {
    const T = std.ArrayList(u8);
    try std.testing.expect(getArrayListChild(T) == u8);
    try std.testing.expect(getArrayListChild([]u8) == null);
}

const MAX_KVS = 512;
const KVT = std.bit_set.StaticBitSet(MAX_KVS);
threadlocal var from_value_visit_tracker = KVT.initEmpty();
pub fn fromValue(comptime T: type, value: *const KV.Value, alloc: std.mem.Allocator, strings: ?*StringStorage) !T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "parseVdf")) {
                if (track_visited and value.* == .obj)
                    value.obj.debug_visited = true;
                return try T.parseVdf(value, alloc, strings);
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
                if (f.type == KVMap) {} else {
                    const child_info = @typeInfo(f.type);
                    const is_alist = getArrayListChild(f.type);
                    const do_many = (is_alist != null) or (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child != u8);
                    if (!do_many and f.default_value_ptr != null) {
                        @field(ret, f.name) = @as(*const f.type, @alignCast(@ptrCast(f.default_value_ptr.?))).*;
                    }
                    const ar_c = is_alist orelse if (do_many) child_info.pointer.child else void;
                    var vec = std.ArrayList(ar_c).init(alloc);

                    for (value.obj.list.items, 0..) |*item, vi| {
                        if (std.mem.eql(u8, item.key, f.name)) {
                            if (do_many) {
                                if (track_visited)
                                    item.debug_visited = true;

                                const val = fromValue(ar_c, &item.val, alloc, strings) catch blk: {
                                    //std.debug.print("parse FAILED {any}\n", .{item.val});
                                    break :blk null;
                                };
                                if (val) |v| {
                                    try vec.append(v);
                                    if (DO_REST)
                                        from_value_visit_tracker.set(vi);
                                }
                            } else {
                                if (track_visited)
                                    item.debug_visited = true;
                                //A regular struct field
                                @field(ret, f.name) = fromValue(f.type, &item.val, alloc, strings) catch |err| {
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

pub const VdfTokenIterator = struct {
    const Self = @This();

    pub const Token = union(enum) {
        ident: []const u8,
        object_begin: void,
        object_end: void,
    };

    slice: []const u8,
    pos: usize = 0,
    state: enum { none, ident, quoted_ident } = .none,
    line_counter: usize = 0,
    char_counter: usize = 0,

    token_buf: std.ArrayList(u8),

    pub fn init(slice: []const u8, alloc: std.mem.Allocator) Self {
        return .{
            .slice = slice,
            .token_buf = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.token_buf.deinit();
    }

    fn isWhitespace(char: u8) bool {
        return char == ' ' or char == '\t';
    }

    fn isNewline(char: u8) bool {
        return char == '\n' or char == '\r';
    }

    pub fn next(self: *Self) !?Token {
        const eql = std.mem.eql;
        self.token_buf.clearRetainingCapacity();
        if (self.pos >= self.slice.len)
            return null;
        while (self.pos < self.slice.len) {
            const byte = self.slice[self.pos];
            self.pos += 1;

            self.char_counter += 1;
            //while (r.readByte() catch null) |byte| {
            switch (byte) {
                '{', '}' => {
                    if (self.state == .quoted_ident) {
                        try self.token_buf.append(byte);
                    } else {
                        return switch (byte) {
                            '{' => .{ .object_begin = {} },
                            '}' => .{ .object_end = {} },
                            else => unreachable,
                        };
                    }
                }, //recur
                '\"' => { //Begin or end a string
                    switch (self.state) {
                        .ident => return error.fucked,
                        .quoted_ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .none => self.state = .quoted_ident,
                    }
                },
                //escape the next char
                //This is commented out as some vmt's use backslashes as path seperators
                //'\\' => {
                //    switch (self.state) {
                //        .quoted_ident => {},
                //        else => return error.fucked,
                //    }
                //    //Ugly way to do it
                //    if (self.pos + 1 < self.slice.len) {
                //        try self.token_buf.append(self.slice[self.pos]);
                //        self.pos += 1;
                //    }
                //},
                '\r', '\n' => {
                    if (byte == '\n') //Cool
                        self.line_counter += 1;
                    self.char_counter = 0;

                    switch (self.state) {
                        .quoted_ident => {}, //newlines in strings, okay, I guess.
                        //.quoted_ident => {
                        //    std.debug.print("ERR {d}:{d}\n", .{ self.line_counter, self.char_counter });
                        //    return error.fucked;
                        //},
                        .ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .none => {},
                    }
                },
                ' ', '\t' => {
                    switch (self.state) {
                        .ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .quoted_ident => {
                            try self.token_buf.append(byte);
                        },
                        .none => {},
                    }
                },
                else => {
                    if (self.state == .ident or self.state == .none) {
                        if (self.pos < self.slice.len and eql(u8, self.slice[self.pos - 1 .. self.pos + 1], "//")) {
                            //Seek forward, leaving pos at next newline,
                            while (self.pos < self.slice.len and !isNewline(self.slice[self.pos])) : (self.pos += 1) {}
                            if (self.state == .ident) {
                                self.state = .none;
                                return .{ .ident = self.token_buf.items };
                            }
                        } else {
                            self.state = .ident;
                            try self.token_buf.append(byte);
                        }
                    } else {
                        try self.token_buf.append(byte);
                    }
                },
            }
        }
        return switch (self.state) {
            .none => null,
            .quoted_ident => error.missingQuote,
            .ident => return .{ .ident = self.token_buf.items },
        };
    }
};

pub fn parse(alloc: std.mem.Allocator, slice: []const u8) !struct {
    value: Object,
    obj_list: std.ArrayList(*Object),
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *@This()) void {
        for (self.obj_list.items) |item| {
            self.obj_list.allocator.destroy(item);
        }
        self.obj_list.deinit();
        self.arena.deinit();
    }
} {
    var arena = std.heap.ArenaAllocator.init(alloc);
    //defer arena.deinit();
    const aa = arena.allocator();

    var key: []u8 = "";

    var object_stack = std.ArrayList(*Object).init(alloc);
    defer object_stack.deinit();

    var root_object = Object.init();
    var root = &root_object;

    var it = VdfTokenIterator.init(slice, alloc);
    defer it.deinit();
    var token_state: enum { key, value } = .key;
    var object_list = std.ArrayList(*Object).init(alloc);

    errdefer std.debug.print("Error at {d}:{d}\n", .{ it.line_counter, it.char_counter });
    while (try it.next()) |token| {
        switch (token) {
            .object_begin => {
                if (token_state != .value) {
                    std.debug.print("Error at line: {d}:{d}\n", .{ it.line_counter, it.char_counter });
                    return error.invalid;
                }

                const new_root = try alloc.create(Object);
                new_root.* = Object.init();
                try root.append(aa, .{ .key = key, .val = .{ .obj = new_root } });
                try object_stack.append(root);
                try object_list.append(new_root);
                root = new_root;
                token_state = .key;
            },
            .object_end => {
                root = object_stack.pop() orelse return error.invalidVdf;
            },
            .ident => switch (token_state) {
                .key => {
                    key = try aa.dupe(u8, token.ident);
                    _ = std.ascii.lowerString(key, key);
                    token_state = .value;
                },
                .value => {
                    try root.append(aa, .{ .key = key, .val = .{ .literal = try aa.dupe(u8, token.ident) } });
                    token_state = .key;
                },
            },
        }
    }
    return .{ .value = root_object, .arena = arena, .obj_list = object_list };
}

pub fn printObj(obj: Object, ident: usize) void {
    const ident_buf = [_]u8{' '} ** 100;
    const buf = ident_buf[0 .. ident * 4];

    std.debug.print("{s}{{\n", .{buf});
    defer std.debug.print("{s}}}\n", .{buf});
    for (obj.list.items) |item| {
        std.debug.print("{s}{s}: ", .{ buf, item.key });
        switch (item.val) {
            .literal => |k| std.debug.print("{s}\n", .{k}),
            .obj => |o| printObj(o.*, ident + 1),
        }
    }
}

test "parsing config" {
    const alloc = std.testing.allocator;
    const in = try std.fs.cwd().openFile("config.vdf", .{});
    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var val = try parse(alloc, slice);
    defer val.deinit();
    //printObj(val.value, 0);

    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const conf = fromValue(struct {
        keys: struct {
            cam_forward: []const u8,
            cam_back: []const u8,
            cam_strafe_l: []const u8,
            cam_strafe_r: []const u8,
        },
        window: struct {
            height_px: i32,
            width_px: i32,
        },
    }, &.{ .obj = &val.value }, aa.allocator(), null);
    _ = try conf;
    //std.debug.print("{any}\n", .{conf});
}

const TestingTokenizer = struct {
    slice: []const u8,
    tests: []const VdfTokenIterator.Token,
};

test "tokenizer" {
    const OB = VdfTokenIterator.Token{ .object_begin = {} };
    const OE = VdfTokenIterator.Token{ .object_end = {} };
    const alloc = std.testing.allocator;
    const ex = std.testing.expectEqualDeep;

    const test1: []const TestingTokenizer = &.{
        .{
            .slice = "hello world",
            .tests = &.{ .{ .ident = "hello" }, .{ .ident = "world" } },
        },
        .{
            .slice =
            \\hello { here is
            \\}
            \\
            ,
            .tests = &.{ .{ .ident = "hello" }, OB, .{ .ident = "here" }, .{ .ident = "is" }, OE },
        },
    };

    {
        var it = VdfTokenIterator.init(test1[1].slice, alloc);
        defer it.deinit();
        while (try it.next()) |p|
            std.debug.print("{any}\n", .{p});
    }

    for (test1) |tt| {
        var it = VdfTokenIterator.init(tt.slice, alloc);
        defer it.deinit();

        for (tt.tests) |t2| {
            try ex(t2, try it.next());
            //try ex(VdfTokenIterator.Token{ .ident = "world" }, try it.next());
        }
    }
}
