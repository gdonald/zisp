//! System and batch builtins: `format`, `load`, `quit` / `exit`, plus the
//! `*standard-output*` and `*features*` variables the batch driver and the
//! test harness rely on. These sit apart from the pure value builtins because
//! they reach the evaluator's output sink, filesystem, and exit channel.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../runtime/value.zig");
const heap = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const format = @import("format.zig");
const streams = @import("streams.zig");
const reader_mod = @import("../reader.zig");
const collect_mod = @import("../eval/collect.zig");
const eval_mod = @import("../eval/eval.zig");
const readtables = @import("readtables.zig");
const special_forms = @import("../eval/special_forms.zig");
const function = @import("../eval/function.zig");
const pathnames = @import("pathnames.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

/// Namestring behind a pathname designator: a string, or a pathname.
const namestringOf = pathnames.namestringOf;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerSystem(ev: *Evaluator) !void {
    _ = try ev.defineNative("FORMAT", &formatFn);
    _ = try ev.defineNative("%FORMAT-TAIL", &formatTailFn);
    _ = try ev.defineNative("LOAD", &loadFn);
    _ = try ev.defineNative("COMPILE-FILE", &compileFileFn);
    _ = try ev.defineNative("TRUENAME", &truenameFn);
    _ = try ev.defineNative("PROBE-FILE", &probeFileFn);
    _ = try ev.defineNative("FILE-WRITE-DATE", &fileWriteDateFn);
    _ = try ev.defineNative("PRIN1-TO-STRING", toStringFn(true));
    _ = try ev.defineNative("PRINC-TO-STRING", toStringFn(false));
    _ = try ev.defineNative("%WRITE-TO-STRING", toStringFn(true));
    function.asFunction(try ev.defineNative("READ-FROM-STRING", &readFromStringFn))
        .preserves_values = true;
    _ = try ev.defineNative("QUIT", &quitFn);
    _ = try ev.defineNative("EXIT", &quitFn);

    // Bound to namestrings during load / compile-file, nil otherwise.
    // Real pathname objects arrive with the pathname type.
    for ([_][]const u8{
        "*LOAD-PATHNAME*",
        "*LOAD-TRUENAME*",
        "*COMPILE-FILE-PATHNAME*",
        "*COMPILE-FILE-TRUENAME*",
    }) |n| {
        const sym = try ev.interner.intern(n);
        if (symbol_mod.symbol(sym).value_cell.equalsRaw(value.SPECIAL_UNBOUND)) {
            symbol_mod.symbol(sym).value_cell = value.NIL;
        }
    }

    try installFeatures(ev);
}

fn installFeatures(ev: *Evaluator) !void {
    const os_feature = switch (builtin.os.tag) {
        .linux => "LINUX",
        .macos => "DARWIN",
        else => "UNIX",
    };
    const arch_feature = switch (builtin.cpu.arch) {
        .x86_64 => "X86-64",
        .aarch64 => "ARM64",
        else => "UNKNOWN-ARCH",
    };
    const names = [_][]const u8{ "ZISP", "ANSI-CL", "COMMON-LISP", os_feature, arch_feature };

    var builder = ev.heap.listBuilder();
    for (names) |name| try builder.append(try ev.interner.internKeyword(name));
    const list = builder.finish();
    const features = try ev.interner.intern("*FEATURES*");
    symbol_mod.symbol(features).value_cell = list;
}

// --- format ---

fn formatFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const dest = args[0];
    const control = args[1];
    if (function.isFunction(control)) return formatThroughFunction(ev, dest, control, args[2..]);
    if (!heap.isString(control)) return Error.TypeError;
    const ctrl = heap.asString(control).constSlice();
    const fmt_args = args[2..];

    // A nil destination collects into a fresh string and returns it.
    if (dest.equalsRaw(value.NIL)) {
        var aw = std.Io.Writer.Allocating.init(ev.allocator);
        defer aw.deinit();
        var column: usize = 0;
        _ = try format.run(ev, .{ .writer = &aw.writer, .column = &column }, ctrl, fmt_args);
        return ev.heap.allocString(aw.written());
    }

    const stream = try streams.streamOf(ev, dest, .output);
    if (stream.kind == .console) {
        const out = ev.out orelse return Error.NoOutputStream;
        _ = try format.run(ev, .{ .writer = out, .column = &ev.output_column }, ctrl, fmt_args);
        return value.NIL;
    }

    // Any other stream takes the rendered text as bytes.
    var aw = std.Io.Writer.Allocating.init(ev.allocator);
    defer aw.deinit();
    var column: usize = 0;
    _ = try format.run(ev, .{ .writer = &aw.writer, .column = &column }, ctrl, fmt_args);
    try streams.emitBytes(ev, stream, aw.written());
    return value.NIL;
}

