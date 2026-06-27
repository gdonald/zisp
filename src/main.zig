const std = @import("std");
const zisp = @import("zisp");
const cli = @import("cli");

pub fn main(init: std.process.Init) !u8 {
    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iter.deinit();

    _ = iter.next(); // program name

    var buf: [64][]const u8 = undefined;
    var n: usize = 0;
    while (iter.next()) |arg| : (n += 1) {
        if (n >= buf.len) {
            cli.write("zisp: too many arguments (max {d})\n", .{buf.len});
            return @intFromEnum(cli.ExitCode.user_error);
        }
        buf[n] = arg;
    }

    const action = try cli.parseArgs(init.gpa, buf[0..n]);
    return switch (action) {
        .print_version => blk: {
            cli.write("zisp {s}\n", .{cli.VERSION});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
        .print_help => blk: {
            cli.write("{s}", .{cli.HELP_TEXT});
            break :blk @intFromEnum(cli.ExitCode.success);
        },
        .user_error => |msg| blk: {
            cli.write("zisp: {s}\nTry 'zisp --help' for usage.\n", .{msg});
            break :blk @intFromEnum(cli.ExitCode.user_error);
        },
        .read_only => |path| readOnlyMode(init.gpa, init.io, path),
        .repl => replMode(init.gpa, init.io),
        .run => |plan| blk: {
            defer plan.deinit(init.gpa);
            break :blk runPlan(init.gpa, init.io, plan);
        },
    };
}

/// Execute a batch plan: run each `--eval` / `--load` op in order, then a
/// script if present, then drop into the REPL unless `--batch` was given.
fn runPlan(gpa: std.mem.Allocator, io: std.Io, plan: cli.Plan) !u8 {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    const out = &stdout_writer.interface;

    var repl = try zisp.repl.Repl.init(gpa, out, io);
    defer repl.deinit();

    for (plan.ops) |op| {
        const result = switch (op) {
            .eval => |expr| repl.evalForms(expr, true),
            .load => |path| repl.loadFile(path),
        };
        result catch |e| {
            if (e == error.Quit) break;
            try out.flush();
            cli.write("zisp: error: {s}\n", .{@errorName(e)});
            return @intFromEnum(cli.ExitCode.user_error);
        };
    }

    if (repl.ev.quit_code == null) {
        if (plan.script) |path| {
            try bindCommandLineArgs(repl, plan.script_args);
            repl.loadFile(path) catch |e| {
                if (e != error.Quit) {
                    try out.flush();
                    cli.write("zisp: error: {s}\n", .{@errorName(e)});
                    return @intFromEnum(cli.ExitCode.user_error);
                }
            };
        }
    }

    if (repl.ev.quit_code) |code| {
        try out.flush();
        return code;
    }

    if (!plan.batch and plan.script == null) {
        if (!plan.quiet) try out.print("zisp {s}\n", .{cli.VERSION});
        try runInteractive(gpa, io, repl, out);
        if (repl.ev.quit_code) |code| {
            try out.flush();
            return code;
        }
    }

    try out.flush();
    return @intFromEnum(cli.ExitCode.success);
}

/// Bind `*command-line-arguments*` to a list of the script's arguments.
fn bindCommandLineArgs(repl: *zisp.repl.Repl, script_args: []const []const u8) !void {
    var list = zisp.value.NIL;
    var i: usize = script_args.len;
    while (i > 0) {
        i -= 1;
        const s = try repl.ev.heap.allocString(script_args[i]);
        list = try repl.ev.heap.allocCons(s, list);
    }
    const sym = try repl.ev.interner.intern("*COMMAND-LINE-ARGUMENTS*");
    zisp.symbol.symbol(sym).value_cell = list;
}

/// Read all of stdin and feed it to the REPL.
fn replMode(gpa: std.mem.Allocator, io: std.Io) !u8 {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    const out = &stdout_writer.interface;

    try out.print("zisp {s}\n", .{cli.VERSION});

    var repl = try zisp.repl.Repl.init(gpa, out, io);
    defer repl.deinit();

    try runInteractive(gpa, io, repl, out);
    try out.flush();
    return @intFromEnum(cli.ExitCode.success);
}

fn runInteractive(gpa: std.mem.Allocator, io: std.Io, repl: *zisp.repl.Repl, out: *std.Io.Writer) !void {
    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(std.Io.File.stdin(), io, &read_buf);
    var source_list: std.ArrayList(u8) = .empty;
    defer source_list.deinit(gpa);
    file_reader.interface.appendRemainingUnlimited(gpa, &source_list) catch |e| {
        cli.write("zisp: read error: {s}\n", .{@errorName(e)});
        return;
    };

    try repl.run(source_list.items);
    try out.flush();
}

/// Reads `path`, hands the bytes to `zisp.read_all.parseAll`, and prints
/// a one-line summary tailored for `tests/run-ansi.sh`'s grep aggregation.
fn readOnlyMode(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        cli.write("FAIL {s}: {s}\n", .{ path, @errorName(e) });
        return @intFromEnum(cli.ExitCode.user_error);
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var source_list: std.ArrayList(u8) = .empty;
    defer source_list.deinit(gpa);
    file_reader.interface.appendRemainingUnlimited(gpa, &source_list) catch |e| {
        cli.write("FAIL {s}: {s}\n", .{ path, @errorName(e) });
        return @intFromEnum(cli.ExitCode.internal_error);
    };

    const outcome = try zisp.read_all.parseAll(gpa, source_list.items, path);
    switch (outcome) {
        .ok => |forms| {
            cli.write("OK {s} forms={d}\n", .{ path, forms });
            return @intFromEnum(cli.ExitCode.success);
        },
        .fail => |info| {
            cli.write(
                "FAIL {s}:{d}:{d} {s} after {d} forms\n",
                .{ path, info.pos.line, info.pos.column, @errorName(info.err), info.forms },
            );
            return @intFromEnum(cli.ExitCode.test_failure);
        },
    }
}
