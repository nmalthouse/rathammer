test "usage" {
    var prof = BasicProfiler.init();

    prof.start();
    //Do stuff
    prof.end();

    //Other stuff

    prof.start();
    //do more stuff

    prof.end();

    prof.log("did stuff"); // -> did stuff took: x ms
}

const std = @import("std");

const config = @import("config");

pub const BasicProfiler = if (config.time_profile) Profile_active else ProfileDummy;
const logger = std.log.scoped(.profile);

const ProfileDummy = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn start(_: @This()) void {}
    pub fn end(_: @This()) void {}

    pub fn log(_: @This(), _: []const u8) void {}
};

const Profile_active = struct {
    time: u64 = 0,
    timer: std.time.Timer,

    pub fn init() @This() {
        return .{
            .time = 0,
            .timer = undefined,
        };
    }

    pub fn start(self: *@This()) void {
        self.timer = std.time.Timer.start() catch return;
    }

    pub fn end(self: *@This()) void {
        self.time += self.timer.read();
    }

    pub fn log(self: *@This(), name: []const u8) void {
        logger.info("{s} took: {d} ms", .{ name, self.time / std.time.ns_per_ms });
    }
};
