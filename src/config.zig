const std = @import("std");
const vdf = @import("vdf.zig");
const graph = @import("graph");
const StringStorage = @import("string.zig").StringStorage;
const ArrayList = std.ArrayListUnmanaged;

/// The user's 'config.zig' maps directly into this structure
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
    keys: Keys = .{},
    window: struct {
        height_px: i32 = 600,
        width_px: i32 = 800,
        cam_fov: f32 = 90,

        sensitivity_3d: f32 = 1,
        sensitivity_2d: f32 = 1,

        display_scale: f32 = -1,
    } = .{},
    default_game: []const u8 = "basic_hl2",
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
    gameinfo: []const GameInfo = &.{},

    fgd_dir: []const u8 = "",
    fgd: []const u8 = "",

    mapbuilder: MapBuilder = .{},

    asset_browser_exclude: struct {
        prefix: []const u8 = "",
        entry: []const []const u8 = &.{},
    } = .{},
};

pub const ConfigCtx = struct {
    config: Config,
    strings: StringStorage,
    alloc: std.mem.Allocator,
    games: std.StringHashMapUnmanaged(GameEntry) = .{},
    binds: genBindingIdStruct(Keys) = undefined,

    pub fn loadLooseGameConfigs(self: *@This(), dir: std.fs.Dir, dir_name: []const u8) !void {
        var iter = try dir.openDir(dir_name, .{ .iterate = true });
        defer iter.close();
        var walk = try iter.walk(self.alloc);
        defer walk.deinit();

        while (try walk.next()) |item| {
            switch (item.kind) {
                else => {},
                .file => {
                    const extension = ".json";
                    if (std.mem.endsWith(u8, item.basename, extension)) {
                        const in = try item.dir.openFile(item.basename, .{});
                        defer in.close();
                        var buf: [256]u8 = undefined;
                        var reader = in.reader(&buf);
                        const slice = try reader.interface.allocRemaining(self.alloc, .unlimited);
                        defer self.alloc.free(slice);
                        const val = try std.json.parseFromSlice(GameEntry, self.alloc, slice, .{ .allocate = .alloc_always });
                        defer val.deinit();
                        const name = item.basename[0 .. item.basename.len - extension.len];
                        if (self.games.contains(name)) {
                            std.debug.print("Config already contains game config for {s} ignoring file\n", .{name});
                        } else {
                            try self.games.put(
                                self.alloc,
                                try self.strings.store(name),
                                try dupeStruct(val.value, self.strings.arena_alloc, &self.strings),
                                //try vdf.fromValue(GameEntry, &val, &.{ .obj = &val.value }, self.alloc, &self.strings),
                            );
                        }
                    } else {}
                },
            }
        }
    }

    pub fn deinit(self: *@This()) void {
        var it = self.games.valueIterator();
        while (it.next()) |item| {
            _ = item;
            //item.asset_browser_exclude.entry.deinit(self.alloc);
            //item.gameinfo.deinit(self.alloc);
        }
        self.games.deinit(self.alloc);
        //self.config.keys.workspace.deinit(self.alloc);
        //self.config.keys.tool.deinit(self.alloc);
        //self.config.keys.inspector_tab.deinit(self.alloc);
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
    const ctx = try alloc.create(ConfigCtx);

    ctx.* = ConfigCtx{
        .alloc = alloc,
        .strings = try StringStorage.init(alloc),
        .config = .{},
    };
    const parsed = try std.json.parseFromSlice(Config, ctx.alloc, slice, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    ctx.config = try dupeStruct(parsed.value, ctx.strings.arena_alloc, &ctx.strings);
    return ctx;
}

const SerialBinding = struct {
    mode: graph.SDL.keybinding.FocusMode = .multi,
    button: graph.SDL.keybinding.ButtonBind,
    repeat: bool = false,
    mod: []const graph.SDL.keybinding.Keymod = &.{},

    pub fn Keycode(k: graph.SDL.keycodes.Keycode) @This() {
        return .{ .button = .{ .keycode = k } };
    }

    pub fn Scancode(k: graph.SDL.keycodes.Scancode) @This() {
        return .{ .button = .{ .scancode = k } };
    }

    pub fn name(self: @This()) []const u8 {
        return switch (self.button) {
            inline else => |k| @tagName(k),
        };
    }

    pub fn nameFull(self: @This(), buf: []u8) []const u8 {
        //const mod_name = graph.keycodes.Keymod.name(self.mod, buf);
        //if (mod_name.len >= buf.len) return mod_name;
        const mod_name = "";
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = buf, .pos = mod_name.len };

        fbs.writer().print("{s}", .{self.name()}) catch {};

        return buf[0..fbs.pos];
    }
};

pub const Keys = struct {
    const mask = graph.SDL.keybinding.Keymod.mask;
    const Bind = SerialBinding;
    const SC = SerialBinding.Scancode;
    const KC = SerialBinding.Keycode;
    global: struct {
        focus_search: Bind = .{ .button = .{ .keycode = .f }, .mod = &.{.ctrl} },

        workspace_0: Bind = .{ .button = .{ .scancode = ._1 }, .mod = &.{.alt}, .mode = .exclusive },
        workspace_texture: Bind = .{ .button = .{ .scancode = .T }, .mod = &.{.alt}, .mode = .exclusive },
        workspace_model: Bind = .{ .button = .{ .scancode = .M }, .mod = &.{.alt}, .mode = .exclusive },
        workspace_1: Bind = .{ .button = .{ .scancode = ._2 }, .mod = &.{.alt}, .mode = .exclusive },

        save: Bind = .{ .button = .{ .keycode = .s }, .mod = &.{.ctrl}, .mode = .exclusive },
        save_new: Bind = .{ .button = .{ .keycode = .s }, .mod = &.{ .ctrl, .shift }, .mode = .exclusive },
        build_map: Bind = .{ .button = .{ .keycode = .F9 }, .mode = .exclusive },
        build_map_user: Bind = .{ .button = .{ .keycode = .F10 }, .mode = .exclusive },

        down_line: Bind = .{ .button = .{ .scancode = .C }, .repeat = true }, // j in dvorak
        up_line: Bind = .{ .button = .{ .scancode = .V }, .repeat = true }, // k in dvorak
        pause: Bind = SC(.ESCAPE),

        inspector_tab_0: Bind = SC(.F1),
        inspector_tab_1: Bind = SC(.F2),
        inspector_tab_2: Bind = SC(.F3),
        inspector_tab_3: Bind = SC(.F4),

        undo: Bind = .{ .button = .{ .scancode = .Z }, .mod = &.{.ctrl}, .mode = .exclusive, .repeat = true },
        redo: Bind = .{ .button = .{ .scancode = .Z }, .mod = &.{ .ctrl, .shift }, .mode = .exclusive, .repeat = true },

        quit: Bind = .{ .button = .{ .scancode = .ESCAPE }, .mod = &.{.ctrl} },
    } = .{},

    tool: struct {
        translate: Bind = .{ .button = .{ .scancode = ._1 }, .mode = .exclusive },
        translate_face: Bind = .{ .button = .{ .scancode = ._2 }, .mode = .exclusive },
        place_entity: Bind = .{ .button = .{ .scancode = .G }, .mod = &.{.shift}, .mode = .exclusive },
        cube_draw: Bind = .{ .button = .{ .scancode = .B }, .mod = &.{.shift}, .mode = .exclusive },
        fast_face: Bind = .{ .button = .{ .scancode = ._3 }, .mode = .exclusive },
        texture: Bind = .{ .button = .{ .scancode = .T }, .mod = &.{.shift}, .mode = .exclusive },
        vertex: Bind = .{ .button = .{ .scancode = .V }, .mod = &.{.shift}, .mode = .exclusive },
        clip: Bind = .{ .button = .{ .scancode = .X }, .mod = &.{.shift}, .mode = .exclusive },
    } = .{},

    view3d: struct { //Context
        cam_forward: Bind = SC(.W),
        cam_back: Bind = SC(.S),
        cam_strafe_l: Bind = SC(.A),
        cam_strafe_r: Bind = SC(.D),
        cam_down: Bind = SC(.C),
        cam_up: Bind = SC(.SPACE),
        duplicate: Bind = SC(.Z),
        tool_context: Bind = SC(.G),
        //mouse_capture: Bind = SC(.LSHIFT),
        mouse_capture: Bind = .{ .button = .{ .mouse = .middle } },

        cam_slow: Bind = SC(.LCTRL),

        hide_selected: Bind = SC(.H),
        unhide_all: Bind = .{ .button = .{ .scancode = .H }, .mod = &.{.ctrl} },

        focus_prop_tab: Bind = SC(.G),
        focus_tool_tab: Bind = SC(.T),

        marquee_3d: Bind = SC(._4),
        select: Bind = .{ .button = .{ .scancode = .E }, .mode = .exclusive },
        delete_selected: Bind = .{ .button = .{ .scancode = .X }, .mod = &.{.ctrl}, .mode = .exclusive },
        toggle_select_mode: Bind = SC(.TAB),
        clear_selection: Bind = .{ .button = .{ .scancode = .E }, .mod = &.{.ctrl}, .mode = .exclusive },
        marquee: Bind = SC(.M),

        group_selection: Bind = .{ .button = .{ .scancode = .T }, .mod = &.{.ctrl}, .mode = .exclusive },

        grid_inc: Bind = .{ .button = .{ .scancode = .R }, .mode = .multi, .repeat = true },
        grid_dec: Bind = .{ .button = .{ .scancode = .F }, .mode = .multi, .repeat = true },

        ignore_groups: Bind = .{ .button = .{ .scancode = .G }, .mod = &.{.ctrl} },
    } = .{},

    vertex: struct {
        do_marquee: Bind = SC(.LSHIFT),
    } = .{},

    cube_draw: struct {
        plane_up: Bind = SC(.X),
        plane_down: Bind = SC(.Z),
        plane_raycast: Bind = SC(.Q),
    } = .{},

    clipping: struct {
        commit: Bind = SC(.RETURN),
    } = .{},

    texture: struct {
        eyedrop: Bind = SC(.Q),
        wrap: Bind = SC(.Z),
    } = .{},
};

pub fn registerBindIds(comptime BindingSerialT: type, bindreg: *graph.SDL.keybinding.BindRegistry, serial: BindingSerialT) !genBindingIdStruct(BindingSerialT) {
    const BindingIdStruct = genBindingIdStruct(BindingSerialT);
    var ret: BindingIdStruct = undefined;
    const info = @typeInfo(BindingIdStruct).@"struct";
    inline for (info.fields) |field| {
        const ctx_info = @typeInfo(field.type).@"struct";
        const ctx_id = try bindreg.newContext(field.name);
        @field(ret, field.name).context_id = ctx_id;

        inline for (ctx_info.fields[0 .. ctx_info.fields.len - 1]) |bf| {
            const bind = @field(@field(serial, field.name), bf.name);

            const bind_id = try bindreg.registerBind(.bind(bind.button, bind.mode, bind.mod, bind.repeat, ctx_id), bf.name);

            @field(@field(ret, field.name), bf.name) = bind_id;
        }
    }
    return ret;
}

pub const BindIds = genBindingIdStruct(Keys);
fn genBindingIdStruct(comptime config_mapping: type) type {
    const info = @typeInfo(config_mapping).@"struct";
    var main_out: [info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (info.fields, 0..) |field, f_i| {
        const binf = @typeInfo(field.type).@"struct";
        var bind_fields: [binf.fields.len + 1]std.builtin.Type.StructField = undefined;
        const default: graph.SDL.keybinding.BindId = .none;
        inline for (binf.fields, 0..) |bind, b_i| {
            bind_fields[b_i] = .{
                .name = bind.name,
                .type = graph.SDL.keybinding.BindId,
                .default_value_ptr = &default,
                .is_comptime = false,
                .alignment = @alignOf(graph.SDL.keybinding.BindId),
            };
        }
        bind_fields[binf.fields.len] = .{
            .name = "context_id",
            .type = graph.SDL.keybinding.ContextId,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(graph.SDL.keybinding.ContextId),
        };

        const T = @Type(.{ .@"struct" = .{
            .fields = &bind_fields,
            .layout = .auto,
            .decls = &.{},
            .is_tuple = false,
        } });
        main_out[f_i] = .{
            .name = field.name,
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    return @Type(.{
        .@"struct" = .{
            .fields = &main_out,
            .layout = .auto,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn dupeStruct(input: anytype, alloc: std.mem.Allocator, str: *StringStorage) !@TypeOf(input) {
    const T = @TypeOf(input);
    const info = @typeInfo(T);
    switch (T) {
        graph.SDL.keybinding.ButtonBind => return input,
        []const u8 => return try str.store(input),
        else => switch (info) {
            .float,
            .int,
            .bool,
            .@"enum",
            => return input,
            .@"struct" => |s| {
                var ret: T = undefined;
                inline for (s.fields) |field|
                    @field(ret, field.name) = try dupeStruct(@field(input, field.name), alloc, str);
                return ret;
            },
            .pointer => |p| {
                if (p.size == .slice) {
                    const new = try alloc.alloc(p.child, input.len);
                    for (input, 0..) |item, i| {
                        new[i] = try dupeStruct(item, alloc, str);
                    }
                    return new;
                }
            },
            else => {},
        },
    }
    @compileError("borken for " ++ @typeName(T));
}
