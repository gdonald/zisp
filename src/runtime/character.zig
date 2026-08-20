//! Character names and classification.
//!
//! The reader, the printer and the character builtins all need the same
//! answers, so the tables live here rather than in three places.
//!
//! Simple case mapping covers the Latin, Greek and Cyrillic blocks, and
//! full case mapping adds the `SpecialCasing.txt` rows where one character
//! maps to several. Characters outside those blocks are left alone.

const std = @import("std");

pub const CODE_LIMIT: u21 = 0x110000;

const Named = struct { name: []const u8, code: u21 };

/// The character names CLHS requires, in the order `char-name` prefers
/// when several spell the same code.
const NAMES = [_]Named{
    .{ .name = "Null", .code = 0 },
    .{ .name = "Backspace", .code = 8 },
    .{ .name = "Tab", .code = 9 },
    .{ .name = "Newline", .code = 10 },
    .{ .name = "Page", .code = 12 },
    .{ .name = "Return", .code = 13 },
    .{ .name = "Space", .code = ' ' },
    .{ .name = "Rubout", .code = 0x7F },
};

/// Names accepted on input that are not the preferred spelling.
const ALIASES = [_]Named{
    .{ .name = "Linefeed", .code = 10 },
};

pub fn codeForName(name: []const u8) ?u21 {
    for (NAMES) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.code;
    }
    for (ALIASES) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry.code;
    }
    return null;
}

pub fn nameForCode(code: u21) ?[]const u8 {
    for (NAMES) |entry| {
        if (entry.code == code) return entry.name;
    }
    return null;
}

// --- case mapping ---

/// True for the Latin-1 letters, which are the accented range with the
/// two multiplication and division signs punched out.
fn isLatin1Letter(c: u21) bool {
    if (c == 0xAA or c == 0xB5 or c == 0xBA) return true;
    return c >= 0xC0 and c <= 0xFF and c != 0xD7 and c != 0xF7;
}

/// Characters whose simple mapping no range rule describes. The two
/// directions are listed separately because several of these are not
/// symmetric: two Greek sigmas share one capital, and dotted capital I
/// lowercases to plain i while plain i uppercases to plain I.
const Mapping = struct { from: u21, to: u21 };

const UPPERCASE_OF = [_]Mapping{
    // Small y with diaeresis: the one Latin-1 letter whose uppercase lies
    // outside the block.
    .{ .from = 0xFF, .to = 0x178 },
    // Dotless i uppercases to plain I, which is the Turkish pairing and
    // also the default one.
    .{ .from = 0x131, .to = 'I' },
    .{ .from = 0x17F, .to = 'S' },
    .{ .from = 0x3C2, .to = 0x3A3 },
    .{ .from = 0x3C3, .to = 0x3A3 },
    .{ .from = 0x3AC, .to = 0x386 },
    .{ .from = 0x3AD, .to = 0x388 },
    .{ .from = 0x3AE, .to = 0x389 },
    .{ .from = 0x3AF, .to = 0x38A },
    .{ .from = 0x3CA, .to = 0x3AA },
    .{ .from = 0x3CB, .to = 0x3AB },
    .{ .from = 0x3CC, .to = 0x38C },
    .{ .from = 0x3CD, .to = 0x38E },
    .{ .from = 0x3CE, .to = 0x38F },
};

const LOWERCASE_OF = [_]Mapping{
    .{ .from = 0x178, .to = 0xFF },
    // Dotted capital I lowercases to plain i here. Turkish maps it to
    // dotless i instead, and the full mapping keeps the dot as a
    // combining mark.
    .{ .from = 0x130, .to = 'i' },
    // The Kelvin and Angstrom signs lowercase onto ordinary letters.
    .{ .from = 0x212A, .to = 'k' },
    .{ .from = 0x212B, .to = 0xE5 },
    .{ .from = 0x386, .to = 0x3AC },
    .{ .from = 0x388, .to = 0x3AD },
    .{ .from = 0x389, .to = 0x3AE },
    .{ .from = 0x38A, .to = 0x3AF },
    .{ .from = 0x38C, .to = 0x3CC },
    .{ .from = 0x38E, .to = 0x3CD },
    .{ .from = 0x38F, .to = 0x3CE },
    .{ .from = 0x3AA, .to = 0x3CA },
    .{ .from = 0x3AB, .to = 0x3CB },
};

