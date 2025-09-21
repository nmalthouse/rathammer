const std = @import("std");
pub const StringStorage = struct {
    const Self = @This();

    set: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    alloc: ?std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .set = std.StringHashMap(void).init(alloc),
            .alloc = null,
        };
    }

    pub fn store(self: *Self, string: []const u8) ![]const u8 {
        if (self.set.getKey(string)) |str| return str;

        if (self.alloc == null)
            self.alloc = self.arena.allocator();

        const str = try self.alloc.?.dupe(u8, string);
        try self.set.put(str, {});
        return str;
    }

    pub fn deinit(self: *Self) void {
        self.set.deinit();
        self.arena.deinit();
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
    var str = StringStorage.init(alloc);
    defer str.deinit();
    const hello = try str.store("hello");
    const hello_jp = try str.store("今日は");

    const hello2 = try str.store("hello");
    try std.testing.expectEqual(hello2, hello);
    const hello_jp2 = try str.store("今日は");
    try std.testing.expectEqual(hello_jp2, hello_jp);
}
