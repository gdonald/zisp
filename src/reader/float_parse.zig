//! Common Lisp float-lexeme parser.
//!
//! The reader recognizes a float as a lexeme but doesn't compute its
//! numeric value. This module turns the lexeme into a typed `f32`/`f64`
//! using IEEE 754 round-to-nearest-even — bitwise-identical to SBCL's
//! reader for the `tests/lisp/float-literal-corpus.lisp` corpus.
//!
//! Exponent marker → result type:
//!   no marker      → the default format the caller passes
//!   `e` / `E`      → the default format the caller passes
//!   `s` / `S`      → single (short — Lisp permits short = single)
//!   `f` / `F`      → single
//!   `d` / `D`      → double
//!   `l` / `L`      → double (long — Lisp permits long = double)

const std = @import("std");

pub const FloatType = enum { single, double };

pub const FloatValue = union(FloatType) {
    single: f32,
    double: f64,
};

pub const Error = error{
    /// Lexeme didn't match a CL float shape, was empty, or held an
    /// unexpected character.
    BadFloatLexeme,
};

/// The longest lexeme `parseFloatLexemeAs` takes, which keeps it free of
/// an allocator. `parseFloatInto` takes any length.
const MAX_LEXEME: usize = 128;

/// Parse a float lexeme. The text is copied into a stack buffer so the
/// exponent marker can be rewritten to `e` for `std.fmt.parseFloat`.
pub fn parseFloatLexeme(text: []const u8) Error!FloatValue {
    return parseFloatLexemeAs(text, .single);
}

/// Parse a float lexeme, reading one with no marker or an `e` marker as
/// `default`, which is what `*read-default-float-format*` names.
pub fn parseFloatLexemeAs(text: []const u8, default: FloatType) Error!FloatValue {
    if (text.len > MAX_LEXEME) return Error.BadFloatLexeme;
    var buf: [MAX_LEXEME]u8 = undefined;
    return parseFloatInto(&buf, text, default);
}

/// `parseFloatLexemeAs` with `buf`, at least as long as `text`, to
/// rewrite the exponent marker in.
pub fn parseFloatInto(buf: []u8, text: []const u8, default: FloatType) Error!FloatValue {
    if (text.len == 0 or text.len > buf.len) return Error.BadFloatLexeme;
    @memcpy(buf[0..text.len], text);

    // Walk the lexeme to find the exponent marker (the sole letter
    // permitted inside a float). Anything before the marker is mantissa
    // material the std parser handles directly. Anything after is the
    // signed-integer exponent.
    var float_type: FloatType = default;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isAlphabetic(c)) {
            float_type = switch (c) {
                'e', 'E' => default,
                's', 'S', 'f', 'F' => .single,
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
