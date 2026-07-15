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
const reader_mod = @import("../reader.zig");
const eval_mod = @import("../eval/eval.zig");
const special_forms = @import("../eval/special_forms.zig");
const function = @import("../eval/function.zig");

const Value = value.Value;
const Evaluator = eval_mod.Evaluator;
const Error = function.NativeError;

fn evaluator(p: *anyopaque) *Evaluator {
    return Evaluator.fromOpaque(p);
}

pub fn registerSystem(ev: *Evaluator) !void {
    _ = try ev.defineNative("FORMAT", &formatFn);
    _ = try ev.defineNative("LOAD", &loadFn);
    _ = try ev.defineNative("COMPILE-FILE", &compileFileFn);
    _ = try ev.defineNative("QUIT", &quitFn);
    _ = try ev.defineNative("EXIT", &quitFn);

    // `*standard-output*` holds T as a placeholder for the console; the
    // printing builtins treat T as "write to the evaluator's out sink" until
    // real stream objects exist.
    const std_out = try ev.interner.intern("*STANDARD-OUTPUT*");
    symbol_mod.symbol(std_out).value_cell = value.T;

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
        .linux => ":LINUX",
        .macos => ":DARWIN",
        else => ":UNIX",
    };
    const arch_feature = switch (builtin.cpu.arch) {
        .x86_64 => ":X86-64",
        .aarch64 => ":ARM64",
        else => ":UNKNOWN-ARCH",
    };
    const names = [_][]const u8{ ":ZISP", ":ANSI-CL", ":COMMON-LISP", os_feature, arch_feature };

    var list = value.NIL;
    var i: usize = names.len;
    while (i > 0) {
        i -= 1;
        const sym = try ev.interner.intern(names[i]);
        list = try ev.heap.allocCons(sym, list);
    }
    const features = try ev.interner.intern("*FEATURES*");
    symbol_mod.symbol(features).value_cell = list;
}

// --- format ---

fn writesToConsole(dest: Value) bool {
    return dest.equalsRaw(value.T);
}

fn formatFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len < 2) return Error.WrongArgCount;
    const dest = args[0];
    const control = args[1];
    if (control.tag() != .heap or heap.heapType(control) != .string) return Error.TypeError;
    const ctrl = heap.asString(control).constSlice();
    const fmt_args = args[2..];

    if (writesToConsole(dest)) {
        const out = ev.out orelse return Error.NoOutputStream;
        try formatTo(ev, out, ctrl, fmt_args);
        return value.NIL;
    }

    // NIL destination: collect into a fresh string and return it.
    var aw = std.Io.Writer.Allocating.init(ev.allocator);
    defer aw.deinit();
    try formatTo(ev, &aw.writer, ctrl, fmt_args);
    return ev.heap.allocString(aw.written());
}

fn formatTo(ev: *Evaluator, writer: *std.Io.Writer, ctrl: []const u8, fmt_args: []const Value) Error!void {
    var arg_index: usize = 0;
    var i: usize = 0;
    while (i < ctrl.len) : (i += 1) {
        const c = ctrl[i];
        if (c != '~') {
            try writer.writeByte(c);
            continue;
        }
        i += 1;
        if (i >= ctrl.len) return Error.ProgramError;
        switch (std.ascii.toUpper(ctrl[i])) {
            'A' => {
                try printer.princ(ev.allocator, writer, try nextArg(fmt_args, &arg_index));
            },
            'S' => {
                try printer.prin1(ev.allocator, writer, try nextArg(fmt_args, &arg_index));
            },
            'D' => {
                const v = try nextArg(fmt_args, &arg_index);
                if (!v.isFixnum()) return Error.TypeError;
                try writer.print("{d}", .{v.toFixnum()});
            },
            '%' => try writer.writeByte('\n'),
            '&' => try writer.writeByte('\n'),
            '~' => try writer.writeByte('~'),
            else => return Error.ProgramError,
        }
    }
}

fn nextArg(fmt_args: []const Value, idx: *usize) Error!Value {
    if (idx.* >= fmt_args.len) return Error.ProgramError;
    const v = fmt_args[idx.*];
    idx.* += 1;
    return v;
}

