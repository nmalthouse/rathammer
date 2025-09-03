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
    Arg("game", .string, "Name of a game defined in config.vdf"),
    Arg("custom_cwd", .string, "override the directory used for game"),
    Arg("fontfile", .string, "load custom font"),
    Arg("display_scale", .number, "override detected display scale, should be ~ 0.2-3"),
    Arg("config", .string, "load custom config, relative to cwd"),
    Arg("version", .flag, "Print rathammer version and exit"),
    Arg("build", .flag, "Print rathammer build info as json and exit"),
    Arg("no_version_check", .flag, "Don't check for newer version over http"),
};
