const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const strip = optimize == .ReleaseFast;

    const remote = b.addExecutable(.{
        .name = "ratremote",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    const hammer_exe = b.addExecutable(.{
        .name = "rathammer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const ratdep = b.dependency("ratgraph", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });
    const uuidmod = uuid_dep.module("uuid");
    const ratmod = ratdep.module("ratgraph");
    hammer_exe.root_module.addImport("graph", ratmod);
    hammer_exe.root_module.addImport("uuidlib", uuidmod);
    remote.root_module.addImport("graph", ratmod);

    const opts = b.addOptions();
    opts.addOption(u32, "stack_trace_frames", b.option(u32, "stack_trace_frames", "number of stack frames for alloc to track in debug mode") orelse 0);

    opts.addOption(bool, "time_profile", b.option(bool, "profile", "profile the time loading takes") orelse false);
    opts.addOption(bool, "dump_vpk", b.option(bool, "dumpvpk", "dump all vpk entries to text file") orelse false);
    opts.addOption(bool, "http_version_check", b.option(bool, "http_version_check", "Enable support for http version check") orelse false);
    opts.addOption(?[]const u8, "http_version_check_url", b.option([]const u8, "http_version_check_url", "override url for version check") orelse null);
    opts.addOption([]const u8, "commit_hash", b.option([]const u8, "commit_hash", "Embed git hash in build") orelse "unspecified");

    const version_opt = b.addOptions();
    version_opt.addOption([]const u8, "version", zon.version);

    hammer_exe.root_module.addOptions("config", opts);
    hammer_exe.root_module.addOptions("version", version_opt);
    remote.root_module.addOptions("version", version_opt);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(hammer_exe);
    b.installArtifact(remote);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(hammer_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    }), .use_llvm = false });
    exe_unit_tests.root_module.addImport("graph", ratmod);
    exe_unit_tests.root_module.addOptions("config", opts);
    exe_unit_tests.root_module.addImport("uuidlib", uuidmod);
    exe_unit_tests.root_module.addOptions("version", version_opt);
    const do_kcov = b.option(bool, "kcov", "run tests with kcov") orelse false;
    if (do_kcov)
        exe_unit_tests.setExecCmd(&[_]?[]const u8{ "kcov", "--exclude-path=/usr/lib", "kcov-output", null });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
