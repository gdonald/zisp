//! Read-eval-print loop.
//!
//! The core driver reads every complete form from a source buffer, evaluates
//! each in turn, prints the primary value, and maintains the standard REPL
//! history variables. `run` may be called repeatedly; evaluator state and
//! history persist across calls, so an interactive driver can feed one line
//! at a time. The interactive stdin/stdout wiring lives in `main.zig`; this
//! module is exercised directly by the test suite with string input and a
//! captured writer.
//!
//! `run` reads its forms through the console stream, so the debugger an
//! error enters reads on from the same input with `read`.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const reader_mod = @import("../reader.zig");
const collect_mod = @import("../eval/collect.zig");
const eval_pkg = @import("../eval.zig");
const builtins = @import("../builtins/builtins.zig");
const readtables = @import("../builtins/readtables.zig");
const system = builtins.system;
const streams = @import("../builtins/streams.zig");
const format = @import("../builtins/format.zig");

const Value = value.Value;
const Evaluator = eval_pkg.Evaluator;
const NativeError = eval_pkg.eval.Error;

/// Errors surfaced by the loop itself: anything the evaluator can raise plus
/// failures from the output writer.
pub const Error = NativeError || std.Io.Writer.Error;

const ABORT_MSG = ";; Aborted.\n";

pub const Repl = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    interner: symbol_mod.Interner,
    heap: heap_mod.Heap,
    ev: Evaluator,
    out: *std.Io.Writer,

    minus: Value,
    plus: Value,
    plus2: Value,
    plus3: Value,
    star: Value,
    star2: Value,
    star3: Value,

    pub fn init(gpa: std.mem.Allocator, out: *std.Io.Writer, io: ?std.Io) !*Repl {
        return initFrom(gpa, out, io, null);
    }

    /// A REPL whose session starts from the image at `image_path`, or
    /// from the boot sources when there is none.
    pub fn initFrom(gpa: std.mem.Allocator, out: *std.Io.Writer, io: ?std.Io, image_path: ?[]const u8) !*Repl {
        const self = try gpa.create(Repl);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .interner = try symbol_mod.Interner.init(gpa),
            .heap = undefined,
            .ev = undefined,
            .out = out,
            .minus = value.NIL,
            .plus = value.NIL,
            .plus2 = value.NIL,
            .plus3 = value.NIL,
            .star = value.NIL,
            .star2 = value.NIL,
            .star3 = value.NIL,
        };
        try symbol_mod.initStandardSymbols(&self.interner);
        self.heap = heap_mod.Heap.init(self.arena.allocator());
        self.ev = Evaluator.init(gpa, &self.heap, &self.interner);
        self.ev.out = out;
        self.ev.io = io;
        try eval_pkg.registerStandardSpecialForms(&self.ev);
        if (image_path) |path| {
            try builtins.registerNatives(&self.ev);
            try builtins.registerSystem(&self.ev);
            try builtins.image.loadPath(&self.ev, path);
        } else {
            try builtins.registerStandard(&self.ev);
            try builtins.registerSystem(&self.ev);
        }

        self.minus = try self.interner.intern("-");
        self.plus = try self.interner.intern("+");
        self.plus2 = try self.interner.intern("++");
        self.plus3 = try self.interner.intern("+++");
        self.star = try self.interner.intern("*");
        self.star2 = try self.interner.intern("**");
        self.star3 = try self.interner.intern("***");
        for ([_]Value{ self.minus, self.plus, self.plus2, self.plus3, self.star, self.star2, self.star3 }) |sym| {
            symbol_mod.symbol(sym).value_cell = value.NIL;
        }
        return self;
    }

    pub fn deinit(self: *Repl) void {
        self.ev.deinit();
        self.interner.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Read, evaluate, and print every complete form in `source`.
    pub fn run(self: *Repl, source: []const u8) Error!void {
        const console = try self.consoleInput();
        console.input = source;
        console.position = 0;
        console.pending = null;
        const interactive = try self.interner.intern("*%INTERACTIVE-DEBUGGER*");
        const was_interactive = getVal(interactive);
        setVal(interactive, value.T);
        defer {
            setVal(interactive, was_interactive);
            if (self.consoleInput()) |left| {
                left.input = &.{};
                left.position = 0;
            } else |_| {}
        }

        while (true) {
            try collect_mod.maybeCollect(&self.ev);
            const form = system.readStreamForm(&self.ev, value.T) catch |e| {
                try self.reportError("Reader", e);
                return;
            };
            const f = form orelse break;
            self.rotateInput(f);
            const result = self.evalWithAbort(f) catch |e| {
                if (e == error.Quit) return;
                const debugged = self.debugFailure(e) catch |nested| {
                    if (nested == error.Quit) return;
                    try self.reportError("Error", nested);
                    continue;
                };
                if (!debugged) try self.writeLine(ABORT_MSG);
                continue;
            } orelse {
                try self.writeLine(ABORT_MSG);
                continue;
            };
            self.rotateOutput(result);
            try self.printResult(result);
        }
    }

    /// The console stream, whose input `run` reads forms from.
    fn consoleInput(self: *Repl) Error!*heap_mod.HeapStream {
        return streams.streamOf(&self.ev, value.T, .input);
    }

    /// Enter the debugger for a failure that unwound to the top level
    /// before one could be entered. False when it was left through
    /// `abort`.
    fn debugFailure(self: *Repl, e: Error) Error!bool {
        const caught = if (self.ev.error_condition.raw != 0)
            self.ev.error_condition
        else
            try self.interner.internKeyword(@errorName(e));
        self.ev.error_condition = .{ .raw = 0 };
        const debugger = self.ev.env.lookupFunction(try self.interner.intern("%DEBUG-TOP-LEVEL-FAILURE")).?;
        const outcome = try self.ev.callFunction(debugger, &.{caught});
        self.ev.error_datum = .{ .raw = 0 };
        return !outcome.equalsRaw(value.NIL);
    }

    /// Read every form in `source`, evaluate each, and (when `print` is set)
    /// print its primary value. Unlike `run`, an evaluation error is not
    /// caught: it propagates so the batch driver can choose an exit code.
    /// Used by `--eval` (print) and `--load` (no print).
    pub fn evalForms(self: *Repl, source: []const u8, print: bool) Error!void {
        var tokenizer = reader_mod.Tokenizer.init(source);
        var rd = reader_mod.Reader.init(&tokenizer, &self.heap, &self.interner);
        rd.read_eval = .{ .context = @ptrCast(&self.ev), .call = &eval_pkg.Evaluator.readEval };
        readtables.install(&self.ev, &rd);
        while (true) {
            try collect_mod.maybeCollect(&self.ev);
            const form = rd.read() catch return Error.ProgramError;
            const f = form orelse break;
            self.rotateInput(f);
            const result = try self.ev.evalTopLevel(f);
            self.rotateOutput(result);
            if (print) try self.printResult(result);
        }
    }

    /// Read and evaluate every form in the file at `path`, discarding values.
    pub fn loadFile(self: *Repl, path: []const u8) Error!void {
        try builtins.system.loadPath(&self.ev, path);
    }

    /// Evaluate `form` under an `abort` restart. Null when the restart
    /// was invoked.
    fn evalWithAbort(self: *Repl, form: Value) Error!?Value {
        const runner = self.ev.env.lookupFunction(try self.interner.intern("%EVAL-WITH-ABORT")) orelse
            return try self.ev.evalTopLevel(form);
        const completed = try self.ev.callFunction(runner, &.{form});
        if (completed.equalsRaw(value.NIL)) return null;
        return self.ev.values.items[1];
    }

    fn rotateInput(self: *Repl, form: Value) void {
        setVal(self.plus3, getVal(self.plus2));
        setVal(self.plus2, getVal(self.plus));
        setVal(self.plus, getVal(self.minus));
        setVal(self.minus, form);
    }

    fn rotateOutput(self: *Repl, result: Value) void {
        setVal(self.star3, getVal(self.star2));
        setVal(self.star2, getVal(self.star));
        setVal(self.star, result);
    }

    fn printResult(self: *Repl, result: Value) Error!void {
        printer.write(self.gpa, self.out, result, format.prin1Settings(&self.ev)) catch |e|
            return self.ev.printFailure(e);
        try self.writeLine("\n");
    }

    fn reportError(self: *Repl, label: []const u8, e: anyerror) Error!void {
        try self.out.print(";; {s}: {s}", .{ label, @errorName(e) });
        try self.writeLine("\n");
    }

    /// Write `text`, which ends a line, so `fresh-line` knows the next
    /// output starts at the left margin.
    fn writeLine(self: *Repl, text: []const u8) Error!void {
        try self.out.writeAll(text);
        self.ev.output_column = 0;
    }
};

fn setVal(sym: Value, v: Value) void {
    symbol_mod.symbol(sym).value_cell = v;
}

fn getVal(sym: Value) Value {
    return symbol_mod.symbol(sym).value_cell;
}
