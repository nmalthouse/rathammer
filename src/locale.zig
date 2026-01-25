const std = @import("std");
const Str = []const u8;

pub var lang: *const Strings = &en_us;

pub const en_us = Strings{};
pub const Strings = struct {
    inspector: struct {
        io: struct {
            output: Str = "My output named",
            target: Str = "Target entites named",
            input: Str = "Via this input",
            param: Str = "With a parameter of",
            delay: Str = "After a delay in seconds of",
            fire_count: Str = "Limit to this many fires",
        } = .{},
    } = .{},

    units: struct {
        hu: Str = "hu",
        sec: Str = "seconds",
        ms: Str = "ms",
        fires: Str = "fires",
    } = .{},

    undo: struct {
        deletion: Str = "deletion",
        clear_selection: Str = "clear selection",
        group_objects: Str = "group objects",
        create_primitive: Str = "create primitive",
        delete_layer: Str = "delete layer",
        create_layer: Str = "create layer",
        dupe_layer: Str = "duplicate layer",

        merge_layer: Str = "merge layer",
        move_layer: Str = "move layer",

        translate_face: Str = "translate face",

        create_ent: Str = "create entity",

        clip: Str = "clip solid",

        dupe_ents: Str = "duplicate entities",
        transform_ents: Str = "transform entities",

        texture_manip: Str = "manipulate texture",
        texture_apply: Str = "texture apply",
    } = .{},

    saving: Str = "saving",
    saved: Str = "saved",
    autosaved: Str = "autosaved",

    notify: struct {
        exported_vmf: Str = "Exported map to vmf",
        exported_vmf_fail: Str = "Failed exporting map to vmf",
    } = .{},

    draw_mode: enumStrings(edit.DrawMode) = .{
        .shaded = "shaded",
        .lightmap_scale = "lightmap scale",
    },

    btn: struct {
        load: Str = "load",
        open_help: Str = "Open help",
        open_home: Str = "Open homepage",
        save: Str = "save",
        save_as: Str = "save-as",
        build: Str = "build",
        build_user: Str = "build-user",
        export_obj: Str = "export-obj",
        export_obj_as: Str = "export-obj-as",
        quit: Str = "quit",

        ignore_groups: Str = "ignore groups",

        new: Str = "new",
        delete: Str = "delete",

        file: Str = "file",
        edit: Str = "edit",
        view: Str = "view",
        options: Str = "options",
        help: Str = "help",
    } = .{},
};

///Given an enum type, generate a struct of enum tags
fn enumStrings(comptime ET: type) type {
    const info = @typeInfo(ET).@"enum";

    var out_field: [info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (info.fields, 0..) |field, i| {
        out_field[i] = .{
            .name = field.name,
            .type = Str,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Str),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &out_field,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn initJsonFile(dir: std.fs.Dir, name: []const u8, alloc: std.mem.Allocator) !std.json.Parsed(Strings) {
    const in = try dir.openFile(name, .{});
    defer in.close();
    var read_buf: [4096]u8 = undefined;
    var r = in.reader(&read_buf);
    const slice = try r.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(slice);

    return try std.json.parseFromSlice(Strings, alloc, slice, .{ .allocate = .alloc_always });
}

pub fn writeJsonTemplate(dir: std.fs.Dir, name: []const u8) !void {
    var out = try dir.createFile(name, .{});

    defer out.close();
    var out_buf: [4096]u8 = undefined;
    var wr = out.writer(&out_buf);

    var jwr = std.json.Stringify{
        .writer = &wr.interface,
        .options = .{ .whitespace = .indent_1 },
    };

    try jwr.write(en_us);

    try wr.interface.flush();
}

const edit = @import("editor.zig");
