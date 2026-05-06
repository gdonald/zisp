const std = @import("std");

/// Source position. Lines and columns are 1-based; byte_offset is 0-based.
pub const Position = struct {
    line: u32 = 1,
    column: u32 = 1,
    byte_offset: u32 = 0,
};

pub const TokenKind = enum {
    // Structural
    lparen,
    rparen,
    dot,

    // Reader macro single chars
    quote, // '
    backquote, // `
    comma, // ,
    comma_at, // ,@

    // # dispatch
    hash_quote, // #'
    hash_lparen, // #(
    hash_plus, // #+
    hash_minus, // #-

    // Literals
    integer, // text holds the digit run (with optional sign / radix prefix)
    ratio, // text is "<num>/<denom>"; both halves may be signed
    float, // 1.1.6 lands the parser; tokenizer recognizes the lexeme
    string, // text excludes surrounding quotes; \\ and \" escapes still raw
    character, // text excludes the leading "#\"; reader resolves the name
    symbol, // text holds the printed name (case-folded if not |..|-quoted)
    keyword, // leading ':' stripped from text

    eof,
};

pub const Token = struct {
    kind: TokenKind,
    pos: Position,
    /// Slice of the original source covered by the token's payload, lifetime
    /// tied to the source buffer the tokenizer borrowed. The tokenizer never
    /// allocates; case folding, escape processing, and numeric parsing all
    /// happen in the reader (Phase 1.2). For each kind:
    ///   integer — the digits, with optional sign and radix prefix
    ///   ratio — "num/denom", either half optionally signed
    ///   float — the full lexeme; parsing waits for 1.1.6
    ///   string — between the quotes, escapes still raw
    ///   character — after the "#\\", e.g. "Space" or "A" or "U+03BB"
    ///   symbol — the printed name as it appeared, pipes included if any
    ///   keyword — after the leading ':'
    ///   structural / reader-macro tokens — the source covering the token
    text: []const u8,
};
