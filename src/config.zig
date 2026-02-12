const std = @import("std");
const vdf = @import("vdf.zig");
const graph = @import("graph");
const StringStorage = @import("string.zig").StringStorage;
const ArrayList = std.ArrayListUnmanaged;

/// The user's 'config.vdf' maps directly into this structure
pub const Config = struct {
    const mask = graph.SDL.keycodes.Keymod.mask;
    enable_version_check: bool = true,
    paths: struct {
        steam_dir: []const u8 = "",
    } = .{},
    autosave: struct {
        enable: bool = true,
        interval_min: u64 = 5,
        max: u32 = 5,
    } = .{},
    dot_size: f32 = 16,
    gui_tint: u32 = 0xffff_ffff,
    mouse_grab_when: enum { key_low, key_high, toggle } = .key_low,
    keys: struct {
        const SC = graph.SDL.NewBind.Scancode;
        const KC = graph.SDL.NewBind.Keycode;
        cam_forward: Keybind = .{ .b = SC(.W, 0) },
        cam_back: Keybind = .{ .b = SC(.S, 0) },
        cam_strafe_l: Keybind = .{ .b = SC(.A, 0) },
        cam_strafe_r: Keybind = .{ .b = SC(.D, 0) },
        cam_down: Keybind = .{ .b = SC(.C, 0) },
        cam_up: Keybind = .{ .b = SC(.SPACE, 0) },
        cam_pan: Keybind = .{ .b = SC(.SPACE, 0) },

        tool_context: Keybind = .{ .b = SC(.G, 0) },

        mouse_capture: Keybind = .{ .b = SC(.LSHIFT, 0) },

        cam_slow: Keybind = .{ .b = SC(.LCTRL, 0) },

        hide_selected: Keybind = .{ .b = SC(.H, 0) },
        unhide_all: Keybind = .{ .b = SC(.H, mask(&.{.CTRL})) },

        quit: Keybind = .{ .b = SC(.ESCAPE, mask(&.{.CTRL})) },
        focus_search: Keybind = .{ .b = KC(.f, mask(&.{.CTRL})) },

        focus_prop_tab: Keybind = .{ .b = SC(.G, 0) },
        focus_tool_tab: Keybind = .{ .b = SC(.T, 0) },

        tool: ArrayList(Keybind) = .{},
        workspace: ArrayList(Keybind) = .{},
        save: Keybind = .{ .b = KC(.s, mask(&.{.CTRL})) },
        save_new: Keybind = .{ .b = KC(.s, mask(&.{ .CTRL, .SHIFT })) },

        marquee_3d: Keybind = .{ .b = SC(._4, 0) },
        select: Keybind = .{ .b = SC(.E, 0) },
        delete_selected: Keybind = .{ .b = SC(.D, 0) },
        toggle_select_mode: Keybind = .{ .b = SC(.TAB, 0) },
        clear_selection: Keybind = .{ .b = SC(.E, mask(&.{.CTRL})) },
        marquee: Keybind = .{ .b = SC(.M, 0) },

        group_selection: Keybind = .{ .b = SC(.T, mask(&.{.CTRL})) },

        build_map: Keybind = .{ .b = SC(.F9, 0) },
        build_map_user: Keybind = .{ .b = SC(.F10, 0) },

        duplicate: Keybind = .{ .b = SC(.Z, 0) },

        down_line: Keybind = .{ .b = SC(.C, 0) }, // j in dvorak
        up_line: Keybind = .{ .b = SC(.V, 0) }, // k in dvorak
        grab_far: Keybind = .{ .b = SC(.Q, 0) },

        grid_inc: Keybind = .{ .b = SC(.R, 0) },
        grid_dec: Keybind = .{ .b = SC(.F, 0) },

        pause: Keybind = .{ .b = SC(.ESCAPE, 0) },

        cube_draw_plane_up: Keybind = .{ .b = SC(.X, 0) },
        cube_draw_plane_down: Keybind = .{ .b = SC(.Z, 0) },
        cube_draw_plane_raycast: Keybind = .{ .b = SC(.Q, 0) },
        texture_eyedrop: Keybind = .{ .b = SC(.Q, 0) },
        texture_wrap: Keybind = .{ .b = SC(.Z, 0) },

        undo: Keybind = .{ .b = KC(.z, 0) },
        redo: Keybind = .{ .b = KC(.s, 0) },

        clip_commit: Keybind = .{ .b = SC(.RETURN, 0) },

        inspector_tab: ArrayList(Keybind) = .{},

        ignore_groups: Keybind = .{ .b = SC(.G, mask(&.{.CTRL})) },
    } = .{},
    window: struct {
        height_px: i32 = 600,
        width_px: i32 = 800,
        cam_fov: f32 = 90,

        sensitivity_3d: f32 = 1,
        sensitivity_2d: f32 = 1,

        display_scale: f32 = -1,
    } = .{},
    default_game: []const u8 = "",
    games: struct {
        map: std.StringHashMapUnmanaged(GameEntry) = .{},
        pub fn parseVdf(p: *vdf.Parsed, v: *const vdf.KV.Value, alloc: std.mem.Allocator, strings_o: ?*StringStorage) !@This() {
            const strings = strings_o orelse return error.needStrings;
            var ret = @This(){};
            if (v.* == .literal)
                return error.notgood;
            for (v.obj.list.items) |entry| {
                const str = p.stringFromId(entry.key) orelse "";
                try ret.map.put(
                    alloc,
                    try strings.store(str),
                    try vdf.fromValue(GameEntry, p, &entry.val, alloc, strings),
                );
            }
            return ret;
        }
    } = .{},
};

