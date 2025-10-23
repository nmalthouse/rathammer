const std = @import("std");
pub const StringStorage = struct {
    const Self = @This();

    set: std.StringArrayHashMap(void),
    arena: *std.heap.ArenaAllocator,
    retained_alloc: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Self {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        //We store this on the heap so we don't have to call arena.allocator on every store()
        arena.* = std.heap.ArenaAllocator.init(alloc);
        return .{
            .arena = arena,
            .set = .init(alloc),
            .retained_alloc = alloc,
            .arena_alloc = arena.allocator(),
        };
    }

    pub fn store(self: *Self, string: []const u8) ![]const u8 {
        if (self.set.getKey(string)) |str| return str;

        const str = try self.arena_alloc.dupe(u8, string);
        try self.set.put(str, {});
        return str;
    }

    pub fn deinit(self: *Self) void {
        self.set.deinit();
        self.arena.deinit();
        self.retained_alloc.destroy(self.arena);
    }
};

/// Acts as a StringStore but doesn't allocate strings
pub const DummyStorage = struct {
    pub fn store(self: *@This(), string: []const u8) ![]const u8 {
        _ = self;
        return string;
    }
};

test {
    const alloc = std.testing.allocator;
    var str = try StringStorage.init(alloc);
    defer str.deinit();
    const hello = try str.store("hello");
    const hello_jp = try str.store("今日は");

    const hello2 = try str.store("hello");
    try std.testing.expectEqual(hello2, hello);
    const hello_jp2 = try str.store("今日は");
    try std.testing.expectEqual(hello_jp2, hello_jp);
}

pub const String = union(enum) {
    const FORCE_ALLOC = true;
    const Self = @This();
    const StaticLen = 30;

    alist: std.ArrayListUnmanaged(u8),

    static: [StaticLen:0]u8,

    pub fn initEmpty() Self {
        return .{ .static = [_:0]u8{0} ** StaticLen };
    }

    pub fn init(alloc: std.mem.Allocator, string: []const u8) !Self {
        if (string.len > StaticLen or FORCE_ALLOC) {
            var ret = std.ArrayListUnmanaged(u8){};
            try ret.appendSlice(alloc, string);
            return .{ .alist = ret };
        }
        var ret: Self = .{ .static = undefined };
        @memcpy(ret.static[0..string.len], string);
        ret.static[string.len] = 0;
        return ret;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .alist => self.alist.deinit(alloc),
            .static => {},
        }
    }

    pub fn clone(self: *Self, alloc: std.mem.Allocator) !Self {
        switch (self.*) {
            .alist => |a| return .{ .alist = try a.clone(alloc) },
            .static => return self.*,
        }
    }

    pub fn slice(self: *const Self) []const u8 {
        switch (self.*) {
            .alist => return self.alist.items,
            .static => return std.mem.sliceTo(&self.static, 0),
        }
    }

    pub fn set(self: *Self, alloc: std.mem.Allocator, string: []const u8) !void {
        self.deinit(alloc);
        self.* = try init(alloc, string);
    }
};

test " HELLO " {
    const alloc = std.testing.allocator;
    std.debug.print("{d}\n", .{@sizeOf(String)});

    var a = try String.init(alloc, "hello");
    defer a.deinit(alloc);

    std.debug.print("{any}\n", .{a.slice()});
}
