# FASL format

`compile-file` writes what it compiled to a fasl, a file `load` reads
back without reading or compiling any source. This document describes
the binary fasl. A file whose literal objects the binary format cannot
hold is written as a text fasl instead, described at the end.

## Layout

Every integer is unsigned unless it says otherwise, in the byte order
the header names. Every section starts at an offset that is a multiple
of 8, and the words of a code section start at a multiple of 4 inside
it, so a loader that maps the file can read them where they lie without
copying or fixing anything up.

### Header

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | magic: the bytes `ZISPFASL` |
| 8 | 1 | byte order: 1 for little-endian, 2 for big-endian |
| 9 | 3 | zero |
| 12 | 2 | major version |
| 14 | 2 | minor version |
| 16 | 4 | instruction set: a hash of the VM's opcode names in order |
| 20 | 4 | section count |
| 24 | 8 | length of the whole file in bytes |

### Sections

Each section is a 16-byte header followed by its payload, padded with
zero bytes to a multiple of 8:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | kind |
| 4 | 4 | zero |
| 8 | 8 | payload length in bytes, before padding |

A file holds its code sections first, then one objects section, then one
top-level section.

**Code** (kind 1) is one compiled function body, numbered by its place
among the file's code sections, from 0:

| Field | Size |
| --- | --- |
| name: an object index, or `0xFFFFFFFF` for none | 4 |
| required parameters | 4 |
| optional parameters | 4 |
| flags: bit 0 set when it takes `&rest` or `&key`, bit 1 when it checks its argument count | 4 |
| other local slots | 4 |
| most values on the stack at once | 4 |
| call sites | 4 |
| instruction words, w | 4 |
| constants, c | 4 |
| jump tables, j | 4 |
| slot names, s | 4 |
| source positions, p | 4 |
| the source file's name: an object index, or `0xFFFFFFFF` for none | 4 |
| zero, so the words start at a multiple of 8 | 4 |
| the instruction words | 4w |
| each constant as an object index | 4c |
| each jump table: its length n, then n offsets | 4 + 4n each |
| each slot's name as an object index, `0xFFFFFFFF` for a slot the compiler made | 4s |
| each source position: the offset of its instruction, its line and its column | 12p |

**Objects** (kind 2) is a count, then that many objects, each a one-byte
tag and what follows it. An object refers to another by its index in
this section, from 0. A number refers only to objects before it, so it
can be made as soon as it is read. A cons or a vector may refer to any
object, before or after it and itself included, which is how shared
structure and cycles are written.

| Tag | Object | Then |
| --- | --- | --- |
| 1 | fixnum | 8, signed |
| 2 | bignum | 1: 1 when negative; 4: limb count n; 8n: limbs, least significant first |
| 3 | ratio | 4, 4: numerator and denominator |
| 4 | single float | 4: its bits |
| 5 | double float | 8: its bits |
| 6 | complex | 4, 4: real and imaginary parts |
| 7 | character | 4: code point |
| 8 | simple string | 4: length n; 4n: code points |
| 9 | symbol | 4: its home package's name, a string, or `0xFFFFFFFF` for none; 4: its name, a string |
| 10 | cons | 4, 4: car and cdr |
| 11 | simple vector | 4: length n; 4n: elements |
| 12 | compiled function | 4: a code number |
| 13 | pathname | 4: its namestring, a string |
| 14 | simple bit vector | 4: length n; n bytes, 0 or 1 |
| 15 | simple vector of `(unsigned-byte 8)` | 4: length n; n bytes |

A symbol with a home package is interned in the package of that name
when the file is loaded, and `load` signals `package-error` when there
is none. Symbols with no home package that are the same object when the
file is compiled are one symbol when it is loaded. A compiled function
object is one closing over nothing: what `make_closure` copies a new
function from.

**Top level** (kind 3) is a count, then that many code numbers. Loading
calls each of those functions in order, with no arguments. Each is one
top-level form of the source file, compiled as the body of a function
of no arguments.

## Loading

`load` reads the header first. A file whose major version or
instruction set is not the one this zisp writes signals
`ext:fasl-version-error` before anything in it runs. A file with a
higher minor version than this zisp knows is loaded as long as the
major version and instruction set match.

The loader then builds every code object with its constants unfilled,
makes the objects in two passes (each one, then what each cons and
vector refers to), fills in the code's constants, and runs the top-level
functions.

`(load "name")` with no type in the name, where no file has that name as
it is, loads `name.zfasl`. When `name.lisp` exists and is newer than the
fasl, or there is no fasl yet, it compiles `name.lisp` first.

`compile-file` compiles each top-level form as it processes it, after
any form before it has taken effect at compile time. A `defclass`,
`define-condition`, `defstruct`, `deftype`, `defsetf`,
`define-setf-expander`, `define-symbol-macro`, `define-compiler-macro`,
`define-modify-macro` or `defconstant` at top level is evaluated when it
is compiled as well as when the fasl is loaded, so the forms after it
can expand macros that refer to what it defines.

A fasl holds no pointers and nothing that depends on the machine that
wrote it, so one written on any target zisp builds for loads on any
other. The same source compiled by the same zisp gives the same bytes
on every target. `tests/run-fasl-fixtures.sh` compiles
`tests/fasl/cross.lisp` with an aarch64 zisp and with an x86_64 one, and
the tests check that each of those fasls loads and that compiling the
source again gives the same bytes.

## Versions

The major version changes when a field moves or changes meaning, and the
instruction set hash changes whenever an instruction is added, removed
or reordered, since either makes what an older zisp wrote mean
something else. The minor version changes when a section kind is added
that a loader can skip: a loader passes over a section of a kind it does
not know, using its length. This zisp writes version 1.0.

## Text fasls

A literal the objects section has no tag for, such as an instance or a
hash table, makes `compile-file` write a text fasl for the whole file:
its first line is `;; zisp fasl (readable load-time forms)`, and the
rest is the file's load-time forms as source, with each object that
defines `make-load-form` written as a reference to a table the fasl
fills as it loads. `load` compiles each form of one before running it.
