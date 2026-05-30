//! Reader-macro dispatch table.
//!
//! In Common Lisp the reader is character-driven: each character has a
//! syntax type and (for macro characters) an associated reader function.
//! The tokenizer bakes the spec's default syntax into a fast pre-pass,
//! so the dispatch the user can extend lives one layer up — it's keyed on
//! the *reader-macro tokens* the tokenizer emits (`'`, `` ` ``, `,`, `,@`,
//! `#'`, `#(`, `#+`, `#-`).
//!
//! The user-facing `set-macro-character` / `set-dispatch-macro-character`
//! APIs wait for Lisp-callable functions to exist; for now this
//! table holds Zig fn pointers, and the Reader queries it during dispatch.
//! Built-in handlers are populated by `Readtable.initStandard`. Tests can
//! override an entry to verify dispatch goes through the table rather than
//! a hardcoded switch.

const std = @import("std");
const tok = @import("token.zig");
const value = @import("../runtime/value.zig");

const TokenKind = tok.TokenKind;
const Value = value.Value;

/// The Reader is forward-declared here as `*anyopaque` so this module
/// stays free of a circular import with `reader.zig`. Handlers cast back.
pub const HandlerError = error{
    EndOfInput,
    UnbalancedParens,
    BadToken,
} || std.mem.Allocator.Error;

/// Result of one dispatch step. `value` is the form just read; `skipped`
/// means the dispatch consumed input but produced no form (the `#+`/`#-`
/// path uses this to discard a form whose feature test failed). The list
/// and vector readers loop past `skipped`, and so does the top-level
/// `read` driver.
pub const ReadStep = union(enum) {
    value: Value,
    skipped,
};

pub const MacroHandler = *const fn (reader_ctx: *anyopaque) HandlerError!ReadStep;

/// Reader-macro tokens recognized by the tokenizer. Anything outside this
/// list is dispatched directly by the reader (atoms, lists, dot, EOF).
const MACRO_TOKEN_KINDS = [_]TokenKind{
    .quote,
    .backquote,
    .comma,
    .comma_at,
    .hash_quote,
    .hash_lparen,
    .hash_plus,
    .hash_minus,
};

/// Compile-time index of a token kind in `MACRO_TOKEN_KINDS`. Used to size
/// the handler array; non-macro token kinds never index this table.
fn macroIndex(kind: TokenKind) ?usize {
    inline for (MACRO_TOKEN_KINDS, 0..) |k, i| {
        if (k == kind) return i;
    }
    return null;
}

pub const Readtable = struct {
    handlers: [MACRO_TOKEN_KINDS.len]?MacroHandler = .{null} ** MACRO_TOKEN_KINDS.len,

    /// Empty readtable — no macro tokens dispatched. Useful only for tests.
    pub fn init() Readtable {
        return .{};
    }

    /// Standard CL readtable: every reader-macro token gets the built-in
    /// handler from the supplied vtable.
    pub fn initStandard(vtable: StandardHandlers) Readtable {
        var t: Readtable = .{};
        t.set(.quote, vtable.quote);
        t.set(.backquote, vtable.backquote);
        t.set(.comma, vtable.comma);
        t.set(.comma_at, vtable.comma_at);
        t.set(.hash_quote, vtable.hash_quote);
        t.set(.hash_lparen, vtable.hash_lparen);
        t.set(.hash_plus, vtable.hash_plus);
        t.set(.hash_minus, vtable.hash_minus);
        return t;
    }

    pub fn set(self: *Readtable, kind: TokenKind, handler: MacroHandler) void {
        const idx = macroIndex(kind) orelse @panic("not a reader-macro token kind");
        self.handlers[idx] = handler;
    }

    pub fn get(self: *const Readtable, kind: TokenKind) ?MacroHandler {
        const idx = macroIndex(kind) orelse return null;
        return self.handlers[idx];
    }
};

/// Vtable of the built-in reader-macro handlers, supplied by `reader.zig`.
/// Kept as a struct so the reader module can populate it without exposing
/// each function through this file.
pub const StandardHandlers = struct {
    quote: MacroHandler,
    backquote: MacroHandler,
    comma: MacroHandler,
    comma_at: MacroHandler,
    hash_quote: MacroHandler,
    hash_lparen: MacroHandler,
    hash_plus: MacroHandler,
    hash_minus: MacroHandler,
};