/// `format` with a function for its control, which is what `formatter`
/// hands back. The function does the writing, so all this settles is
/// where it writes and what comes back.
fn formatThroughFunction(ev: *Evaluator, dest: Value, control: Value, rest: []const Value) Error!Value {
    var call: std.ArrayListUnmanaged(Value) = .empty;
    defer call.deinit(ev.allocator);

    const collecting = dest.equalsRaw(value.NIL);
    const target = if (collecting)
        try ev.heap.allocStream(streams.emptyStream(.string, .output))
    else if (dest.equalsRaw(value.T))
        try standardOutput(ev)
    else
        dest;

    var held = ev.heap.protect();
    defer held.close();
    try held.push(target);

    try call.append(ev.allocator, target);
    try call.appendSlice(ev.allocator, rest);
    _ = try ev.callFunction(control, call.items);

    if (!collecting) return value.NIL;
    const stream = try streams.expectStream(target);
    const text = try ev.heap.allocString(stream.output.items);
    stream.output.clearRetainingCapacity();
    return text;
}

/// What `*standard-output*` names, which is where a destination of `t`
/// sends its output.
fn standardOutput(ev: *Evaluator) Error!Value {
    const sym = ev.interner.lookup("*STANDARD-OUTPUT*") orelse return Error.NoOutputStream;
    return ev.env.lookupValue(sym) orelse Error.NoOutputStream;
}

/// Write `control` to `stream` and hand back the arguments it did not
/// use, which is the contract a `formatter` function is called under.
fn formatTailFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const control = args[1];
    if (function.isFunction(control)) {
        _ = try formatThroughFunction(ev, args[0], control, args[2..]);
        return value.NIL;
    }
    if (!heap.isString(control)) return Error.TypeError;
    const ctrl = heap.asString(control).constSlice();
    const rest = args[2..];

    const stream = try streams.streamOf(ev, args[0], .output);
    var consumed: usize = 0;
    if (stream.kind == .console) {
        const out = ev.out orelse return Error.NoOutputStream;
        consumed = try format.run(ev, .{ .writer = out, .column = &ev.output_column }, ctrl, rest);
    } else {
        var aw = std.Io.Writer.Allocating.init(ev.allocator);
        defer aw.deinit();
        var column: usize = 0;
        consumed = try format.run(ev, .{ .writer = &aw.writer, .column = &column }, ctrl, rest);
        try streams.emitBytes(ev, stream, aw.written());
    }

    var builder = ev.heap.listBuilder();
    for (rest[@min(consumed, rest.len)..]) |arg| try builder.append(arg);
    return builder.finish();
}

// --- printing to a string ---