fn lookup(table: []const Mapping, c: u21) ?u21 {
    for (table) |entry| {
        if (entry.from == c) return entry.to;
    }
    return null;
}

/// Latin Extended-A runs in even/odd pairs, but the parity flips twice
/// inside the block.
fn latinExtendedAPair(c: u21) ?Mapping {
    if (c < 0x100 or c > 0x17F) return null;
    // Letters with no partner, or one the tables above already cover.
    if (c == 0x130 or c == 0x131 or c == 0x138 or c == 0x149 or c == 0x17F) return null;
    const even_is_upper = (c >= 0x100 and c <= 0x137) or (c >= 0x14A and c <= 0x177);
    const upper = if (even_is_upper) c & ~@as(u21, 1) else ((c - 1) | 1);
    return .{ .from = upper + 1, .to = upper };
}

pub fn upcase(c: u21) u21 {
    if (c >= 'a' and c <= 'z') return c - 0x20;
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 0x20;
    if (lookup(&UPPERCASE_OF, c)) |mapped| return mapped;
    if (latinExtendedAPair(c)) |pair| {
        if (pair.from == c) return pair.to;
        return c;
    }
    // Greek and Cyrillic each run as a block of pairs.
    if (c >= 0x3B1 and c <= 0x3C9) return c - 0x20;
    if (c >= 0x430 and c <= 0x44F) return c - 0x20;
    if (c >= 0x450 and c <= 0x45F) return c - 0x50;
    return c;
}

pub fn downcase(c: u21) u21 {
    if (c >= 'A' and c <= 'Z') return c + 0x20;
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 0x20;
    if (lookup(&LOWERCASE_OF, c)) |mapped| return mapped;
    if (latinExtendedAPair(c)) |pair| {
        if (pair.to == c) return pair.from;
        return c;
    }
    if (c >= 0x391 and c <= 0x3A9) return c + 0x20;
    if (c >= 0x410 and c <= 0x42F) return c + 0x20;
    if (c >= 0x400 and c <= 0x40F) return c + 0x50;
    return c;
}

pub fn isAlpha(c: u21) bool {
    if (c < 128) return std.ascii.isAlphabetic(@intCast(c));
    if (isLatin1Letter(c)) return true;
    // A character the case tables know about is a letter by construction.
    if (upcase(c) != c or downcase(c) != c) return true;
    return false;
}

/// An uppercase character is an alphabetic one that changes under
/// `downcase`, and the reverse for lowercase.
pub fn isUpper(c: u21) bool {
    return isAlpha(c) and downcase(c) != c;
}

pub fn isLower(c: u21) bool {
    return isAlpha(c) and upcase(c) != c;
}

pub fn isBothCase(c: u21) bool {
    return isUpper(c) or isLower(c);
}

/// The weight of `c` as a digit in `radix`, or null when it is not one.
pub fn digitWeight(c: u21, radix: u8) ?u8 {
    const weight: u8 = switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'z' => @intCast(c - 'a' + 10),
        'A'...'Z' => @intCast(c - 'A' + 10),
        else => return null,
    };
    if (weight >= radix) return null;
    return weight;
}

/// The character standing for `weight` in `radix`, uppercase past nine.
pub fn digitChar(weight: u8, radix: u8) ?u21 {
    if (weight >= radix) return null;
    if (weight < 10) return '0' + @as(u21, weight);
    return 'A' + @as(u21, weight - 10);
}

pub fn isAlphanumeric(c: u21) bool {
    return isAlpha(c) or digitWeight(c, 10) != null;
}

/// A graphic character is one with a printed glyph. The two control
/// blocks are the exceptions, and space counts as graphic.
pub fn isGraphic(c: u21) bool {
    if (c < 0x20 or c == 0x7F) return false;
    if (c >= 0x80 and c <= 0x9F) return false;
    return true;
}

pub fn isStandard(c: u21) bool {
    return c == '\n' or (c >= 0x20 and c <= 0x7E);
}

// --- full case mapping ---

