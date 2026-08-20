# Strings

A string is a contiguous block of characters, one character per byte. The
`HeapString` header stores the character count and the characters follow
inline, so `length`, `char`, `aref` and `(setf char)` are all constant time
and mutate in place.

## Character range

A string element holds one codepoint, so any character fits and indexing
is constant time:

```lisp
(length "héllo")   ; => 5
(char "日本語" 1)   ; => #\本
```

## Case conversion

`char-upcase` and `char-downcase` are the one-to-one mappings CLHS
defines, covering the Latin, Greek and Cyrillic blocks. `string-upcase`
and its relatives are built on them, as the standard requires, so a
character with no single-character uppercase is left alone:

```lisp
(string-upcase "straße")   ; => "STRAßE"
```

`unicode-upcase`, `unicode-downcase` and `unicode-capitalize` apply the
full mappings instead, where one character can produce several and
context can matter:

```lisp
(unicode-upcase "straße")     ; => "STRASSE"
(unicode-upcase "ﬃ")          ; => "FFI"
(unicode-downcase "ΟΔΟΣ")     ; => "οδος", with a final sigma
```

These cannot replace the standard functions, because CLHS defines those
in terms of `char-upcase`, which cannot expand.

## Fill pointers

A string carries the same optional fill pointer and adjustable flag as any
other vector, so `make-array` with `:element-type 'character` returns a
string and `vector-push-extend` works on it. Storage is held indirectly for
that reason: growing a string must not move the object other values already
point at. See [arrays.md](arrays.md).

## Case conversion

`char-upcase` and `char-downcase` map the full Latin-1 range, so `#\ÿ`
uppercases to `#\Ÿ` at U+0178. A string element has only a byte, so
`string-upcase` leaves that one character alone rather than storing a code
it cannot hold. Every other Latin-1 letter maps within the byte range and
converts normally.

## Bytes at the boundary

Source text, filesystem paths and symbol names are bytes, so a string is
decoded from UTF-8 on the way in and encoded back on the way out. The
conversion happens at those boundaries only; everything in between works
in codepoints.

One codepoint per element costs four bytes a character where UTF-8 would
often use one. That is the price of constant-time `char` and `(setf char)`
at any character width, which the alternative cannot give without an index
or a rescan.