// --- load ---

fn loadFn(p: *anyopaque, args: []const Value) Error!Value {
    const ev = evaluator(p);
    if (args.len != 1) return Error.WrongArgCount;
    const path_v = args[0];
    if (path_v.tag() != .heap or heap.heapType(path_v) != .string) return Error.TypeError;
    const path = heap.asString(path_v).constSlice();
    try loadPath(ev, path);
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

/// Saved global cells for a pathname/truename variable pair, rebound for
/// the duration of a load or compile-file.
const PathVarBindings = struct {
    pathname_sym: Value,
    truename_sym: Value,
    old_pathname: Value,
    old_truename: Value,

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
            .pathname_sym = p_sym,
            .truename_sym = t_sym,
            .old_pathname = symbol_mod.symbol(p_sym).value_cell,
            .old_truename = symbol_mod.symbol(t_sym).value_cell,
        };
        symbol_mod.symbol(p_sym).value_cell = try ev.heap.allocString(path);
        symbol_mod.symbol(t_sym).value_cell = try ev.heap.allocString(truename);
        return saved;
    }

    fn restore(self: *PathVarBindings) void {
        symbol_mod.symbol(self.pathname_sym).value_cell = self.old_pathname;
        symbol_mod.symbol(self.truename_sym).value_cell = self.old_truename;
    }
};

/// Read and evaluate every form in `source`, discarding the values.
pub fn evalSource(ev: *Evaluator, source: []const u8) Error!void {
    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
    while (true) {
        const form = rd.read() catch return Error.ProgramError;
        const f = form orelse break;
        _ = try ev.eval(f);
    }
}

// --- compile-file ---

/// Process one top-level form per the CLHS 3.2.3.1 minimal-compilation
/// rules. `ctt` is compile-time-too mode. Forms destined for load time are
/// appended to `out`; compile-time evaluation happens immediately.
pub fn compileToplevel(ev: *Evaluator, form: Value, ctt: bool, out: *std.ArrayList(Value)) Error!void {
    var f = form;
    while (try ev.macroexpand1(f)) |expanded| f = expanded;

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
            try out.append(ev.allocator, f);
            return;
        }
    }

    try out.append(ev.allocator, f);
    if (ctt) _ = try ev.eval(f);
}

/// Minimal compilation of `source`: process every top-level form, collect
/// the load-time forms into `out`.
pub fn compileSource(ev: *Evaluator, source: []const u8, out: *std.ArrayList(Value)) Error!void {
    var tokenizer = reader_mod.Tokenizer.init(source);
    var rd = reader_mod.Reader.init(&tokenizer, ev.heap, ev.interner);
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
    if (args[0].tag() != .heap or heap.heapType(args[0]) != .string) return Error.TypeError;
    const path = heap.asString(args[0]).constSlice();

    const io = ev.io orelse return Error.FileError;
    const source = try readFileAlloc(ev, io, path);
    defer ev.allocator.free(source);

    const truename = truenameOf(ev, io, path) catch return Error.FileError;
    defer ev.allocator.free(truename);

    var load_forms: std.ArrayList(Value) = .empty;
    defer load_forms.deinit(ev.allocator);
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

    const fasl_path = try faslPathOf(ev.allocator, path);
    defer ev.allocator.free(fasl_path);
    try writeFasl(ev, io, fasl_path, load_forms.items);
    return ev.heap.allocString(fasl_path);
}

/// `foo.lisp` compiles to `foo.zfasl`; other names get `.zfasl` appended.
fn faslPathOf(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, path, ".lisp"))
        path[0 .. path.len - ".lisp".len]
    else
        path;
    return std.fmt.allocPrint(allocator, "{s}.zfasl", .{stem});
}

fn writeFasl(ev: *Evaluator, io: std.Io, path: []const u8, forms: []const Value) Error!void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &write_buf);
    const w = &file_writer.interface;
    w.print(";; zisp fasl (readable load-time forms)\n", .{}) catch return Error.FileError;
    for (forms) |f| {
        printer.prin1(ev.allocator, w, f) catch return Error.FileError;
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