fn toStringFn(comptime escape: bool) function.NativeFn {
    return struct {
        fn f(p: *anyopaque, args: []const Value) Error!Value {
            const ev = evaluator(p);
            if (args.len != 1) return Error.WrongArgCount;
            var aw = std.Io.Writer.Allocating.init(ev.allocator);
            defer aw.deinit();
            if (!escape) {
                var arena = std.heap.ArenaAllocator.init(ev.allocator);
                defer arena.deinit();
                if (try format.conditionReport(ev, arena.allocator(), args[0])) |text| {
                    return ev.heap.allocString(text);
                }
            }
            const settings = if (escape) format.prin1Settings(ev) else format.princSettings(ev);
            try printer.write(ev.allocator, &aw.writer, args[0], settings);
            return ev.heap.allocString(aw.written());
        }
    }.f;
}

/// `(read-from-string string)` returns the first form and the index just
/// past the text it consumed.
fn readFromStringFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    if (!heap.isString(args[0])) return Error.TypeError;
    const source = try heap.stringUtf8Alloc(ev.allocator, args[0]);
    defer ev.allocator.free(source);

    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
    rd.read_eval = .{ .context = @ptrCast(ev), .call = &eval_mod.Evaluator.readEval };
    readtables.install(ev, &rd);
    const form = rd.read() catch return Error.ProgramError;
    return ev.setValues(&.{
        form orelse return Error.ProgramError,
        Value.fromFixnum(@intCast(tokenizer.idx)),
    });
}

// --- load ---

fn loadFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    try loadPath(ev, try namestringOf(ev.heap.allocator, args[0]));
    return value.T;
}

/// Read and evaluate every form in the file at `path`. Used by the `load`
/// builtin and by the driver's `--load` / `--script` handling. Binds
/// `*load-pathname*` / `*load-truename*` to namestrings for the duration.
pub fn loadPath(ev: *Evaluator, path: []const u8) Error!void {
    const io = ev.io orelse return Error.FileError;
    const source = try readFileAlloc(ev, io, path);
    defer ev.allocator.free(source);

    const truename = truenameOf(ev, io, path) catch return Error.FileError;
    defer ev.allocator.free(truename);

    var bindings = try PathVarBindings.bind(ev, "*LOAD-PATHNAME*", "*LOAD-TRUENAME*", path, truename);
    defer bindings.restore();

    // CLHS 24.1: `load` binds `*package*`, so an `in-package` in the file
    // does not leak into whatever loaded it.
    const saved_package = ev.interner.currentPackage();
    defer ev.interner.setCurrentPackage(saved_package);

    try evalSource(ev, source);
}

fn readFileAlloc(ev: *Evaluator, io: std.Io, path: []const u8) Error![]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(ev.allocator);
    file_reader.interface.appendRemainingUnlimited(ev.allocator, &source) catch return Error.FileError;
    return source.toOwnedSlice(ev.allocator);
}

fn truenameOf(ev: *Evaluator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, ev.allocator);
}

fn truenameFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    const path = try namestringOf(ev.heap.allocator, args[0]);
    const resolved = truenameOf(ev, io, path) catch return Error.FileError;
    defer ev.allocator.free(resolved);
    return pathnames.parsed(ev, resolved);
}

fn probeFileFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    const path = try namestringOf(ev.heap.allocator, args[0]);
    const resolved = truenameOf(ev, io, path) catch return value.NIL;
    defer ev.allocator.free(resolved);
    return pathnames.parsed(ev, resolved);
}

/// Universal time counts from 1900-01-01, seventy years before the Unix epoch.
const UNIX_EPOCH_UNIVERSAL_TIME: i64 = 2208988800;

fn fileWriteDateFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const io = ev.io orelse return Error.FileError;
    const path = try namestringOf(ev.heap.allocator, args[0]);
    const info = std.Io.Dir.cwd().statFile(io, path, .{}) catch return Error.FileError;
    const seconds: i64 = @intCast(@divFloor(info.mtime.nanoseconds, std.time.ns_per_s));
    return Value.fromFixnum(seconds + UNIX_EPOCH_UNIVERSAL_TIME);
}

