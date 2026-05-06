//! Common Lisp float-lexeme parser (ROADMAP Phase 1.1.6).
//!
//! The tokenizer recognizes a float as a lexeme but doesn't compute its
//! numeric value. This module turns the lexeme into a typed `f32`/`f64`
//! using IEEE 754 round-to-nearest-even — bitwise-identical to SBCL's
//! reader for the `tests/lisp/float-literal-corpus.lisp` corpus.
//!
//! Exponent marker → result type:
//!   no marker      → single (per `*read-default-float-format*` default)
//!   `e` / `E`      → single (default float format)
//!   `s` / `S`      → single (short — Lisp permits short = single)
//!   `f` / `F`      → single
//!   `d` / `D`      → double
//!   `l` / `L`      → double (long — Lisp permits long = double)
//!
//! `*read-default-float-format*` is fixed at `single-float` for Phase 1.
//! 4.6.x will let user code rebind it; this parser will read that variable
//! when the dynamic-bindings substrate lands.

const std = @import("std");

pub const FloatType = enum { single, double };

pub const FloatValue = union(FloatType) {
    single: f32,
    double: f64,
};

pub const Error = error{
    /// Lexeme didn't match a CL float shape, was empty, or held an
    /// unexpected character. The tokenizer's classifier should reject
    /// these before we see them, but we validate defensively.
    BadFloatLexeme,
};

/// Maximum lexeme length we accept. Real-world float lexemes are well
/// under 64 bytes; the cap keeps the parser stack-only.
const MAX_LEXEME: usize = 128;

/// Parse a tokenizer-classified float lexeme.
///
/// Caller passes the exact `text` slice the tokenizer captured (no
/// trimming). The function copies into a stack buffer so it can rewrite
/// the exponent marker to `e` for `std.fmt.parseFloat`.
pub fn parseFloatLexeme(text: []const u8) Error!FloatValue {
    if (text.len == 0 or text.len > MAX_LEXEME) return Error.BadFloatLexeme;

    var buf: [MAX_LEXEME]u8 = undefined;
    @memcpy(buf[0..text.len], text);

    // Walk the lexeme to find the exponent marker (the sole letter
    // permitted inside a float). Anything before the marker is mantissa
    // material the std parser handles directly. Anything after is the
    // signed-integer exponent.
    var float_type: FloatType = .single;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isAlphabetic(c)) {
            float_type = switch (c) {
                'e', 'E', 's', 'S', 'f', 'F' => .single,
                'd', 'D', 'l', 'L' => .double,
                else => return Error.BadFloatLexeme,
            };
            buf[i] = 'e';
            break;
        }
    }

    const slice = buf[0..text.len];
    return switch (float_type) {
        .single => .{
            .single = std.fmt.parseFloat(f32, slice) catch return Error.BadFloatLexeme,
        },
        .double => .{
            .double = std.fmt.parseFloat(f64, slice) catch return Error.BadFloatLexeme,
        },
    };
}
