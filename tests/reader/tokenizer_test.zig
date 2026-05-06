const std = @import("std");
const zisp = @import("zisp");
const Tokenizer = zisp.reader.Tokenizer;
const Token = zisp.reader.Token;
const TokenKind = zisp.reader.TokenKind;
const Err = zisp.reader.TokenizerError;

fn expectKinds(src: []const u8, kinds: []const TokenKind) !void {
    var t = Tokenizer.init(src);
    for (kinds) |k| {
        const got = try t.next();
        try std.testing.expectEqual(k, got.kind);
    }
    const tail = try t.next();
    try std.testing.expectEqual(TokenKind.eof, tail.kind);
}

fn expectKindAndText(src: []const u8, kind: TokenKind, text: []const u8) !void {
    var t = Tokenizer.init(src);
    const got = try t.next();
    try std.testing.expectEqual(kind, got.kind);
    try std.testing.expectEqualStrings(text, got.text);
}

fn expectError(src: []const u8, want: Err) !void {
    var t = Tokenizer.init(src);
    while (true) {
        const got = t.next() catch |err| {
            try std.testing.expectEqual(want, err);
            return;
        };
        if (got.kind == .eof) break;
    }
    return error.TestExpectedError;
}

// --- 1.1.1 whitespace ----------------------------------------------------

test "empty input yields eof" {
    try expectKinds("", &.{});
}

test "all whitespace skipped" {
    try expectKinds("   \t\n\r\x0c\x0b   ", &.{});
}

test "newline advances line counter" {
    var t = Tokenizer.init("a\nb");
    const a = try t.next();
    try std.testing.expectEqual(@as(u32, 1), a.pos.line);
    const b = try t.next();
    try std.testing.expectEqual(@as(u32, 2), b.pos.line);
    try std.testing.expectEqual(@as(u32, 1), b.pos.column);
}

test "column tracks across whitespace" {
    var t = Tokenizer.init("  hello");
    const tk = try t.next();
    try std.testing.expectEqual(@as(u32, 3), tk.pos.column);
}

// --- 1.1.2 line comments -------------------------------------------------

test "line comment skipped" {
    try expectKinds("; ignore me\n42", &.{.integer});
}

test "line comment at eof without newline" {
    try expectKinds("; trailing", &.{});
}

// --- 1.1.3 block comments with nesting ----------------------------------

test "block comment skipped" {
    try expectKinds("#| ignored |# 7", &.{.integer});
}

test "block comment nests" {
    // The outer `|#` after the inner block's close is what terminates.
    try expectKinds("#| outer #| inner |# still-outer |# 9", &.{.integer});
}

test "block comment with deep nesting" {
    try expectKinds("#|a#|b#|c|#b|#a|#1", &.{.integer});
}

test "unterminated block comment errors" {
    try expectError("#| no end", Err.UnexpectedEndOfInput);
}

test "unterminated nested block comment errors" {
    try expectError("#| outer #| inner |# missing-outer", Err.UnexpectedEndOfInput);
}

// --- 1.1.4 integer literals ---------------------------------------------

test "integer literal" {
    try expectKindAndText("42", .integer, "42");
}

test "negative integer literal" {
    try expectKindAndText("-42", .integer, "-42");
}

test "explicitly positive integer literal" {
    try expectKindAndText("+7", .integer, "+7");
}

test "integer with trailing dot" {
    try expectKindAndText("123.", .integer, "123.");
}

// --- 1.1.5 radix prefixes -----------------------------------------------

test "binary radix #b" {
    try expectKindAndText("#b1010", .integer, "#b1010");
}

test "binary radix #B uppercase" {
    try expectKindAndText("#B1111", .integer, "#B1111");
}

test "octal radix #o" {
    try expectKindAndText("#o755", .integer, "#o755");
}

test "hex radix #x with letters" {
    try expectKindAndText("#xDEADBEEF", .integer, "#xDEADBEEF");
}

test "hex radix with sign" {
    try expectKindAndText("#x-FF", .integer, "#x-FF");
}

test "explicit radix #16r" {
    try expectKindAndText("#16rFF", .integer, "#16rFF");
}

test "explicit radix #36r alphanum" {
    try expectKindAndText("#36rZZ", .integer, "#36rZZ");
}

test "explicit radix uppercase R" {
    try expectKindAndText("#10R12", .integer, "#10R12");
}

test "radix prefix without digits errors" {
    try expectError("#b", Err.BadNumericLiteral);
}

test "explicit radix without digits errors" {
    try expectError("#10R", Err.BadNumericLiteral);
}

test "explicit radix without R-marker errors" {
    try expectError("#10x10", Err.BadNumericLiteral);
}

