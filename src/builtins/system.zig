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
    _ = try ev.defineNative("QUIT", &quitFn);
    _ = try ev.defineNative("EXIT", &quitFn);

    // `*standard-output*` holds T as a placeholder for the console; the
    // printing builtins treat T as "write to the evaluator's out sink" until
    // real stream objects exist.
    const std_out = try ev.interner.intern("*STANDARD-OUTPUT*");
    symbol_mod.symbol(std_out).value_cell = value.T;

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
/// builtin and by the driver's `--load` / `--script` handling.
pub fn loadPath(ev: *Evaluator, path: []const u8) Error!void {
    const io = ev.io orelse return Error.FileError;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Error.FileError;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &read_buf);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(ev.allocator);
    file_reader.interface.appendRemainingUnlimited(ev.allocator, &source) catch return Error.FileError;

    try evalSource(ev, source.items);
}

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
