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

    // -Dprofile=true compiles in profiling hooks. Currently a no-op; the
    // option exists now so the rest of the tree can read it from build_options.
    const profile = b.option(
        bool,
        "profile",
        "Enable profiling instrumentation (placeholder)",
    ) orelse false;

    // -Dfreestanding=true leaves out the file system and the foreign
    // function interface, as a build for a freestanding target does.
    const freestanding = b.option(
        bool,
        "freestanding",
        "Leave out the file system and the foreign function interface",
    ) orelse false;

    // -Dgc-torture=N runs a collection every N allocations, so a value a
    // Zig local holds without rooting is reclaimed under it rather than
    // surviving by luck. Zero leaves the trigger heuristic in charge.
    const gc_torture = b.option(
        u32,
        "gc-torture",
        "Collect every N allocations (0 = off)",
    ) orelse 0;

    // -Ddispatch picks how the bytecode VM goes from one instruction to
    // the next: one switch in a loop, a switch that jumps from each
    // instruction straight to the next one's code, or a handler per
    // instruction that tail-calls the next.
    const dispatch = b.option(
        []const u8,
        "dispatch",
        "Bytecode dispatch: loop, threaded or tail",
    ) orelse "loop";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "dispatch", dispatch);
    build_options.addOption(u32, "gc_torture", gc_torture);
    build_options.addOption(bool, "ansi_tests", ansi_tests);
    build_options.addOption(bool, "profile", profile);
    build_options.addOption(bool, "freestanding", freestanding);
    const build_options_module = build_options.createModule();

    // Public runtime module — exposed to tests and to the executable.
    const zisp_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        // The foreign function interface looks C symbols up with dlsym.
        .link_libc = !freestanding,
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
    run_cmd.addPassthruArgs();
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
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{ .path = b.path("tests/test_runner.zig"), .mode = .simple },
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("tests", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build coverage` runs the test binary under kcov. Output goes to
    // ./coverage/ (gitignored). The kcov binary must be on PATH; install via
    // `apt install kcov` on Debian/Ubuntu or `brew install kcov` on macOS.
    //
    // We run kcov directly against the test artifact rather than going through
    // `zig build tests`'s IPC path — kcov needs a plain process to instrument,
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

    // `zig build fuzz-reader` runs a reader-only test binary. The test
    // routes through `std.testing.fuzz` so a future `-ffuzz` build can
    // engage Zig's mutation loop, and also drives a deterministic
    // PRNG-based loop that runs each invocation regardless of fuzz
    // mode — the property check (no panic / no leak / typed errors
    // only) holds for both.
    const fuzz_reader_module = b.createModule(.{
        .root_source_file = b.path("tests/reader/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zisp", .module = zisp_module },
        },
    });
    const fuzz_reader_tests = b.addTest(.{ .root_module = fuzz_reader_module });
    const run_fuzz_reader = b.addRunArtifact(fuzz_reader_tests);
    run_fuzz_reader.addPassthruArgs();
    const fuzz_reader_step = b.step("fuzz-reader", "Run the reader fuzzer");
    fuzz_reader_step.dependOn(&run_fuzz_reader.step);

    // `zig build gc-stress` runs the collector's long-running corpus at
    // full size. The default size the corpus carries is what the unit
    // suite runs; a hundred million cells takes far too long for that.
    const gc_stress_run = b.addRunArtifact(exe);
    gc_stress_run.addArgs(&.{
        "--batch",
        "--quiet",
        "--eval",
        "(defparameter *gc-stress-iterations* 100000000)",
        "--load",
        "tests/lisp/gc-stress.lisp",
    });
    const gc_stress_step = b.step("gc-stress", "Run the collector's long-running stress corpus");
    gc_stress_step.dependOn(&gc_stress_run.step);

    // `zig build gc-pause` runs the collector's pause corpus for a minute.
    // The size the corpus carries by default is a short version of the
    // same run, for when someone wants an answer sooner.
    const gc_pause_run = b.addRunArtifact(exe);
    gc_pause_run.addArgs(&.{
        "--batch",
        "--quiet",
        "--eval",
        "(defparameter *gc-pause-seconds* 60)",
        "--load",
        "tests/lisp/gc-pause.lisp",
        "--eval",
        "(room t)",
    });
    const gc_pause_step = b.step("gc-pause", "Measure what share of a run the collector takes");
    gc_pause_step.dependOn(&gc_pause_run.step);

    // `zig build bytecode-bench` times a loop compiled against the same
    // loop interpreted, and fails when compiling has fallen below the
    // speedup the benchmark asks for.
    const bytecode_bench_run = b.addRunArtifact(exe);
    bytecode_bench_run.addArgs(&.{ "--batch", "--quiet", "--load", "tests/lisp/bytecode-bench.lisp" });
    const bytecode_bench_step = b.step("bytecode-bench", "Measure the bytecode VM against the interpreter");
    bytecode_bench_step.dependOn(&bytecode_bench_run.step);

    // `zig build unboxing-bench` times typed fixnum and single-float
    // loops compiled against the same loops interpreted.
    const unboxing_bench_run = b.addRunArtifact(exe);
    unboxing_bench_run.addArgs(&.{ "--batch", "--quiet", "--load", "tests/lisp/unboxing-bench.lisp" });
    const unboxing_bench_step = b.step("unboxing-bench", "Measure typed loops compiled against the interpreter");
    unboxing_bench_step.dependOn(&unboxing_bench_run.step);

    // `zig build optimize-bench` times a loop compiled with (speed 3)
    // against the same loop compiled with (speed 0).
    const optimize_bench_run = b.addRunArtifact(exe);
    optimize_bench_run.addArgs(&.{ "--batch", "--quiet", "--load", "tests/lisp/optimize-bench.lisp" });
    const optimize_bench_step = b.step("optimize-bench", "Measure (speed 3) against (speed 0)");
    optimize_bench_step.dependOn(&optimize_bench_run.step);

    // `zig build tco-soak` runs tail-recursive loops for a minute each
    // and fails when one grew the frames in progress.
    const tco_soak_run = b.addRunArtifact(exe);
    tco_soak_run.addArgs(&.{ "--batch", "--quiet", "--load", "tests/lisp/tco-soak.lisp" });
    const tco_soak_step = b.step("tco-soak", "Run tail-recursive loops for a minute each");
    tco_soak_step.dependOn(&tco_soak_run.step);

    // `zig build image-cold-start` saves a small session as an image and
    // fails when starting from it takes longer than the gate allows.
    const image_run = b.addSystemCommand(&.{"env"});
    image_run.addPrefixedFileArg("ZISP=", exe.getEmittedBin());
    image_run.addArgs(&.{ "bash", "tests/run-image-cold-start.sh" });
    image_run.step.dependOn(b.getInstallStep());
    const image_step = b.step("image-cold-start", "Time starting from a saved image");
    image_step.dependOn(&image_run.step);

    // `zig build boyer` measures cl-bench's Boyer benchmark with the
    // nursery and without it, and fails if the generational collector
    // has fallen behind the mark and sweep baseline.
    const boyer_run = b.addSystemCommand(&.{"env"});
    boyer_run.addPrefixedFileArg("ZISP=", exe.getEmittedBin());
    boyer_run.addArgs(&.{ "bash", "tests/run-boyer.sh" });
    boyer_run.step.dependOn(b.getInstallStep());
    const boyer_step = b.step("boyer", "Measure the collector against cl-bench's Boyer benchmark");
    boyer_step.dependOn(&boyer_run.step);

    // The ansi-test harnesses run a ReleaseSafe zisp whatever -Doptimize
    // says. A Debug build records a stack trace on every allocation, which
    // makes the suite take minutes where this takes seconds, and safety
    // checks stay on.
    const suite_runtime = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_module },
        },
    });
    const suite_exe = b.addExecutable(.{
        .name = "zisp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zisp", .module = suite_runtime },
                .{ .name = "cli", .module = b.createModule(.{
                    .root_source_file = b.path("src/cli.zig"),
                    .target = target,
                    .optimize = .ReleaseSafe,
                }) },
            },
        }),
    });
    const suite_dir: std.Build.InstallDir = .{ .custom = "suite" };
    const suite_install = b.addInstallArtifact(suite_exe, .{ .dest_dir = .{ .override = suite_dir } });

    // `zig build ansi-test` shells out to the harness in tests/run-ansi.sh,
    // passing ZISP=... so the script doesn't have to guess the path.
    const ansi_run = b.addSystemCommand(&.{"env"});
    ansi_run.addPrefixedFileArg("ZISP=", suite_exe.getEmittedBin());
    ansi_run.addArgs(&.{ "bash", "tests/run-ansi.sh" });
    ansi_run.step.dependOn(&suite_install.step);
    const ansi_step = b.step("ansi-test", "Run the ANSI Common Lisp test suite");
    ansi_step.dependOn(&ansi_run.step);

    // `zig build rt-tests -- format typep` runs the named rt slices
    // through tests/run-rt-tests.sh.
    const rt_run = b.addSystemCommand(&.{"env"});
    rt_run.addPrefixedFileArg("ZISP=", suite_exe.getEmittedBin());
    rt_run.addArgs(&.{ "bash", "tests/run-rt-tests.sh" });
    rt_run.step.dependOn(&suite_install.step);
    rt_run.addPassthruArgs();
    const rt_step = b.step("rt-tests", "Run rt-based ansi-test slices: zig build rt-tests -- <slice>...");
    rt_step.dependOn(&rt_run.step);

    // `zig build gclload` loads the suite through its own gclload1.lsp,
    // in a copy of it, through tests/run-gclload.sh.
    const gclload_run = b.addSystemCommand(&.{"env"});
    gclload_run.addPrefixedFileArg("ZISP=", suite_exe.getEmittedBin());
    gclload_run.addArgs(&.{ "bash", "tests/run-gclload.sh" });
    gclload_run.step.dependOn(&suite_install.step);
    const gclload_step = b.step("gclload", "Load the ansi-test suite through its own gclload1.lsp");
    gclload_step.dependOn(&gclload_run.step);

    // `zig build subtypep-sbcl` compares zisp's subtypep with SBCL's
    // through tests/run-subtypep-sbcl-diff.sh. It needs sbcl on the PATH.
    const subtypep_sbcl_run = b.addSystemCommand(&.{"env"});
    subtypep_sbcl_run.addPrefixedFileArg("ZISP=", suite_exe.getEmittedBin());
    subtypep_sbcl_run.addArgs(&.{ "bash", "tests/run-subtypep-sbcl-diff.sh" });
    subtypep_sbcl_run.step.dependOn(&suite_install.step);
    const subtypep_sbcl_step = b.step("subtypep-sbcl", "Compare subtypep with SBCL on the ansi-test subtypep calls");
    subtypep_sbcl_step.dependOn(&subtypep_sbcl_run.step);

    // `zig build wasi-test` builds zisp for wasm32-wasi and runs the
    // corpora in tests/wasi-corpora.txt in it under Node's WASI.
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasi_exe = b.addExecutable(.{
        .name = "zisp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasi_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zisp", .module = b.createModule(.{
                    .root_source_file = b.path("src/runtime.zig"),
                    .target = wasi_target,
                    .optimize = .ReleaseSafe,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "build_options", .module = build_options_module },
                    },
                }) },
                .{ .name = "cli", .module = b.createModule(.{
                    .root_source_file = b.path("src/cli.zig"),
                    .target = wasi_target,
                    .optimize = .ReleaseSafe,
                }) },
            },
        }),
    });
    const wasi_install = b.addInstallArtifact(wasi_exe, .{ .dest_dir = .{ .override = .{ .custom = "wasi" } } });
    const wasi_run = b.addSystemCommand(&.{"env"});
    wasi_run.addPrefixedFileArg("ZISP_WASM=", wasi_exe.getEmittedBin());
    wasi_run.addArgs(&.{ "bash", "tests/run-corpus-wasi.sh" });
    wasi_run.step.dependOn(&wasi_install.step);
    wasi_run.addPassthruArgs();
    const wasi_step = b.step("wasi-test", "Run the corpora in zisp built for wasm32-wasi, under Node");
    wasi_step.dependOn(&wasi_run.step);

    // `zig build wasm` builds zisp as a wasm32-freestanding module for a
    // host such as a browser, with the entry points in src/wasm.zig.
    const freestanding_wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const freestanding_options = b.addOptions();
    freestanding_options.addOption([]const u8, "dispatch", dispatch);
    freestanding_options.addOption(u32, "gc_torture", 0);
    freestanding_options.addOption(bool, "ansi_tests", false);
    freestanding_options.addOption(bool, "profile", false);
    freestanding_options.addOption(bool, "freestanding", true);
    const web_wasm = b.addExecutable(.{
        .name = "zisp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = freestanding_wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "zisp", .module = b.createModule(.{
                    .root_source_file = b.path("src/runtime.zig"),
                    .target = freestanding_wasm_target,
                    .optimize = .ReleaseSmall,
                    .imports = &.{
                        .{ .name = "build_options", .module = freestanding_options.createModule() },
                    },
                }) },
            },
        }),
    });
    web_wasm.entry = .disabled;
    web_wasm.rdynamic = true;
    const web_dir: std.Build.InstallDir = .{ .custom = "web" };
    const web_wasm_install = b.addInstallArtifact(web_wasm, .{ .dest_dir = .{ .override = web_dir } });
    const embed_wasm = b.addExecutable(.{
        .name = "embed-wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/embed-wasm.zig"),
            .target = b.graph.host,
        }),
    });
    const embed_run = b.addRunArtifact(embed_wasm);
    embed_run.addFileArg(web_wasm.getEmittedBin());
    embed_run.addFileArg(b.path("examples/wasm-repl/demo.lisp"));
    const embedded = embed_run.addOutputFileArg("zisp-wasm.js");
    const web_wasm_step = b.step("wasm", "Build zisp for wasm32-freestanding and the REPL page into zig-out/web/");
    web_wasm_step.dependOn(&web_wasm_install.step);
    web_wasm_step.dependOn(&b.addInstallFileWithDir(embedded, web_dir, "zisp-wasm.js").step);
    for ([_][]const u8{ "index.html", "zisp.js" }) |name| {
        const file = b.addInstallFileWithDir(b.path(b.fmt("examples/wasm-repl/{s}", .{name})), web_dir, name);
        web_wasm_step.dependOn(&file.step);
    }

    // `zig build wasm-test` runs the demo through the page's loader under Node.
    const wasm_test_run = b.addSystemCommand(&.{ "node", "tests/run-wasm-repl.mjs" });
    wasm_test_run.addFileArg(web_wasm.getEmittedBin());
    const wasm_test_step = b.step("wasm-test", "Run the REPL page's demo in the wasm32-freestanding build under Node");
    wasm_test_step.dependOn(&wasm_test_run.step);

    // -Dansi-tests=true: fold ansi-test into the default build.
    if (ansi_tests) {
        b.getInstallStep().dependOn(&ansi_run.step);
    }
}