const builtin = @import("builtin");
const WINDOZE = builtin.target.os.tag == .windows;
pub const TMP_DIR = if (WINDOZE) "C:/rathammer_tmp" else "/tmp/mapcompile";

pub const GameEntry = struct {
    pub const GameInfo = struct {
        base_dir: []const u8 = "",
        game_dir: []const u8 = "",
        gameinfo_name: []const u8 = "", //Optional

        u_scale: f32 = 0.25,
        v_scale: f32 = 0.25,
    };
    pub const MapBuilder = struct {
        game_dir: []const u8 = "",
        exe_dir: []const u8 = "",
        game_name: []const u8 = "",
        output_dir: []const u8 = "",
        tmp_dir: []const u8 = TMP_DIR,

        user_build_cmd: []const u8 = "",
    };
    gameinfo: ArrayList(GameInfo) = .{},

    fgd_dir: []const u8 = "",
    fgd: []const u8 = "",

    mapbuilder: MapBuilder = .{},

    asset_browser_exclude: struct {
        prefix: []const u8 = "",
        entry: ArrayList([]const u8) = .{},
    } = .{},
};

pub const ConfigCtx = struct {
    config: Config,
    strings: StringStorage,
    alloc: std.mem.Allocator,

    pub fn loadLooseGameConfigs(self: *@This(), dir: std.fs.Dir, dir_name: []const u8) !void {
        var iter = try dir.openDir(dir_name, .{ .iterate = true });
        defer iter.close();
        var walk = try iter.walk(self.alloc);
        defer walk.deinit();

        while (try walk.next()) |item| {
            switch (item.kind) {
                else => {},
                .file => {
                    if (std.mem.endsWith(u8, item.basename, ".vdf")) {
                        const in = try item.dir.openFile(item.basename, .{});
                        defer in.close();
                        var buf: [256]u8 = undefined;
                        var reader = in.reader(&buf);
                        const slice = try reader.interface.allocRemaining(self.alloc, .unlimited);
                        defer self.alloc.free(slice);
                        var val = try vdf.parse(self.alloc, slice, null, .{});
                        defer val.deinit();
                        const name = item.basename[0 .. item.basename.len - ".vdf".len];
                        if (self.config.games.map.contains(name)) {
                            std.debug.print("Config already contains game config for {s} ignoring file\n", .{name});
                        } else {
                            try self.config.games.map.put(
                                self.alloc,
                                try self.strings.store(name),
                                try vdf.fromValue(GameEntry, &val, &.{ .obj = &val.value }, self.alloc, &self.strings),
                            );
                        }
                    } else {}
                },
            }
        }
    }

    pub fn deinit(self: *@This()) void {
        var it = self.config.games.map.valueIterator();
        while (it.next()) |item| {
            item.asset_browser_exclude.entry.deinit(self.alloc);
            item.gameinfo.deinit(self.alloc);
        }
        self.config.games.map.deinit(self.alloc);
        self.config.keys.workspace.deinit(self.alloc);
        self.config.keys.tool.deinit(self.alloc);
        self.config.keys.inspector_tab.deinit(self.alloc);
        self.strings.deinit();
        self.alloc.destroy(self);
    }
};

