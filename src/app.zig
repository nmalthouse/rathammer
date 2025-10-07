const std = @import("std");
const graph = @import("graph");
const Arg = graph.ArgGen.Arg;
pub const Args = [_]graph.ArgGen.ArgItem{
    Arg("map", .string, "vmf or json to load"),
    Arg("blank", .string, "create blank map named"),
    Arg("basedir", .string, "base directory of the game, \"Half-Life 2\""),
    Arg("gamedir", .string, "directory of gameinfo.txt, \"Half-Life 2/hl2\""),
    Arg("fgddir", .string, "directory of fgd file"),
    Arg("fgd", .string, "name of fgd file"),
    Arg("nthread", .number, "How many threads."),
    Arg("gui_scale", .number, "Scale the gui"),
    Arg("gui_font_size", .number, "pixel size of font"),
    Arg("gui_item_height", .number, "item height in pixels / gui_scale"),
    Arg("custom_cwd", .string, "override the directory used for game"),
    Arg("fontfile", .string, "load custom font"),
    Arg("display_scale", .number, "override detected display scale, should be ~ 0.2-3"),
    Arg("config", .string, "load custom config, relative to cwd"),
    Arg("version", .flag, "Print rathammer version and exit"),
    Arg("build", .flag, "Print rathammer build info as json and exit"),
    Arg("no_version_check", .flag, "Don't check for newer version over http"),
    Arg("game", .string, "Name of a game defined in config.vdf"),
    Arg("games", .flag, "List available games from config.vdf"),
};

const EventKindT = u16;
pub const EventKind = enum(EventKindT) {
    undo,
    redo,
    tool_changed,
    saved,
    //select,
};

pub const Event = union(EventKind) {
    undo: void,
    redo: void,
    //select: void,
    tool_changed: void,
    saved: void,
};

pub const EventCb = fn (user: *iEvent, ev: Event) void;
pub const iEvent = struct {
    cb: *const EventCb,
};

pub const EventCtx = struct {
    const ArrayList = std.ArrayListUnmanaged;
    var SdlEventId: u32 = 0;
    const Self = @This();

    alloc: std.mem.Allocator,
    listeners: ArrayList(*iEvent) = .{},

    subscribers: ArrayList(ArrayList(usize)) = .{},

    pub fn allocateSdlEvent() void {
        SdlEventId = graph.c.SDL_RegisterEvents(1);
    }

    pub fn create(alloc: std.mem.Allocator) !*Self {
        const ret = try alloc.create(Self);
        ret.* = .{
            .alloc = alloc,
        };
        return ret;
    }

    pub fn destroy(self: *Self) void {
        self.listeners.deinit(self.alloc);
        for (self.subscribers.items) |*sub|
            sub.deinit(self.alloc);
        self.subscribers.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn registerListener(self: *Self, l: *iEvent) !usize {
        const id = self.listeners.items.len;
        try self.listeners.append(self.alloc, l);
        return id;
    }

    pub fn subscribe(self: *Self, listener: usize, event_id: EventKindT) !void {
        if (listener >= self.listeners.items.len) return error.invalidListener;

        const len: EventKindT = @intCast(self.subscribers.items.len);
        if (event_id >= len) {
            try self.subscribers.appendNTimes(self.alloc, .{}, event_id - len + 1);
        }

        try self.subscribers.items[@intCast(event_id)].append(self.alloc, listener);
    }

    ///Thread safe
    pub fn pushEvent(self: *Self, event: Event) void {
        const ev = self.alloc.create(Event) catch {
            std.debug.print("Failed to alloc event!\n", .{});
            return;
        };
        ev.* = event;
        graph.SDL.pushEvent(SdlEventId, 0, @ptrCast(self), @ptrCast(ev)) catch {
            std.debug.print("Error creating sdl event\n", .{});
        };
    }

    pub fn graph_event_cb(ev: graph.c.SDL_UserEvent) void {
        if (ev.type == SdlEventId) {
            const self: *Self = @alignCast(@ptrCast(ev.data1 orelse return));
            if (ev.data2) |us1| {
                const event: *Event = @alignCast(@ptrCast(us1));
                const id = @intFromEnum(event.*);
                if (id < self.subscribers.items.len) {
                    for (self.subscribers.items[id].items) |sub| {
                        const l = self.listeners.items[sub];
                        l.cb(l, event.*);
                    }
                }
                self.alloc.destroy(event);
            }
        } else {
            std.debug.print("unknown sdl event {d}\n", .{ev.type});
        }
    }
};

test "sample_event" {
    //This test doesn't work because we haven't initilized sdl
    //but it demos how the interface works
    if (true)
        return;
    const alloc = std.testing.allocator;

    var eventctx = try EventCtx.create(alloc);
    defer eventctx.destroy();

    const Tlisten = struct {
        ev_vt: iEvent = .{ .cb = ev_cb },

        pub fn ev_cb(ev_vt: *iEvent, ev: Event) void {
            const self: *@This() = @alignCast(@fieldParentPtr("ev_vt", ev_vt));
            _ = self;
            switch (ev) {
                .undo => {
                    std.debug.print("got undo event\n", .{});
                },
                else => {},
            }
        }
    };

    var tlist: Tlisten = .{};

    const list1 = try eventctx.registerListener(&tlist.ev_vt);
    try eventctx.subscribe(list1, @intFromEnum(EventKind.undo));

    eventctx.pushEvent(.{ .undo = {} });
}
