# Lisp macros that run Zig comptime

A zisp macro can hand a Zig expression to the Zig compiler, have it
evaluated at Zig compile time, and get the result back as a Lisp form.
Three things are built on that:

- reading the layout of a Zig type, so a `defcstruct` comes from the
  Zig declaration instead of being written out by hand;
- writing a Zig `extern struct` for a Lisp `defstruct`;
- checking a function's arithmetic against Zig's typing rules at
  macroexpansion time.

## Surface API

The names are exported from a new package, `ZISP-ZIG`, nicknamed `ZIG`.
The Lisp side lives in `src/lisp/zig.lisp`.

| Name | Kind | Signature and result |
| --- | --- | --- |
| `*zig-program*` | variable | The Zig compiler to run. NIL, its initial value, means the value of the environment variable `ZISP_ZIG` when it is set, otherwise `"zig"`, found on `PATH` |
| `*zig-cache-directory*` | variable | Where generator files and their results are kept. NIL, its initial value, means `$XDG_CACHE_HOME/zisp/zig/`, or `~/.cache/zisp/zig/` when `XDG_CACHE_HOME` is unset |
| `(comptime-eval zig-expression &key imports)` | function | `zig-expression` is a string holding one Zig expression. `imports` is a list of `(name path)` pairs, each naming a Zig file the expression reaches as `name`. `std` is always imported. Returns the Lisp form the expression's value prints as (see the table below) |
| `(define-cstruct-from-zig name zig-type &key imports)` | macro | `zig-type` is a string naming a Zig struct type, such as `"std.c.timespec"`, and `imports` is as for `comptime-eval`. Expands to a `defcstruct` named `name` with the fields, field types and offsets Zig gives that type |
| `(extern-struct-source &rest structure-names)` | function | A string of Zig source declaring an `extern struct` for each named Lisp `defstruct` |
| `(write-zig-structs path &rest structure-names)` | function | Writes `(extern-struct-source structure-names...)` to `path` and returns `path` |
| `(defun-checked name ((parameter type)...) result-type &body body)` | macro | Translates the function into Zig, has Zig type-check it, and expands to a `defun` with the same parameters and type declarations, or signals `zig-type-error` |
| `zig-error` | condition | The base condition. Slots `arguments` (the argument list Zig was run with), `exit-code` and `output` (what Zig wrote to standard error) |
| `zig-not-found` | condition, a `zig-error` | `*zig-program*` could not be started |
| `zig-comptime-error` | condition, a `zig-error` | Zig rejected a `comptime-eval` expression |
| `zig-type-error` | condition, a `zig-error` | Zig rejected a `defun-checked` body. Adds slots `function-name`, `form` (the Lisp form the first error points at) and `message` (Zig's first error line) |

Each slot has a reader named after the condition and the slot, such as
`zig-error-output` and `zig-type-error-form`.

`comptime-eval` is an ordinary function, so any `defmacro` can call it
while expanding. That is the whole mechanism for a macro that calls into
Zig comptime: `define-cstruct-from-zig` and `defun-checked` are two such
macros, written in Lisp.

```lisp
(defmacro int-max (bits)
  (zig:comptime-eval (format nil "std.math.maxInt(i~d)" bits)))

(int-max 32)                          ; expands to 2147483647
```

### What a Zig value prints as

| Zig value | Lisp form |
| --- | --- |
| an integer, `comptime_int` included | the integer |
| `true`, `false` | `T`, `NIL` |
| `null` | `NIL` |
| an enum value or enum literal | a keyword: `.little` is `:LITTLE` |
| a string literal or a `*const [N]u8` | a string |
| a tuple, an array or a slice | a list of its elements |
| a struct value | a property list, `.{ .a = 1, .b_c = 2 }` is `(:A 1 :B-C 2)` |
| an integer type | `(:SIGNED bits)` or `(:UNSIGNED bits)` |
| a float type | `(:FLOAT bits)` |
| `bool` | `:BOOL` |
| a pointer or optional pointer type | `:POINTER` |
| a struct type | `(:STRUCT :SIZE n :ALIGNMENT n (field :OFFSET n :TYPE type-form)...)`, each field a keyword |

A name becomes a keyword by upcasing it and turning `_` into `-`. Any
other value or type, such as a function or a union, is a Zig compile
error, so it signals `zig-comptime-error`.

## The bridge

`comptime-eval` writes a Zig program whose one constant is the
expression, printed to Lisp text at Zig compile time, and runs it.

**The generator.** For the expression `E` and imports `(name path)...`,
the file is:

```zig
const std = @import("std");
const lisp = @import("zisp_lisp.zig");
const name = @import("name");          // one line per import

const form = lisp.print(E);

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, form ++ "\n");
}
```

`form` is a container-level constant, and `lisp.print` builds its
string inside a `comptime` block, so Zig evaluates `E` and prints it
while compiling. `main` only writes bytes that are already in the
program. An expression whose value is not known at compile time is a
Zig compile error, reported by Zig.

`zisp_lisp.zig` is the printer behind the table above, about 80 lines
using `@typeInfo`, `@offsetOf`, `@sizeOf`, `@alignOf` and
`std.fmt.comptimePrint`. It is kept in the zisp tree as
`src/zig/zisp_lisp.zig`, built into the zisp binary with `@embedFile`,
and written to `*zig-cache-directory*` before each Zig run.

**Running it.** These steps happen in order.

1. The key is the SHA-256 of these strings joined with NUL characters:
   the output of `zig version`, the printer's source, the generator's
   source, and each import's name and file contents. `zig version` is
   run once per process and remembered.
2. If `<key>.lisp` exists in the cache directory, its one form is read
   and returned. Zig is not run.
3. Otherwise the generator is written to `<key>.zig`, and zisp runs
   `*zig-program*` with the arguments `run --cache-dir zig-cache`, then
   `--dep name` for each import, `-Mroot=<key>.zig`, and `-Mname=path`
   for each import with its absolute path. It runs in the cache
   directory, with no shell, capturing standard output and standard
   error. Each import is a Zig module, since Zig refuses an `@import` of
   a file outside the generator's directory.
4. A program that cannot be started signals `zig-not-found`. A nonzero
   exit signals `zig-comptime-error` with Zig's standard error as
   `output`.
5. On exit 0, standard output is read with `read-from-string`, with
   `*read-eval*` NIL and the standard read table. The text is written to
   `<key>.lisp.tmp` and renamed to `<key>.lisp`, so a second zisp process
   reading the cache sees the whole file or no file. The form is
   returned.

zisp has no way to run a program today. The bridge adds one native,
`(cl::%run-program program arguments directory)`, in `src/builtins/zig.zig`,
returning three values: the exit code, the standard output string and
the standard error string. A program that cannot be started returns NIL
and the reason as the third value. It uses `std.process.run` and is left
out of freestanding and WASM builds, where `comptime-eval` signals
`zig-not-found`.

**Cost.** Measured on macOS aarch64 with Zig 0.17.1, for the worked
example below: 2.5 s with an empty Zig cache, 58 ms when Zig's cache
already holds the build, and no Zig run at all once `<key>.lisp` exists.

**Compiled files.** Macros expand when `compile-file` runs, so a FASL
holds the expansion. Loading a FASL does not run Zig, and a machine
without Zig can load it.

## Worked example

`std.c.timespec` is the C library's `struct timespec` as Zig declares it
for the target. A program that passes one to `clock_gettime` needs it as
a `defcstruct`.

**Lisp source.**

```lisp
(use-package '("FFI" "ZIG"))

(define-cstruct-from-zig timespec "std.c.timespec")
```

**Macroexpansion.** `define-cstruct-from-zig` is:

```lisp
(defmacro define-cstruct-from-zig (name zig-type &key imports)
  (%cstruct-form name (comptime-eval zig-type :imports imports)))
```

`%cstruct-form` is internal to zisp. Expanding the
macro calls `(comptime-eval "std.c.timespec")`, which writes this
generator:

```zig
const std = @import("std");
const lisp = @import("zisp_lisp.zig");

const form = lisp.print(std.c.timespec);

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, form ++ "\n");
}
```

**Zig comptime.** Zig evaluates `lisp.print(std.c.timespec)` while
compiling. The argument is a type, so the printer walks
`@typeInfo(std.c.timespec).@"struct"`: for each name in `field_names`
and type in `field_types` it takes `@offsetOf` and prints the field
type. The program writes, on aarch64 macOS:

```lisp
(:STRUCT :SIZE 16 :ALIGNMENT 8 (:SEC :OFFSET 0 :TYPE (:SIGNED 64)) (:NSEC :OFFSET 8 :TYPE (:SIGNED 64)))
```

**Emitted code.** `%cstruct-form` turns each field's type form into an
FFI type: `(:SIGNED n)` into `:int8`, `:int16`, `:int32` or `:int64`,
`(:UNSIGNED n)` into `:uint8` through `:uint64`, `(:FLOAT 32)` into
`:float`, `(:FLOAT 64)` into `:double` and `:POINTER` into `:pointer`.
It interns each field name in the current package. The expansion is:

```lisp
(defcstruct timespec
  (sec :int64)
  (nsec :int64))
```

`%cstruct-form` then lays this `defcstruct` out with the FFI's rules and
compares each offset and the size with what Zig printed. A mismatch,
such as from a field with an `align` attribute, signals an error naming
the field, instead of producing a structure C would read differently.
A field type outside the list, such as a nested struct or an array,
signals an error naming the field and its Zig type.

## Zig structures from Lisp structures

```lisp
(defstruct point x y)
(defstruct sample
  (count 0 :type (signed-byte 32))
  (total 0 :type fixnum)
  (ratio 0.0 :type single-float)
  (handle nil :type foreign-pointer))

(zig:write-zig-structs "shapes.zig" 'point 'sample)
```

writes

```zig
pub const Value = u64;

pub const Point = extern struct {
    x: Value,
    y: Value,
};

pub const Sample = extern struct {
    count: i32,
    total: i64,
    ratio: f32,
    handle: ?*anyopaque,
};
```

which `zig build-obj shapes.zig` compiles. The structure name becomes
the Zig name by capitalizing each `-`-separated part and dropping the
`-`, and a slot name by downcasing it and turning `-` into `_`. A name
that is a Zig keyword, such as `error`, is written `@"error"`. Fields
are in slot order.

| Slot `:type` | Zig field type |
| --- | --- |
| `(signed-byte N)`, `(unsigned-byte N)`, N of 8, 16, 32 or 64 | `iN`, `uN` |
| `fixnum` | `i64` |
| `single-float`, `double-float` | `f32`, `f64` |
| `foreign-pointer` | `?*anyopaque` |
| none, or `t` | `Value`, the 64-bit word a zisp value is (`docs/tagging.md`) |

This is the same mapping `defcstruct-from-defstruct` uses, so a
structure with typed slots has the same layout in both. `Value` is
declared once per file when a structure needs it. Any other slot type
signals an error naming the slot.

## Type-checking with Zig

```lisp
(zig:defun-checked scale ((x (signed-byte 32)) (factor single-float)) (signed-byte 32)
  (* x factor))
```

`defun-checked` translates the function into Zig and has Zig check it:

```zig
fn scale(x: i32, factor: f32) i32 {
    return x * factor;
}

comptime {
    _ = &scale;
}
```

It runs `*zig-program*` with `build-obj -fno-emit-bin <key>.zig`, which
does Zig's semantic analysis without generating code, and caches a pass
as `<key>.ok` the way `comptime-eval` caches its result. Zig rejects
this one:

```
<key>.zig:2:14: error: incompatible types: 'i32' and 'f32'
```

so the macro signals `zig-type-error` with `function-name` `SCALE`,
`form` `(* X FACTOR)` and that message. The translator writes each Lisp
form on its own line and records which form each line came from, which
is how a line number in Zig's error leads back to a form.

When Zig accepts a function, the expansion is a plain `defun`, after a
form that records the function's Zig signature so later checked
functions can call it, at compile time too:

```lisp
(defun-checked sum-squares ((x fixnum) (y fixnum)) fixnum
  (+ (* x x) (* y y)))
```

expands to

```lisp
(progn
  (eval-when (:compile-toplevel :load-toplevel :execute)
    (setf (gethash 'sum-squares *%checked-functions*) '(("i61" "i61") "i61")))
  (defun sum-squares (x y)
    (declare (type fixnum x) (type fixnum y))
    (the fixnum (progn (+ (* x x) (* y y))))))
```

The function runs as Lisp. Zig only checks it.

**Types.** As in the structure table, except that `fixnum` is `i61`,
the range a zisp fixnum holds, `boolean` is `bool`, and a type with no
Zig equivalent, such as `integer` or `t`, signals an error naming the
parameter.

**Forms the translator accepts.**

| Lisp | Zig |
| --- | --- |
| a parameter or `let` variable | the same name, `-` turned into `_`, with a numbered suffix when an enclosing variable already has the name, since Zig refuses shadowing |
| an integer or float literal | the literal |
| `(+ a b ...)`, `(- a b ...)`, `(* a b ...)` | the operator between the operands, left to right |
| `(- a)` | `-a` |
| `(truncate a b)` | `@divTrunc(a, b)` |
| `(< a b)`, `(> a b)`, `(<= a b)`, `(>= a b)`, `(= a b)` | the comparison |
| `(if test then else)` | `if (test) then else`, or in tail position an `if` statement returning from each branch |
| `(let ((var value)...) body...)` | a labeled block with a `const` per variable, or in tail position a block of `const` statements |
| `(the type form)` | `@as(T, form)` |
| a call to a function already defined with `defun-checked` | a call, with that function declared in the same file from its recorded signature |

Every body form but the last, in the function and in a `let`, is
evaluated and discarded with `_ =`, and so is a parameter or variable
the body does not mention, since Zig refuses unused locals.

Anything else signals an error naming the form. The rules are Zig's, and
they are stricter than Common Lisp's: Zig has no contagion from integer
to float and no implicit narrowing, so `(* x factor)` above is an error,
and so is returning an `i64` sum from a function declared `(signed-byte
32)`. That strictness is what the check is for.

## Out of scope

- Calling Zig functions at run time. Zig code reached at run time goes
  through the FFI, after building it into a shared library outside zisp.
- Zig calling back into Lisp during comptime. Data goes one way per
  `comptime-eval`: Zig source in, one Lisp form out.
- Zig generics driven from Lisp, such as instantiating
  `std.ArrayList(T)` for a Lisp-chosen `T` and using the result.
- Compiling Lisp to Zig beyond the `defun-checked` subset.
- Unions, enums as types, error sets, nested structs and arrays as
  field types, packed structs, and functions as values in
  `comptime-eval` results.
- Running untrusted Zig source safely. `comptime-eval` runs a Zig build
  with the user's permissions, as `zig run` does.
- Freestanding and WASM builds of zisp, which cannot start a process.
- Zig versions other than 0.17. The printer uses 0.17's `@typeInfo`
  layout, where a struct's fields are `field_names` and `field_types`.

## Sign-off

- [x] Approved
