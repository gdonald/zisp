//! Read-eval-print loop.
//!
//! The core driver reads every complete form from a source buffer, evaluates
//! each in turn, prints the primary value, and maintains the standard REPL
//! history variables. `run` may be called repeatedly; evaluator state and
//! history persist across calls, so an interactive driver can feed one line
//! at a time. The interactive stdin/stdout wiring lives in `main.zig`; this
//! module is exercised directly by the test suite with string input and a
//! captured writer.

const std = @import("std");
const value = @import("../runtime/value.zig");
const heap_mod = @import("../runtime/heap.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const printer = @import("../runtime/printer.zig");
const reader_mod = @import("../reader.zig");
const eval_pkg = @import("../eval.zig");
const builtins = @import("../builtins/builtins.zig");

const Value = value.Value;
const Evaluator = eval_pkg.Evaluator;
const NativeError = eval_pkg.eval.Error;

/// Errors surfaced by the loop itself: anything the evaluator can raise plus
/// failures from the output writer.
pub const Error = NativeError || std.Io.Writer.Error;

const BREAK_MSG = ";; Entering break loop. :abort or :continue to resume.\n";
const RESUME_MSG = ";; Resuming top level.\n";

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
        const self = try gpa.create(Repl);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .interner = symbol_mod.Interner.init(gpa),
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
        try builtins.registerStandard(&self.ev);
        try builtins.registerSystem(&self.ev);

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
        var tokenizer = reader_mod.Tokenizer.init(source);
        var rd = reader_mod.Reader.init(&tokenizer, &self.heap, &self.interner);
        while (true) {
            const form = rd.read() catch |e| {
                try self.reportError("Reader", e);
                return;
            };
            const f = form orelse break;
            self.rotateInput(f);
            const result = self.ev.eval(f) catch |e| {
                if (e == error.Quit) return;
                try self.reportError("Error", e);
                try self.breakLoop(&rd);
                continue;
            };
            self.rotateOutput(result);
            try self.printResult(result);
        }
    }

    /// Read every form in `source`, evaluate each, and (when `print` is set)
    /// print its primary value. Unlike `run`, an evaluation error is not
    /// caught: it propagates so the batch driver can choose an exit code.
    /// Used by `--eval` (print) and `--load` (no print).
    pub fn evalForms(self: *Repl, source: []const u8, print: bool) Error!void {
        var tokenizer = reader_mod.Tokenizer.init(source);
        var rd = reader_mod.Reader.init(&tokenizer, &self.heap, &self.interner);
        while (true) {
            const form = rd.read() catch return Error.ProgramError;
            const f = form orelse break;
            self.rotateInput(f);
            const result = try self.ev.eval(f);
            self.rotateOutput(result);
            if (print) try self.printResult(result);
        }
    }

    /// Read and evaluate every form in the file at `path`, discarding values.
    pub fn loadFile(self: *Repl, path: []const u8) Error!void {
        try builtins.system.loadPath(&self.ev, path);
    }

    /// Minimal break loop entered after an evaluation error. Reads forms and
    /// evaluates them in a nested context; `:abort` or `:continue` resumes the
    /// top level. End of input also resumes. The full condition-driven version
    /// arrives with the condition system.
    fn breakLoop(self: *Repl, rd: *reader_mod.Reader) Error!void {
        try self.out.writeAll(BREAK_MSG);
        while (true) {
            const form = rd.read() catch |e| {
                try self.reportError("Reader", e);
                return;
            };
            const f = form orelse return;
            if (isResumeCommand(f)) {
                try self.out.writeAll(RESUME_MSG);
                return;
            }
            self.rotateInput(f);
            const result = self.ev.eval(f) catch |e| {
                if (e == error.Quit) return;
                try self.reportError("Error", e);
                continue;
            };
            self.rotateOutput(result);
            try self.printResult(result);
        }
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
        try printer.prin1(self.gpa, self.out, result);
        try self.out.writeByte('\n');
    }

    fn reportError(self: *Repl, label: []const u8, e: anyerror) Error!void {
        try self.out.print(";; {s}: {s}\n", .{ label, @errorName(e) });
    }
};

fn setVal(sym: Value, v: Value) void {
    symbol_mod.symbol(sym).value_cell = v;
}

fn getVal(sym: Value) Value {
    return symbol_mod.symbol(sym).value_cell;
}

fn isResumeCommand(form: Value) bool {
    if (!form.isSymbol()) return false;
    const name = symbol_mod.symbol(form).name;
    return std.mem.eql(u8, name, ":ABORT") or std.mem.eql(u8, name, ":CONTINUE");
}