pub const Keybind = struct {
    b: graph.SDL.NewBind,
    pub fn parseVdf(_: *vdf.Parsed, v: *const vdf.KV.Value, _: std.mem.Allocator, _: anytype) !@This() {
        if (v.* != .literal)
            return error.notgood;

        var buf: [128]u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, v.literal, '+');
        var ret = graph.SDL.NewBind{
            .key = undefined,
            .mod = 0,
        };
        var has_key: bool = false;
        while (it.next()) |token| {
            const key_t = classifyKey(token);
            const key_name = key_t[0];

            if (key_name.len > buf.len)
                return error.keyNameTooLong;
            @memcpy(buf[0..key_name.len], key_name);
            std.mem.replaceScalar(u8, buf[0..key_name.len], '_', ' ');
            _ = std.ascii.lowerString(buf[0..key_name.len], buf[0..key_name.len]);
            const converted_name = buf[0..key_name.len];
            const scancode = graph.SDL.getScancodeFromName(converted_name);

            if (scancode == 0) {
                const backup = backupKeymod(converted_name);
                if (backup != .NONE) {
                    ret.mod |= @intFromEnum(backup);
                    continue;
                }

                std.debug.print("Not a key {s}\n", .{key_name});
                return error.notAKey;
            }

            const Kmod = graph.SDL.keycodes.Keymod;
            const keymod = Kmod.fromScancode(@enumFromInt(scancode));
            ret.key = switch (key_t[1]) {
                .scancode => .{ .scancode = @enumFromInt(scancode) },
                .keycode => .{ .keycode = graph.SDL.getKeyFromScancode(@enumFromInt(scancode)) },
            };

            if (keymod != @intFromEnum(Kmod.NONE)) {
                ret.mod |= keymod;
            }
            has_key = true;
            //const keyc = graph.SDL.getKeyFromScancode(@enumFromInt(scancode));
            //std.debug.print("{s}\n", .{graph.c.SDL_GetKeyName(@intFromEnum(keyc))});
        }
        if (!has_key)
            return error.noKeySpecified;
        return .{ .b = ret };
    }
};

fn classifyKey(token: []const u8) struct { []const u8, enum { scancode, keycode } } {
    if (std.mem.startsWith(u8, token, "scancode:"))
        return .{ token["scancode:".len..], .scancode };
    if (std.mem.startsWith(u8, token, "keycode:"))
        return .{ token["keycode:".len..], .keycode };
    return .{ token, .keycode };
}

/// 'ctrl' is not a key on the keyboard, so sdl returns 0 for getScancodeFromName
/// Most of the time we don't want lctrl we want any ctrl
/// this maps all of the combined modifier keys defined in sdl keymod
fn backupKeymod(name: []const u8) graph.SDL.keycodes.Keymod {
    if (std.mem.eql(u8, name, "ctrl"))
        return .CTRL;
    if (std.mem.eql(u8, name, "shift"))
        return .SHIFT;
    if (std.mem.eql(u8, name, "gui"))
        return .GUI;
    if (std.mem.eql(u8, name, "alt"))
        return .ALT;
    return .NONE;
}

pub fn loadConfigFromFile(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !*ConfigCtx { //Load config
    //
    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;

    var realpath_buf: [256]u8 = undefined;
    if (dir.realpath(path, &realpath_buf)) |rp| {
        try out.print("Loading config file: {s}\n", .{rp});
    } else |_| {
        std.debug.print("Realpath failed when loading config\n", .{});
    }

    const in = try dir.openFile(path, .{});
    defer in.close();
    var buf: [1024]u8 = undefined;
    var reader = in.reader(&buf);
    const slice = try reader.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(slice);
    return try loadConfig(alloc, slice);
}

pub fn loadConfig(alloc: std.mem.Allocator, slice: []const u8) !*ConfigCtx { //Load config
    var val = try vdf.parse(alloc, slice, null, .{});
    defer val.deinit();

    const ctx = try alloc.create(ConfigCtx);

    ctx.* = ConfigCtx{
        .alloc = alloc,
        .strings = try StringStorage.init(alloc),
        .config = undefined,
    };
    //CONF MUST BE copyable IE no alloc
    const conf = try vdf.fromValue(
        Config,
        &val,
        &.{ .obj = &val.value },
        alloc,
        &ctx.strings,
    );
    ctx.config = conf;
    return ctx;
}
