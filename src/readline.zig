const std = @import("std");
const Self = @This();

hist_arena: std.heap.ArenaAllocator,
alloc: std.mem.Allocator,
history: std.ArrayList([]const u8),

/// user adds candidates to this list through addComplete
/// strings stored in hist_arena
complete_list: std.ArrayList([]const u8) = .{},

/// Mirrors what is in the textbox
current_line: std.ArrayList(u8) = .{},

/// Last string we sent to user
auto_line: std.ArrayList(u8) = .{},

hist_location: usize = 0,
complete_index: usize = 0,
state: enum {
    init,
    complete,
},

pub fn init(alloc: std.mem.Allocator) Self {
    return Self{
        .alloc = alloc,
        .history = .{},
        .hist_arena = .init(alloc),
        .state = .init,
    };
}

pub fn deinit(self: *Self) void {
    self.hist_arena.deinit();
    self.history.deinit(self.alloc);
    self.current_line.deinit(self.alloc);
    self.auto_line.deinit(self.alloc);
    self.complete_list.deinit(self.alloc);
}

pub fn reset(self: *Self) void {
    self.hist_location = self.history.items.len;
    self.state = .init;
}

pub fn addComplete(self: *Self, item: []const u8) !void {
    try self.complete_list.append(
        self.alloc,
        try self.hist_arena.allocator().dupe(u8, item),
    );
}

pub fn appendHistory(self: *Self, item: []const u8) !void {
    try self.history.append(
        self.alloc,
        try self.hist_arena.allocator().dupe(u8, item),
    );
    self.reset();
}

pub fn prev(self: *Self) ?[]const u8 {
    if (self.hist_location > 0) {
        self.hist_location -= 1;

        const line = self.history.items[self.hist_location];
        self.setAutoLine(line) catch return null;
        return line;
    }
    return null;
}

pub fn next(self: *Self) ?[]const u8 {
    if (self.hist_location < self.history.items.len) {
        self.hist_location += 1;

        if (self.hist_location >= self.history.items.len) {
            self.setAutoLine("") catch return null;
            return "";
        }

        const line = self.history.items[self.hist_location];
        self.setAutoLine(line) catch return null;
        return line;
    }
    return "";
}

fn setAutoLine(self: *Self, line: []const u8) !void {
    self.auto_line.clearRetainingCapacity();
    try self.auto_line.appendSlice(self.alloc, line);
}

pub fn setLine(self: *Self, line: []const u8) !void {
    if (!std.mem.eql(u8, line, self.auto_line.items)) {
        self.current_line.clearRetainingCapacity();
        try self.current_line.appendSlice(self.alloc, line);
    }
}

pub fn complete(self: *Self) []const u8 {
    if (self.complete_list.items.len == 0) return "";
    switch (self.state) {
        .init => {
            self.complete_index = self.complete_list.items.len - 1;
            self.state = .complete;
        },
        .complete => {},
    }

    var counter: usize = 0;
    while (counter < self.complete_list.items.len) : (counter += 1) {
        self.complete_index = (self.complete_index + 1) % self.complete_list.items.len;
        const item = self.complete_list.items[self.complete_index];
        if (std.mem.startsWith(u8, item, self.current_line.items)) {
            break;
        }
    }

    const line = if (counter == self.complete_list.items.len) "" else self.complete_list.items[self.complete_index];

    self.setAutoLine(line) catch {};
    return line;
}
