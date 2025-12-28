const std = @import("std");

/// Colored Strings can be submitted to NotifyCtx
/// These strings are then drawn, in order, for some duration before disapearing
pub const NotifyCtx = struct {
    const Self = @This();
    const Item = struct {
        msg: []const u8, //Allocated
        color: u32,
        time_left_ms: f32,
    };

    strbuf: std.ArrayList(u8) = .{},
    alloc: std.mem.Allocator,

    items: std.ArrayList(Item) = .{},
    time: f32,

    pub fn init(alloc: std.mem.Allocator, time_ms: f32) Self {
        return .{
            .alloc = alloc,
            .time = time_ms,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.items.items) |*item| {
            self.alloc.free(item.msg);
        }
        self.items.deinit(self.alloc);
        self.strbuf.deinit(self.alloc);
    }

    /// returned string is only valid until next call to getSlice
    pub fn submitNotify(self: *Self, comptime msg: []const u8, args: anytype, color: u32) ![]const u8 {
        self.strbuf.clearRetainingCapacity();
        try self.strbuf.print(self.alloc, msg, args);
        const str = try self.alloc.dupe(u8, self.strbuf.items);

        try self.items.append(self.alloc, .{
            .msg = str,
            .color = color,
            .time_left_ms = self.time,
        });
        return str;
    }

    /// The returned slice becomes invalid if submitNotify or getSlice is called.
    pub fn getSlice(self: *Self, dt_ms: f32) ![]const Item {
        if (dt_ms > 0) {
            var remove_index: ?usize = null;
            for (self.items.items, 0..) |*item, i| {
                item.time_left_ms -= dt_ms;
                if (item.time_left_ms < 0) {
                    remove_index = i;
                    self.alloc.free(item.msg);
                }
            }
            if (remove_index) |mi| {
                try self.items.replaceRange(self.alloc, 0, mi + 1, &.{});
            }
        }
        return self.items.items;
    }
};
