const std = @import("std");

// Laying out how this should work.
//
// List of user specified filters that match some subset of the entities
//
// For a given entity to be shown in the world all matching filters must be set true

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

fn checkMatchInner(f: Filter, class: []const u8) bool {
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

    try ex(checkMatchInner(f, "prop_static"), true);
    try ex(checkMatchInner(f, "prop"), true);
    try ex(checkMatchInner(f, "pr"), false);
}

pub fn checkMatch(f: Filter, ent_class: ?[]const u8, texture: ?[]const u8, model: ?[]const u8) bool {
    const string: ?[]const u8 = switch (f.kind) {
        .class => ent_class,
        .texture => texture,
        .model => model,
    };
    if (string) |str| {
        return checkMatchInner(f, str);
    } else {
        return f.invert;
    }
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

    _disabled_buf: std.ArrayList(Filter),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .filters = std.ArrayList(Filter).init(alloc),
            .enabled = std.ArrayList(bool).init(alloc),
            ._disabled_buf = std.ArrayList(Filter).init(alloc),
        };
    }

    pub fn getDisabled(self: *Self) ![]const Filter {
        self._disabled_buf.clearRetainingCapacity();
        for (self.enabled.items, 0..) |en, i| {
            if (!en) {
                try self._disabled_buf.append(self.filters.items[i]);
            }
        }
        return self._disabled_buf.items;
    }

    pub fn getPtr(self: *Self, name: []const u8) ?*bool {
        for (self.filters.items, 0..) |f, i| {
            if (std.mem.eql(u8, name, f.name))
                return &self.enabled.items[i];
        }
        return null;
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
        self._disabled_buf.deinit();
        self.filters.deinit();
        self.enabled.deinit();
    }
};