/// Up to three characters, which is the longest expansion in
/// `SpecialCasing.txt`.
pub const Expansion = struct {
    codes: [3]u21,
    len: u8,

    fn one(c: u21) Expansion {
        return .{ .codes = .{ c, 0, 0 }, .len = 1 };
    }

    fn two(a: u21, b: u21) Expansion {
        return .{ .codes = .{ a, b, 0 }, .len = 2 };
    }

    fn three(a: u21, b: u21, c: u21) Expansion {
        return .{ .codes = .{ a, b, c }, .len = 3 };
    }

    pub fn slice(self: *const Expansion) []const u21 {
        return self.codes[0..self.len];
    }
};

const FullEntry = struct { code: u21, to: Expansion };

/// The `SpecialCasing.txt` rows where uppercasing one character produces
/// several. Zig's standard library has no case tables at all, so every one
/// of these is carried here.
const FULL_UPPER = [_]FullEntry{
    // Latin small letter sharp s.
    .{ .code = 0xDF, .to = Expansion.two('S', 'S') },
    // Latin small letter n preceded by apostrophe.
    .{ .code = 0x149, .to = Expansion.two(0x2BC, 'N') },
    // Latin small letter j with caron.
    .{ .code = 0x1F0, .to = Expansion.two('J', 0x30C) },
    // Greek small letter iota with dialytika and tonos.
    .{ .code = 0x390, .to = Expansion.three(0x399, 0x308, 0x301) },
    // Greek small letter upsilon with dialytika and tonos.
    .{ .code = 0x3B0, .to = Expansion.three(0x3A5, 0x308, 0x301) },
    // Armenian small ligature ech yiwn.
    .{ .code = 0x587, .to = Expansion.two(0x535, 0x552) },
    // Latin small letters with a combining mark and no precomposed upper.
    .{ .code = 0x1E96, .to = Expansion.two('H', 0x331) },
    .{ .code = 0x1E97, .to = Expansion.two('T', 0x308) },
    .{ .code = 0x1E98, .to = Expansion.two('W', 0x30A) },
    .{ .code = 0x1E99, .to = Expansion.two('Y', 0x30A) },
    .{ .code = 0x1E9A, .to = Expansion.two('A', 0x2BE) },
    // Latin ligatures.
    .{ .code = 0xFB00, .to = Expansion.two('F', 'F') },
    .{ .code = 0xFB01, .to = Expansion.two('F', 'I') },
    .{ .code = 0xFB02, .to = Expansion.two('F', 'L') },
    .{ .code = 0xFB03, .to = Expansion.three('F', 'F', 'I') },
    .{ .code = 0xFB04, .to = Expansion.three('F', 'F', 'L') },
    .{ .code = 0xFB05, .to = Expansion.two('S', 'T') },
    .{ .code = 0xFB06, .to = Expansion.two('S', 'T') },
    // Armenian ligatures.
    .{ .code = 0xFB13, .to = Expansion.two(0x544, 0x546) },
    .{ .code = 0xFB14, .to = Expansion.two(0x544, 0x535) },
    .{ .code = 0xFB15, .to = Expansion.two(0x544, 0x53B) },
    .{ .code = 0xFB16, .to = Expansion.two(0x54E, 0x546) },
    .{ .code = 0xFB17, .to = Expansion.two(0x544, 0x53D) },
};

/// The one lowercasing row that expands: dotted capital I keeps its dot as
/// a combining mark, which is what distinguishes the default mapping from
/// the Turkish one.
const FULL_LOWER = [_]FullEntry{
    .{ .code = 0x130, .to = Expansion.two('i', 0x307) },
};

pub fn fullUpcase(c: u21) Expansion {
    for (FULL_UPPER) |entry| {
        if (entry.code == c) return entry.to;
    }
    return Expansion.one(upcase(c));
}

/// `final` marks a character at the end of a word, which is the only place
/// capital sigma lowercases to the final form.
pub fn fullDowncase(c: u21, final: bool) Expansion {
    if (c == 0x3A3) return Expansion.one(if (final) 0x3C2 else 0x3C3);
    for (FULL_LOWER) |entry| {
        if (entry.code == c) return entry.to;
    }
    return Expansion.one(downcase(c));
}

/// A character that joins to its neighbours in a word, which is what
/// decides whether a sigma is final.
pub fn isCased(c: u21) bool {
    return isAlpha(c) or isCombiningMark(c);
}

/// The combining marks the case tables produce, which do not break a word.
pub fn isCombiningMark(c: u21) bool {
    return (c >= 0x300 and c <= 0x36F) or c == 0x2BC or c == 0x2BE;
}