/// Saved global cells for a pathname/truename variable pair, rebound for
/// the duration of a load or compile-file.
/// The previous contents of the two variables `load` rebinds. A nested
/// `load` collects while these are out of their symbols' cells, so they
/// are pinned rather than held in the struct alone.
const PathVarBindings = struct {
    ev: *Evaluator,
    pathname_sym: Value,
    truename_sym: Value,
    pin_mark: usize,

    fn bind(
        ev: *Evaluator,
        pathname_var: []const u8,
        truename_var: []const u8,
        path: []const u8,
        truename: []const u8,
    ) Error!PathVarBindings {
        const p_sym = try ev.interner.intern(pathname_var);
        const t_sym = try ev.interner.intern(truename_var);
        const saved = PathVarBindings{
            .ev = ev,
            .pathname_sym = p_sym,
            .truename_sym = t_sym,
            .pin_mark = ev.pinMark(),
        };
        try ev.pin(symbol_mod.symbol(p_sym).value_cell);
        try ev.pin(symbol_mod.symbol(t_sym).value_cell);
        symbol_mod.symbol(p_sym).value_cell = try ev.heap.allocString(path);
        symbol_mod.symbol(t_sym).value_cell = try ev.heap.allocString(truename);
        return saved;
    }

    fn restore(self: *PathVarBindings) void {
        const pins = self.ev.pinned.items;
        symbol_mod.symbol(self.pathname_sym).value_cell = pins[self.pin_mark];
        symbol_mod.symbol(self.truename_sym).value_cell = pins[self.pin_mark + 1];
        self.ev.unpinTo(self.pin_mark);
    }
};

/// Read and evaluate every form in `source`, discarding the values.
pub fn evalSource(ev: *Evaluator, source: []const u8) Error!void {
    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
    rd.read_eval = .{ .context = @ptrCast(ev), .call = &eval_mod.Evaluator.readEval };
    readtables.install(ev, &rd);
    while (true) {
        // Between top-level forms nothing but the evaluator's own state
        // holds a value, which is what makes a collection safe here.
        try collect_mod.maybeCollect(ev);
        const form = rd.read() catch return Error.ProgramError;
        const f = form orelse break;
        // The form is fresh structure nothing else holds.
        var held = ev.heap.protect();
        defer held.close();
        try held.push(f);
        _ = try ev.eval(f);
    }
}

// --- compile-file ---

/// Process one top-level form per the CLHS 3.2.3.1 minimal-compilation
/// rules. `ctt` is compile-time-too mode. Forms destined for load time are
/// appended to `out`; compile-time evaluation happens immediately.
pub fn compileToplevel(ev: *Evaluator, form: Value, ctt: bool, out: *std.ArrayList(Value)) Error!void {
    // The forms collected for the fasl, and the one in hand, are held
    // through the evaluation that compiling does. `out` is a Zig list, so
    // a pin is what keeps its contents from being reclaimed.
    try ev.pin(form);
    defer ev.unpin();
    var f = form;
    while (try ev.macroexpand1(f)) |expanded| {
        f = expanded;
        ev.repin(f);
    }

    if (f.isCons() and heap.car(f).isSymbol()) {
        const head = symbol_mod.symbol(heap.car(f)).name;
        if (std.mem.eql(u8, head, "PROGN")) {
            var rest = heap.cdr(f);
            while (rest.isCons()) {
                try compileToplevel(ev, heap.car(rest), ctt, out);
                rest = heap.cdr(rest);
            }
            if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
            return;
        }
        if (std.mem.eql(u8, head, "EVAL-WHEN")) {
            const args = heap.cdr(f);
            if (!args.isCons()) return Error.BadArgList;
            const s = try special_forms.parseSituations(ev, heap.car(args));
            const body = heap.cdr(args);
            if (s.load_toplevel) {
                // Body stays top-level; compile-time-too when :compile-toplevel
                // is present, or when :execute meets an already compile-time-too
                // context.
                const new_ctt = s.compile_toplevel or (s.execute and ctt);
                var rest = body;
                while (rest.isCons()) {
                    try compileToplevel(ev, heap.car(rest), new_ctt, out);
                    rest = heap.cdr(rest);
                }
                if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
                return;
            }
            if (s.compile_toplevel or (s.execute and ctt)) {
                var rest = body;
                while (rest.isCons()) {
                    _ = try ev.eval(heap.car(rest));
                    rest = heap.cdr(rest);
                }
                if (!rest.equalsRaw(value.NIL)) return Error.BadArgList;
                return;
            }
            return; // discarded
        }
        if (std.mem.eql(u8, head, "DEFMACRO")) {
            // Macro definitions become available at compile time and are
            // also part of the compiled file.
            _ = try ev.eval(f);
            try keepForLoad(ev, out, f);
            return;
        }
    }

    try keepForLoad(ev, out, f);
    if (ctt) _ = try ev.eval(f);
}

