const std = @import("std");
const Str = []const u8;
//TODO
//pause window

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
        class: Str = "class",
        selected_id: Str = "selected id",
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

        ungroup: Str = "ungrouped objects",
        change_class: Str = "Change class",

        set_color: Str = "Set color",
        set_kv: Str = "Set kv",

        paste_io: Str = "paste io",
        delete_io: Str = "delete io",
        add_io: Str = "add io",
        edit_io: Str = "edit io",
        scale: Str = "scale",
        vertex_translate: Str = "vertex translate",
    } = .{},

    tool: struct {
        vtx_selection_mode: Str = "Selection mode",

        texture: struct {
            reset_face_world: Str = "Reset face world",
            reset_face_normal: Str = "Reset face normal",
            apply_to_selected: Str = "apply selection",
            apply_to_face: Str = "apply face",
            make_disp: Str = "Make displacement",
            x_axis: Str = "X",
            y_axis: Str = "y",
            scale: Str = "Scale",
            trans: Str = "Trans",
            axis: Str = "Axis",
            flip: Str = "flip",
            lux_scale: Str = "lux scale (hu / luxel)",
            justify: Str = "Justify",
            left: Str = "left",
            right: Str = "right",
            fit: Str = "fit",
            top: Str = "top",
            bottom: Str = "bot",
            center: Str = "center",
        } = .{},
    } = .{},

    saving: Str = "saving",
    saved: Str = "saved",
    autosaved: Str = "autosaved",
    search: Str = "Search",
    result: Str = "Results",
    up: Str = "up",
    down: Str = "down",
    columns: Str = "Columns",
    welcome: Str = "Welcome",
    set_skybox: Str = "Set skybox",
    description: Str = "Description",
    unsaved_changes: Str = "Unsaved changes!",
    default_layer_name: Str = "new layer",

    notify: struct {
        exported_vmf: Str = "Exported map to vmf",
        exported_vmf_fail: Str = "Failed exporting map to vmf",
        invalid_io_paste: Str = "invalid io csv",
    } = .{},

    draw_mode: enumStrings(edit.DrawMode) = .{
        .shaded = "shaded",
        .lightmap_scale = "lightmap scale",
    },

    checkbox: struct {
        draw_sprite: Str = "draw sprites",
        draw_model: Str = "draw models",
        draw_hdr: Str = "HDR",
        model_shadow: Str = "model shadows",
        draw_outlines: Str = "draw_outlines",
        draw_skybox: Str = "draw_skybox",
        draw_debug_stat: Str = "draw debug stat",
        modify_displacement: Str = "Modify disps",
    } = .{},

    btn: struct {
        load: Str = "load",
        open_help: Str = "Open help",
        open_help_in_browser: Str = "Open help in browser",
        open_home: Str = "Open homepage",
        save: Str = "save",
        save_as: Str = "save-as",
        build: Str = "build",
        build_user: Str = "build-user",
        export_obj: Str = "export-obj",
        export_obj_as: Str = "export-obj-as",
        quit: Str = "quit",
        unpause: Str = "unpause",

        ignore_groups: Str = "ignore groups",

        new: Str = "new",
        new_map: Str = "new map",
        load_map: Str = "open map",
        delete: Str = "delete",

        file: Str = "file",
        edit: Str = "edit",
        view: Str = "view",
        options: Str = "options",
        help: Str = "help",

        ungroup: Str = "ungroup",
        show_help: Str = "show help",
        select: Str = "Select",

        cancel: Str = "cancel",
        copy_io: Str = "copy io",
        paste_new: Str = "paste new",
        accept: Str = "accept",
        undo: Str = "undo",
        redo: Str = "redo",

        new_layer: Str = "New layer",
        layer_move_selected: Str = "-> put",
        layer_select_all: Str = "<- select",
        layer_dupe: Str = "duplicate",
        layer_new_child: Str = "new child",
        layer_omit_export: Str = "don't export",
        layer_delete: Str = "delete layer",
        layer_merge_up: Str = "^ merge up",
        layer_attach_sibling: Str = "attach as sibling",
        layer_attach_child: Str = "attach as child",

        snap_selected_to_int: Str = "snap selected to integer",

        import_vmfs: Str = "import vmfs",
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

pub fn writeCsv(wr: *std.io.Writer) !void {
    const help = struct {
        fn recur(w: *std.io.Writer, comptime T: type, comptime name_space: []const u8, value: ?Str) !void {
            const info = @typeInfo(T);
            switch (info) {
                .@"struct" => |s| {
                    inline for (s.fields) |field| {
                        try recur(
                            w,
                            field.type,
                            name_space ++ "." ++ field.name,
                            if (field.type == Str) field.defaultValue() else null,
                        );
                    }
                },
                else => {
                    if (T == Str) {
                        try w.print("{s}, {s}\n", .{
                            name_space[1..
                            // +1 to strip leading .
                            ],
                            value orelse "",
                        });
                        return;
                    }
                    @compileError("nope " ++ @typeName(T));
                },
            }
        }
    };

    try help.recur(wr, Strings, "", null);

    try wr.flush();
}

const edit = @import("editor.zig");
