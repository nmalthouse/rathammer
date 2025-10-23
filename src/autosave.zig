const std = @import("std");

//map_name_autosave_01.json
const MAX_COUNT = 64;
const log = std.log.scoped(.autosave);
pub const Autosaver = struct {
    const Self = @This();
    interval_ms: u64,
    enabled: bool = true,
    timer: std.time.Timer,
    max_count: u32,
    alloc: std.mem.Allocator,
    force: bool = false,

    pub fn init(
        interval_ms: u64,
        max_count: u32,
        enable: bool,
        alloc: std.mem.Allocator,
    ) !Self {
        if (max_count > MAX_COUNT)
            return error.maxAutoSaves;
        return .{
            .alloc = alloc,
            .interval_ms = interval_ms,
            .enabled = enable,
            .timer = try std.time.Timer.start(),
            .max_count = max_count,
        };
    }

    pub fn resetTimer(self: *Self) void {
        self.timer.reset();
    }

    pub fn shouldSave(self: *Self) bool {
        if (!self.enabled) return false;
        if (self.force) {
            self.force = false;
            return true;
        }
        const time_ms: u64 = self.timer.read() / std.time.ns_per_ms;
        return (time_ms > self.interval_ms);
    }

    pub fn prune(self: *Self, dir: std.fs.Dir, base_name: []const u8, extension: []const u8) !void {
        const d = try dir.openDir(".", .{ .iterate = true });
        var oldest = std.ArrayList(i64){};
        var strbuf = std.ArrayList(u8){};
        defer oldest.deinit(self.alloc);
        defer strbuf.deinit(self.alloc);

        var it = d.iterate();
        while (try it.next()) |entry| {
            const index = getSaveTimestamp(entry.name, base_name, extension) orelse continue;

            try oldest.append(self.alloc, index);
        }
        const Ctx = struct {
            pub fn lessThan(_: void, a: i64, b: i64) bool {
                return a < b;
            }
        };
        if (oldest.items.len > self.max_count) {
            std.sort.insertion(i64, oldest.items, {}, Ctx.lessThan);
            for (oldest.items[0 .. oldest.items.len - self.max_count]) |ts| {
                const fname = try getSaveName(base_name, extension, ts, &strbuf, self.alloc);
                log.info("Pruning {s}", .{fname});
                //log.err("dummy deleting {s}", .{fname});
                d.deleteFile(fname) catch |err| {
                    log.err("Failed to prune autosave {s} with error {}", .{ fname, err });
                };
            }
        }
    }

    pub fn getSaveFileAndPrune(self: *Self, dir: std.fs.Dir, base_name: []const u8, extension: []const u8) !std.fs.File {
        var namebuf = std.ArrayList(u8){};
        defer namebuf.deinit(self.alloc);
        var bname = try encodeBasename(base_name, &namebuf, self.alloc);
        if (bname.len > 200) //rough, but should stop windows from exploding
            bname = bname[bname.len - 200 ..];

        try self.prune(dir, bname, extension);
        var strbuf = std.ArrayList(u8){};
        defer strbuf.deinit(self.alloc);
        const name = try getSaveName(bname, extension, std.time.timestamp(), &strbuf, self.alloc);
        const sf = try dir.createFile(name, .{});
        return sf;
    }
};

/// Autosave files have format "basename_autosave_unixtimestamp"
const AUTOSAVE_STRING = "_autosave_";
fn getSaveTimestamp(entry_name: []const u8, basename: []const u8, extension: []const u8) ?i64 {
    if (std.mem.startsWith(u8, entry_name, basename)) {
        const suffix = entry_name[basename.len..];
        if (std.mem.startsWith(u8, suffix, AUTOSAVE_STRING) and std.mem.endsWith(u8, suffix, extension)) {
            if (suffix.len <= AUTOSAVE_STRING.len + extension.len) //incase of weird files
                return null;
            const save_index = suffix[AUTOSAVE_STRING.len .. suffix.len - extension.len];
            return std.fmt.parseInt(i64, save_index, 10) catch null;
        }
    }
    return null;
}

fn encodeBasename(name: []const u8, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) ![]const u8 {
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc, name);
    for (buf.items) |*char| {
        char.* = switch (char.*) {
            '\\' => '_',
            '/' => '_',
            else => continue,
        };
    }
    return buf.items;
}

fn getSaveName(basename: []const u8, extension: []const u8, timestamp: i64, out: *std.ArrayList(u8), alloc: std.mem.Allocator) ![]const u8 {
    out.clearRetainingCapacity();
    try out.print(alloc, "{s}{s}{d}{s}", .{ basename, AUTOSAVE_STRING, timestamp, extension });
    return out.items;
}

test {
    std.debug.print("\n\n", .{});
    try std.testing.expect(getSaveTimestamp("crass_autosave_01.json", "crass", ".json") == 1);
    try std.testing.expect(getSaveTimestamp("crass.json", "crass", ".json") == null);
    try std.testing.expect(getSaveTimestamp("crass_autosave_0091.json", "crass", ".json") == 91);
}