test "explicit radix below 2 errors" {
    try expectError("#1R0", Err.BadRadix);
}

test "explicit radix above 36 errors" {
    try expectError("#37R0", Err.BadRadix);
}

// --- 1.1.7 ratio literals -----------------------------------------------

test "ratio literal" {
    try expectKindAndText("1/2", .ratio, "1/2");
}

test "negative ratio literal" {
    try expectKindAndText("-3/4", .ratio, "-3/4");
}

test "ratio with decimal point falls through to symbol" {
    // CL's potential-number rules: this isn't a valid ratio shape, so it
    // tokenizes as a symbol.
    try expectKindAndText("1.5/2", .symbol, "1.5/2");
}

test "ratio with exponent letter falls through to symbol" {
    try expectKindAndText("1e2/3", .symbol, "1e2/3");
}

test "1- is a symbol (not a number)" {
    try expectKindAndText("1-", .symbol, "1-");
}

test "1+ is a symbol (not a number)" {
    try expectKindAndText("1+", .symbol, "1+");
}

test "trailing slash falls through to symbol" {
    try expectKindAndText("1/", .symbol, "1/");
}

test "numeric-shaped lexeme with backslash escape is a symbol" {
    // Once any escape appears, the lexeme is a symbol regardless of shape.
    try expectKindAndText("1\\2", .symbol, "1\\2");
}

test "numeric-shaped lexeme with trailing backslash is a symbol" {
    var t = Tokenizer.init("1\\");
    const got = try t.next();
    try std.testing.expectEqual(TokenKind.symbol, got.kind);
    try std.testing.expectEqualStrings("1\\", got.text);
}

// --- 1.1.6 floats are recognized as a lexeme (1.1.6 parses them) --------

test "float with decimal point" {
    try expectKindAndText("1.5", .float, "1.5");
}

test "float with leading dot" {
    try expectKindAndText(".5", .float, ".5");
}

test "float with exponent" {
    try expectKindAndText("1e10", .float, "1e10");
}

test "float with double-float exponent marker" {
    try expectKindAndText("1.5d0", .float, "1.5d0");
}

test "float with single-float exponent marker" {
    try expectKindAndText("1f0", .float, "1f0");
}

// --- 1.1.8 strings -------------------------------------------------------

test "string literal" {
    try expectKindAndText("\"hello\"", .string, "hello");
}

test "string with escaped quote" {
    try expectKindAndText("\"a\\\"b\"", .string, "a\\\"b");
}

test "string with escaped backslash" {
    try expectKindAndText("\"a\\\\b\"", .string, "a\\\\b");
}

test "empty string" {
    try expectKindAndText("\"\"", .string, "");
}

test "unterminated string errors" {
    try expectError("\"oops", Err.UnexpectedEndOfInput);
}

test "string with backslash at eof errors" {
    try expectError("\"oops\\", Err.UnexpectedEndOfInput);
}

// --- 1.1.9 characters ---------------------------------------------------

test "character single ascii" {
    try expectKindAndText("#\\A", .character, "A");
}

test "character named space" {
    try expectKindAndText("#\\Space", .character, "Space");
}

test "character named newline" {
    try expectKindAndText("#\\Newline", .character, "Newline");
}

test "character explicit codepoint" {
    try expectKindAndText("#\\U+03BB", .character, "U+03BB");
}

test "character open paren" {
    try expectKindAndText("#\\(", .character, "(");
}

test "character backslash" {
    try expectKindAndText("#\\\\", .character, "\\");
}

test "character space (the literal space char)" {
    try expectKindAndText("#\\ ", .character, " ");
}

test "character at eof errors" {
    try expectError("#\\", Err.UnexpectedEndOfInput);
}

test "character single digit" {
    // #\3 is the character '3', with the `3` consumed as a one-char "name".
    try expectKindAndText("#\\3", .character, "3");
}

// --- 1.1.10 keywords ----------------------------------------------------

test "keyword bare" {
    try expectKindAndText(":foo", .keyword, "foo");
}

test "keyword with pipe-quoted body" {
    try expectKindAndText(":|Mixed Case|", .keyword, "|Mixed Case|");
}

test "unterminated keyword pipe errors" {
    try expectError(":|oops", Err.UnexpectedEndOfInput);
}

test "keyword pipe with backslash at eof errors" {
    try expectError(":|oops\\", Err.UnexpectedEndOfInput);
}

test "keyword body absorbs internal escape" {
    try expectKindAndText(":foo\\(bar", .keyword, "foo\\(bar");
}

test "keyword pipe body absorbs escaped pipe" {
    try expectKindAndText(":|a\\|b|", .keyword, "|a\\|b|");
}

