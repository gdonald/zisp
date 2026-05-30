//! Reader-only sweep helper.
//!
//! Drives a fresh reader through every form in a source buffer and
//! returns either a count or the position of the first failure. The
//! `--read-only` CLI mode wraps this with file I/O; the test suite
//! exercises it directly so the parsing path stays in coverage even
//! though main.zig isn't part of the test binary.

const std = @import("std");
const reader_mod = @import("../reader.zig");
const heap_mod = @import("heap.zig");
const symbol = @import("symbol.zig");
const source_pos = @import("source_pos.zig");

const Tokenizer = reader_mod.Tokenizer;
const Reader = reader_mod.Reader;
const Heap = heap_mod.Heap;
const Interner = symbol.Interner;
const SourcePosition = source_pos.SourcePosition;

pub const ReadAllError = reader_mod.ReaderError;

pub const Outcome = union(enum) {
    /// Every form parsed; `forms` is the count.
    ok: u32,
    /// First failure: `err` is the reader error, `pos` is where it
    /// happened (may have a zero line/column if even the position
    /// fallback didn't fire), `forms` is the number of clean forms
    /// before the failure.
    fail: struct {
        err: ReadAllError,
        pos: SourcePosition,
        forms: u32,
    },
};

/// Read every top-level form in `source` using a fresh reader.
/// Allocator backs the heap (cons cells, strings) and the interner
/// (symbol arena). Caller owns the inputs.
pub fn parseAll(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) !Outcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var heap_inst = Heap.init(arena.allocator());
    var interner = Interner.init(allocator);
    defer interner.deinit();
    try symbol.initStandardSymbols(&interner);

    var tk = Tokenizer.init(source);
    var rd = Reader.initFull(
        &tk,
        &heap_inst,
        &interner,
        reader_mod.reader.defaultReadtable(),
        null,
        file_name,
    );

    var forms: u32 = 0;
    while (true) {
        const v = rd.read() catch |e| {
            const pos = rd.lastErrorPos() orelse SourcePosition{
                .file = file_name,
                .line = 0,
                .column = 0,
            };
            return .{ .fail = .{ .err = e, .pos = pos, .forms = forms } };
        };
        if (v == null) break;
        forms += 1;
    }
    return .{ .ok = forms };
}
