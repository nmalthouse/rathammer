const std = @import("std");

pub const Filter = struct {
    name: []const u8,
    invert: bool = false,
    filter: []const u8,
    kind: enum { class, texture, model }, //Match classname, texturename or modelname
    match: enum {
        startsWith,
        endsWith,
        contains,
        equals,
    },
};

fn checkMatch(f: Filter, class: []const u8) bool {
    const res = switch (f.match) {
        .startsWith => std.mem.startsWith(u8, class, f.filter),
        .endsWith => std.mem.endsWith(u8, class, f.filter),
        .contains => std.mem.containsAtLeast(u8, class, 1, f.filter),
        .equals => std.mem.eql(u8, class, f.filter),
    };
    return if (f.invert) !res else res;
}

test {
    const ex = std.testing.expectEqual;

    const f = Filter{
        .name = "test",
        .filter = "prop",
        .kind = .class,
        .match = .startsWith,
    };

    try ex(checkMatch(f, "prop_static"), true);
    try ex(checkMatch(f, "prop"), true);
    try ex(checkMatch(f, "pr"), false);
}

//const World = Filter{ .invert = true, .filter = "", .kind = .class, .match = .equals };
//const Func = Filter{ .invert = false, .filter = "func", .kind = .class, .match = .startsWith };
//const Prop = Filter{ .invert = false, .filter = "prop", .kind = .class, .match = .startsWith };
//const Trigger = Filter{ .invert = false, .filter = "trigger", .kind = .class, .match = .startsWith };
//const Tool = Filter{ .invert = false, .Filter = "materials/tools", .kind = .texture, .match = .startsWith };

pub const VisContext = struct {
    const Self = @This();
    filters: std.ArrayList(Filter),
    enabled: std.ArrayList(bool),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .filters = std.ArrayList(Filter).init(alloc),
            .enabled = std.ArrayList(bool).init(alloc),
        };
    }

    pub fn add(self: *Self, f: Filter) !void {
        const alloc = self.filters.allocator;
        var newf = f;
        newf.name = try alloc.dupe(u8, f.name);
        newf.filter = try alloc.dupe(u8, f.filter);
        try self.filters.append(newf);
        try self.enabled.append(true);
    }

    pub fn deinit(self: *Self) void {
        for (self.filters.items) |f| {
            self.filters.allocator.free(f.filter);
            self.filters.allocator.free(f.name);
        }
        self.filters.deinit();
        self.enabled.deinit();
    }
};