test "keyword pipe body absorbs escaped backslash" {
    try expectKindAndText(":|a\\\\b|", .keyword, "|a\\\\b|");
}

// --- 1.1.11 symbols, including |escaped| --------------------------------

test "symbol bare" {
    try expectKindAndText("hello", .symbol, "hello");
}

test "symbol with internal punctuation" {
    try expectKindAndText("foo-bar?", .symbol, "foo-bar?");
}

test "symbol just plus" {
    try expectKindAndText("+", .symbol, "+");
}

test "symbol just minus" {
    try expectKindAndText("-", .symbol, "-");
}

test "symbol minus-minus" {
    try expectKindAndText("--", .symbol, "--");
}

test "symbol leading dot" {
    try expectKindAndText(".foo", .symbol, ".foo");
}

test "symbol pipes preserved in text" {
    try expectKindAndText("|Mixed Case|", .symbol, "|Mixed Case|");
}

test "pipe-symbol with embedded escaped pipe" {
    try expectKindAndText("|a\\|b|", .symbol, "|a\\|b|");
}

test "pipe-symbol with embedded escaped backslash" {
    try expectKindAndText("|a\\\\b|", .symbol, "|a\\\\b|");
}

test "unterminated pipe-symbol errors" {
    try expectError("|oops", Err.UnexpectedEndOfInput);
}

test "pipe-symbol backslash at eof errors" {
    try expectError("|oops\\", Err.UnexpectedEndOfInput);
}

test "symbol absorbing internal escape" {
    try expectKindAndText("foo\\;bar", .symbol, "foo\\;bar");
}

test "symbol body trailing backslash at eof" {
    var t = Tokenizer.init("foo\\");
    const got = try t.next();
    try std.testing.expectEqual(TokenKind.symbol, got.kind);
    try std.testing.expectEqualStrings("foo\\", got.text);
}

test "symbol that starts with a digit-then-letter is a symbol" {
    try expectKindAndText("123abc", .symbol, "123abc");
}

test "symbol that mixes exp-letter then non-digit-letter" {
    // '1eX' — 'e' is an exp marker but 'X' isn't a digit; this is a symbol.
    try expectKindAndText("1eX", .symbol, "1eX");
}

// --- structural and reader-macro chars ----------------------------------

test "parens" {
    try expectKinds("()", &.{ .lparen, .rparen });
}

test "quote" {
    try expectKinds("'x", &.{ .quote, .symbol });
}

test "backquote" {
    try expectKinds("`x", &.{ .backquote, .symbol });
}

test "comma" {
    try expectKinds(",x", &.{ .comma, .symbol });
}

test "comma-at" {
    try expectKinds(",@x", &.{ .comma_at, .symbol });
}

test "hash quote (function shortcut)" {
    try expectKinds("#'x", &.{ .hash_quote, .symbol });
}

test "hash lparen (vector literal)" {
    try expectKinds("#(1 2)", &.{ .hash_lparen, .integer, .integer, .rparen });
}

test "hash plus feature expr" {
    try expectKinds("#+sbcl x", &.{ .hash_plus, .symbol, .symbol });
}

test "hash minus feature expr" {
    try expectKinds("#-windows x", &.{ .hash_minus, .symbol, .symbol });
}

test "bare dot" {
    try expectKinds("(a . b)", &.{ .lparen, .symbol, .dot, .symbol, .rparen });
}

test "dot at eof is a dot token" {
    try expectKinds(".", &.{.dot});
}

test "hash with no body errors" {
    try expectError("#", Err.BadDispatchChar);
}

test "hash unknown dispatch errors" {
    try expectError("#$", Err.BadDispatchChar);
}

// --- mixed-form integration --------------------------------------------

test "small program tokenizes" {
    const src = "(defun fact (n) (if (zerop n) 1 (* n (fact (1- n)))))";
    try expectKinds(src, &.{
        .lparen,  .symbol, .symbol, .lparen, .symbol, .rparen,
        .lparen,  .symbol, .lparen, .symbol, .symbol, .rparen,
        .integer, .lparen, .symbol, .symbol, .lparen, .symbol,
        .lparen,  .symbol, .symbol, .rparen, .rparen, .rparen,
        .rparen,  .rparen,
    });
}

test "comments and forms interleave" {
    const src =
        \\;; top
        \\(a #| inline |# b)
        \\;; trailing
    ;
    try expectKinds(src, &.{ .lparen, .symbol, .symbol, .rparen });
}

test "byte_offset records source position" {
    var t = Tokenizer.init("  42");
    const tk = try t.next();
    try std.testing.expectEqual(@as(u32, 2), tk.pos.byte_offset);
}
