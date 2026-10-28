# Image format

`(ext:save-image "file.zimg")` writes everything a Lisp session holds to
a file, and `zisp --image file.zimg` starts a session from it instead of
from the boot sources. This document describes the file.

## What an image holds

Every package, with its names, the packages it uses, and its present
symbols; every symbol reachable from those, with its value, function,
property list and the flags that make it special or constant; and every
object reachable from any of them. Compiled code goes in as code
sections, the way a fasl holds it. The optimize policy and the logical
pathname hosts go in as well.

A variable bound dynamically when the image is saved is saved with its
global value, the one outside every binding.

What does not go in:

- the evaluator's caches: macro expansions, call caches, source
  positions;
- finalizers;
- the contents of streams. A console stream is made again as a console
  stream reading or writing the new session's terminal, and any other
  stream comes back closed.

## How objects are found

`ext:%walk-heap` is the collector's marker run with a callback: the walk
follows every reference the marker follows, plus a compiled function's
constants, and calls the callback once for each object it reaches the
first time. The image is written in the order that walk visits objects,
starting from the packages in the order they were made and their present
symbols in name order. The same session state therefore always gives the
same bytes.

## Layout

Integers are in the byte order the header names. Every section starts at
an offset that is a multiple of 8.

### Header

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | magic: the bytes `ZISPIMG` and a zero byte |
| 8 | 1 | byte order: 1 for little-endian, 2 for big-endian |
| 9 | 3 | zero |
| 12 | 2 | major version |
| 14 | 2 | minor version |
| 16 | 4 | instruction set, as in a fasl |
| 20 | 4 | section count |
| 24 | 8 | length of the whole file in bytes |

### Sections

Each section is a 16-byte header, the kind in 4 bytes, 4 zero bytes, and
the payload length in 8, followed by the payload, padded with zero bytes
to a multiple of 8. An image holds, in this order:

1. **Natives** (kind 1): the natives the image refers to, as a count
   and then, for each, its place in the order the binary defines its
   natives and the name it was defined under, as a length and UTF-8
   bytes.
2. **Code** (kind 2), one section for each compiled function body: its
   name, flags (has a name, takes `&rest` or `&key`, checks its
   argument count), its required and optional parameter counts, its
   other slots, the most values it keeps on the stack and its call
   sites, then its instruction words starting at a multiple of 8 within
   the file, its constants as references, its jump tables, each slot's
   name as a reference, its source positions, and its source file's
   name.
3. **Packages** (kind 3): a count, then for each package its name, its
   nicknames, and the indices of the packages it uses.
4. **Objects** (kind 4): a count, then each object as a tag and its
   fields.
5. **Package contents** (kind 5): for each package, its present
   symbols, each as a reference, the name it is present under, and
   whether it is external or shadowing.
6. **State** (kind 6): the current package, the optimize policy, and the
   logical pathname hosts as an object index.

### Objects

A reference is 8 bytes. A value that refers to nothing in the heap, a
fixnum, a character, a single float or one of the evaluator's markers
such as unbound, is written as itself. A reference to an object is the
object's index shifted left 3 bits, with 7 in the low 3: a tag no live
value carries.

| Tag | Object | Fields |
| --- | --- | --- |
| 1 | fixnum | 8, signed |
| 2 | bignum | sign byte, limb count, limbs |
| 3 | ratio | numerator, denominator |
| 5 | double float | its bits |
| 6 | complex | real part, imaginary part |
| 7 | character | code point |
| 8 | string | length, capacity, flags (fill pointer, adjustable), code points; or, when displaced, the string it is displaced to and the offset |
| 9 | symbol | home package index or `0xFFFFFFFF`, name as a length and UTF-8 bytes, flags (special, constant, name only), then value, function and property list unless the flags say name only |
| 10 | cons | car, cdr |
| 11 | array | element type, rank, dimensions, flags (fill pointer, adjustable), fill pointer, then either the array it is displaced to and the offset, or its elements |
| 12 | hash table | test, requested size, rehash size, rehash threshold, entry count, then each key and value |
| 13 | native function | index into the natives section, flags |
| 14 | interpreted function | name, parameters, body, captured variable frame, captured function frame, flags (macro) |
| 15 | compiled function | code number, flags, closed-over values |
| 16 | funcallable instance | class, slots, wrapper, function |
| 17 | frame | parent frame or `0xFFFFFFFF`, binding count, each binding's symbol and value |
| 18 | structure | name, slot count, slots |
| 19 | package | package index |
| 20 | pathname | host, device, directory, name, type, version, logical flag |
| 21 | stream | kind, direction, element type, external format, path, target |
| 22 | random state | four 8-byte words |
| 23 | readtable | case |
| 24 | weak pointer | referent |

`%image-round-trip` writes the objects reachable from one object, with
symbols by name only, and reads them back. The tests use it to check
each kind of object and shared structure on their own.

## Loading

`zisp --image` makes an evaluator and registers the natives, without
evaluating the boot sources. Loading then:

1. finds each native at its place among the natives this binary
   defines, and signals `ext:fasl-version-error` when the name there is
   not the one the image gives, since then the image was written by a
   zisp with different natives;
2. builds the code sections, with their constants unfilled;
3. finds or makes each package;
4. makes every object in the order they are written, a symbol in its
   home package under its name, a cons empty, an array or a structure
   with room for its contents;
5. goes over the objects a second time and fills in every reference,
   from the index in the file to the object made for it, which is how
   shared structure and cycles come back as they were;
6. fills in the code's constants, rebuilds each hash table from its
   entries, since an `eq` table hashes on addresses, and enters each
   package's present symbols;
7. sets the state.

A native's code is in the binary, not in the image: the natives section
is the table that ties each reference to the native the loading zisp
has of that name. Bytecode holds no machine addresses, so nothing in a
code section needs fixing up. The objects themselves are made again in
the collected heap rather than mapped from the file, since the collector
owns the regions it allocates from.

## Starting from an image

    zig build image-cold-start -Doptimize=ReleaseFast

saves an image of a session that defines one function, checks that
saving the same session twice gives the same bytes, and times
`zisp --image demo.zimg --eval '(my-fn)'` from process start to exit,
failing when the best of ten runs is over 50 ms. CI runs it on its
Linux runner.

| Measured on | ReleaseFast | ReleaseSafe | Debug |
| --- | --- | --- | --- |
| macOS, aarch64, 2026-10-24 | 3.7 ms | 4.3 ms | 45.5 ms |

## Versions

A file whose major version, or whose instruction set, is not the one
this zisp writes signals an error before anything is made. The minor
version changes when a section kind is added that an older loader can
pass over by its length; an object tag cannot be skipped, so adding one
changes the major version. This zisp writes version 2.0.
