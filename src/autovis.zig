const std = @import("std");
const vpk = @import("vpk.zig");
const VpkResId = vpk.VpkResId;

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

    _id: u32 = 0, //Set by Context
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

// After editor init, the set of vis are assumed static
// TODO ensure they are static
pub const VisContext = struct {
    const MAX_VIS = 64;
    const MaskSet = std.bit_set.IntegerBitSet(MAX_VIS);
    const Self = @This();

    filters: std.ArrayList(Filter),
    enabled: std.ArrayList(bool),

    vpk_id_cache: std.AutoHashMap(VpkResId, MaskSet),
    //TODO convert entity.class to numeric and this to something better
    class_id_cache: std.StringHashMap(MaskSet),

    _disabled_buf: std.ArrayList(Filter),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .filters = std.ArrayList(Filter).init(alloc),
            .enabled = std.ArrayList(bool).init(alloc),
            ._disabled_buf = std.ArrayList(Filter).init(alloc),
            .vpk_id_cache = std.AutoHashMap(VpkResId, MaskSet).init(alloc),
            .class_id_cache = std.StringHashMap(MaskSet).init(alloc),
        };
    }

    /// Returns a bitmask of filters which match this vpk resource
    /// A id can be tested with a single hashmap lookup and cmp rather than n string comparisons
    pub fn getCachedMask(self: *Self, vpk_id: VpkResId, vpkctx: *vpk.Context) !MaskSet {
        if (self.vpk_id_cache.get(vpk_id)) |mask| return mask;

        const name = vpkctx.getResource(vpk_id) orelse {
            try self.vpk_id_cache.put(vpk_id, MaskSet.initEmpty());
            return MaskSet.initEmpty();
        };

        var mask = MaskSet.initEmpty();
        for (self.filters.items) |filter| {
            switch (filter.kind) {
                .class => {}, // not a vpk res
                .texture, .model => {
                    if (checkMatchInner(filter, name)) {
                        mask.set(filter._id);
                    }
                },
            }
        }
        try self.vpk_id_cache.put(vpk_id, mask);
        return mask;
    }

    pub fn getCachedClassMask(self: *Self, class: []const u8) !MaskSet {
        if (self.class_id_cache.get(class)) |mask| return mask;

        var mask = MaskSet.initEmpty();

        for (self.filters.items) |filter| {
            if (filter.kind != .class) continue;
            if (checkMatchInner(filter, class))
                mask.set(filter._id);
        }

        try self.class_id_cache.put(class, mask);
        return mask;
    }

    pub fn getDisabled(self: *Self) !struct { []const Filter, MaskSet } {
        var mask = MaskSet.initEmpty();
        self._disabled_buf.clearRetainingCapacity();
        for (self.enabled.items, 0..) |en, i| {
            if (!en) {
                mask.set(i);
                try self._disabled_buf.append(self.filters.items[i]);
            }
        }
        return .{ self._disabled_buf.items, mask };
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
        newf._id = @intCast(self.enabled.items.len);
        if (newf._id >= MAX_VIS) return error.tooManyAutoVis;
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
        self.vpk_id_cache.deinit();
        self.class_id_cache.deinit();
        self._disabled_buf.deinit();
        self.filters.deinit();
        self.enabled.deinit();
    }
};

const test_filter = Filter{
    .name = "test",
    .filter = "prop",
    .kind = .class,
    .match = .startsWith,
};
test "inner" {
    const ex = std.testing.expectEqual;

    const f = test_filter;
    try ex(true, checkMatchInner(f, "prop_static"));
    try ex(true, checkMatchInner(f, "prop"));
    try ex(false, checkMatchInner(f, "pr"));

    try ex(true, checkMatch(f, "prop_static", "tex", "model"));
    try ex(false, checkMatch(f, "_prop_dynamic", "tex", "model"));
    try ex(true, checkMatch(f, "prop_dynamic", "tex", "model"));
}

test "context" {
    const alloc = std.testing.allocator;
    var ctx = VisContext.init(alloc);
    defer ctx.deinit();

    try ctx.add(test_filter);
    try ctx.add(.{ .name = "my filter", .filter = "tools", .kind = .texture, .match = .startsWith });
}
