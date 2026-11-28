# Packages

`COMMON-LISP` exports the 978 symbols the standard names and no others.
The implementation's own helpers, whose names hold a `%`, are internal to
it: a program reaches one as `cl::%name`.

    (cl::%structure-p x)

What zisp adds for programs to call is exported from `EXTENSIONS`, whose
nickname is `EXT`, and `COMMON-LISP-USER` uses it, so `(gc)`, `(quit)`
and `ext:*evaluator-mode*` read there unqualified. `COMMON-LISP` holds
these symbols too, internally, so the implementation's Lisp sources name
them without a prefix.

A character is a string designator, so `(find-package #\Z)` finds the
package named `Z`.

## Compiling a file

`compile-file` evaluates a file's `in-package` and `defpackage` forms as
it compiles them, so the forms after them are read in the package they
name, and it puts `*package*` back when it is done. A fasl written as
text names every symbol with its package, so it reads back the same in
whatever package is current.
