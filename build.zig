const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dansi-tests=true makes `zig build` depend on the ansi-test step.
    // Off by default so day-to-day builds don't shell out to bash.
    const ansi_tests = b.option(
        bool,
        "ansi-tests",
        "Run the ANSI Common Lisp test suite as part of `zig build`",
    ) orelse false;

    // -Dprofile=true compiles in profiling hooks. No-op until Phase 9; the
    // option exists now so the rest of the tree can read it from build_options.
    const profile = b.option(
        bool,
        "profile",
        "Enable profiling instrumentation (Phase 9 placeholder)",
    ) orelse false;

    // -Dfreestanding=true is the Phase 10 embedded build. The option is
    // accepted now and threaded through build_options so 10.2.1's grep-gate
    // can detect violations the moment the freestanding tree starts taking shape.
    const freestanding = b.option(
        bool,
        "freestanding",
        "Build for a freestanding target — no std.io/std.fs/std.os (Phase 10 placeholder)",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "ansi_tests", ansi_tests);
    build_options.addOption(bool, "profile", profile);
    build_options.addOption(bool, "freestanding", freestanding);
    const build_options_module = build_options.createModule();

    // Public runtime module — exposed to tests and to the executable.
    const zisp_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    // CLI module — used by the executable; tested separately.
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable entry.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zisp", .module = zisp_module },
            .{ .name = "cli", .module = cli_module },
        },
    });
    const exe = b.addExecutable(.{
        .name = "zisp",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zisp");
    run_step.dependOn(&run_cmd.step);

    // Test root lives in tests/all.zig and pulls in the rest of tests/ via comptime imports.
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zisp", .module = zisp_module },
            .{ .name = "cli", .module = cli_module },
            .{ .name = "build_options", .module = build_options_module },
        },
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build coverage` runs the test binary under kcov. Output goes to
    // ./coverage/ (gitignored). The kcov binary must be on PATH; install via
    // `apt install kcov` on Debian/Ubuntu or `brew install kcov` on macOS.
    //
    // We run kcov directly against the test artifact rather than going through
    // `zig build test`'s IPC path — kcov needs a plain process to instrument,
    // and the IPC --listen=- flag would confuse it.
    const cov_run = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=src/",
    });
    cov_run.addArg("coverage");
    cov_run.addArtifactArg(tests);
    const cov_step = b.step("coverage", "Run unit tests under kcov; report in ./coverage/");
    cov_step.dependOn(&cov_run.step);

    // `zig build ansi-test` shells out to the harness in tests/run-ansi.sh.
    // The harness needs the binary built first; depend on the install step
    // and pass ZISP=... so the script doesn't have to guess the path.
    const ansi_run = b.addSystemCommand(&.{ "bash", "tests/run-ansi.sh" });
    ansi_run.setEnvironmentVariable("ZISP", b.getInstallPath(.bin, "zisp"));
    ansi_run.step.dependOn(b.getInstallStep());
    const ansi_step = b.step("ansi-test", "Run the ANSI Common Lisp test suite");
    ansi_step.dependOn(&ansi_run.step);

    // -Dansi-tests=true: fold ansi-test into the default build.
    if (ansi_tests) {
        b.getInstallStep().dependOn(&ansi_run.step);
    }
}