/// Collect a load-time form, pinning it for as long as the caller keeps
/// the list.
fn keepForLoad(ev: *Evaluator, out: *std.ArrayList(Value), f: Value) Error!void {
    try out.append(ev.allocator, f);
    try ev.pin(f);
}

/// Minimal compilation of `source`: process every top-level form, collect
/// the load-time forms into `out`.
pub fn compileSource(ev: *Evaluator, source: []const u8, out: *std.ArrayList(Value)) Error!void {
    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
    rd.read_eval = .{ .context = @ptrCast(ev), .call = &eval_mod.Evaluator.readEval };
    readtables.install(ev, &rd);
    while (true) {
        const form = rd.read() catch return Error.ProgramError;
        const f = form orelse break;
        try compileToplevel(ev, f, false, out);
    }
}

/// `(compile-file "path")` — minimal compilation to a fasl that holds the
/// load-time forms as readable source. Returns the fasl's namestring.
fn compileFileFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const path = try namestringOf(ev.heap.allocator, args[0]);

    const io = ev.io orelse return Error.FileError;
    const source = try readFileAlloc(ev, io, path);
    defer ev.allocator.free(source);

    const truename = truenameOf(ev, io, path) catch return Error.FileError;
    defer ev.allocator.free(truename);

    var load_forms: std.ArrayList(Value) = .empty;
    defer load_forms.deinit(ev.allocator);
    const pin_mark = ev.pinMark();
    defer ev.unpinTo(pin_mark);
    {
        var bindings = try PathVarBindings.bind(
            ev,
            "*COMPILE-FILE-PATHNAME*",
            "*COMPILE-FILE-TRUENAME*",
            path,
            truename,
        );
        defer bindings.restore();
        try compileSource(ev, source, &load_forms);
    }

    const fasl_path = try pathnames.faslPathOf(ev.allocator, path);
    defer ev.allocator.free(fasl_path);
    try writeFasl(ev, io, fasl_path, load_forms.items);
    return ev.heap.allocString(fasl_path);
}

fn writeFasl(ev: *Evaluator, io: std.Io, path: []const u8, forms: []const Value) Error!void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &write_buf);
    const w = &file_writer.interface;
    w.print(";; zisp fasl (readable load-time forms)\n", .{}) catch return Error.FileError;
    for (forms) |f| {
        printer.write(ev.allocator, w, f, format.prin1Settings(ev)) catch return Error.FileError;
        w.writeByte('\n') catch return Error.FileError;
    }
    w.flush() catch return Error.FileError;
}

// --- quit / exit ---

fn quitFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len > 1) return Error.WrongArgCount;
    var code: u8 = 0;
    if (args.len == 1) {
        if (!args[0].isFixnum()) return Error.TypeError;
        const n = args[0].toFixnum();
        if (n < 0 or n > 255) return Error.TypeError;
        code = @intCast(n);
    }
    ev.quit_code = code;
    return Error.Quit;
}
