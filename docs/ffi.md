# Foreign function interface

zisp calls C functions in the C library it is linked with and in shared
libraries it loads. The functions are exported from the `ZISP-FFI`
package, nicknamed `FFI`, and follow CFFI's names.

```lisp
(use-package "FFI")
(defcfun "strlen" :size-t (s :pointer))
(strlen "héllo")                      ; => 6, the UTF-8 bytes
```

`src/lisp/ffi.lisp` is the Lisp side and `src/builtins/ffi.zig` holds the
natives under it. A freestanding build has neither the natives nor libc.

## Types

| Type | Lisp value |
| --- | --- |
| `:char`, `:unsigned-char`, `:short`, `:unsigned-short`, `:int`, `:unsigned-int`, `:long`, `:unsigned-long`, `:long-long`, `:unsigned-long-long` | an integer within the type's range. `:char` and `:unsigned-char` also take a character, as its code |
| `:float` | any real, passed as a single-float |
| `:double` | any real, passed as a double-float |
| `:pointer` | a `foreign-pointer`, NIL for a null pointer, or a string |
| `:string` | a string, a `foreign-pointer`, or NIL. A result is a Lisp string, or NIL for a null pointer |
| `:void` | a result only, which comes back as NIL |

A string passed as `:pointer` or `:string` is copied into a NUL-terminated
UTF-8 buffer that is freed when the call returns. An integer outside its
type's range signals `type-error`. `long` and pointers are 8 bytes, as on
every target zisp builds for.

`(defctype name base)` names an alias. These are defined:
`:size-t` (`:unsigned-long`), `:ssize-t` and `:off-t` (`:long`), and
`:int8` through `:uint64`. `canonical-foreign-type` resolves an alias and
`foreign-type-size` gives the size in bytes.

## Calling

```lisp
(defcfun "strlen" :size-t (s :string))          ; Lisp name STRLEN
(defcfun ("get_value" fetch) :int (key :int))   ; Lisp name FETCH
(foreign-funcall "abs" :int -3 :int)            ; types and arguments, then the result type
(foreign-funcall-pointer (foreign-symbol-pointer "abs") :int :int -3)
```

`defcfun` takes the C name, or a list of the C name and the Lisp name.
Without one, the Lisp name is the C name upcased with `_` turned into
`-`. The C function has to be defined when `defcfun` runs, or it signals
an error. Each call looks the symbol up again, so a saved image started
in a new process finds the function at its new address.

`(foreign-symbol-pointer name)` is the address of a C symbol, or NIL.
`(load-foreign-library path)` loads a shared library with its symbols
global, so `defcfun` finds them, and signals an error with the loader's
message when it cannot.

Up to 6 integer, character and pointer arguments and up to 8 float and
double arguments can be passed. On x86_64 and aarch64 a call that is not
variadic passes the first class in integer registers in order and the
second in float registers in order, each independently of the other, so
every call goes through one C function type that takes six integers and
eight doubles. A `float` travels in the low 32 bits of its register.
Variadic functions such as `printf`, structures passed by value, and
more arguments than the registers hold are not supported.

zisp does not check what C does with what it is given. A null pointer
handed to a function that reads through it, such as `strlen`, ends the
process.

## Foreign memory

```lisp
(with-foreign-object (cells :int 4)
  (setf (mem-aref cells :int 0) 7)
  (mem-aref cells :int 0))                       ; => 7
```

| Function | |
| --- | --- |
| `(foreign-alloc type &key count initial-element initial-contents)` | `count` objects of `type` from `malloc` |
| `(foreign-free pointer)` | give them back |
| `(mem-ref pointer type &optional offset)` | the `type` at `offset` bytes past `pointer`, and `setf` of it |
| `(mem-aref pointer type &optional index)` | the `index`th `type` from `pointer`, and `setf` of it |
| `(with-foreign-object (var type &optional count) body...)` | `var` bound to memory freed when `body` is left |
| `(with-foreign-objects ((var type count)...) body...)` | several at once |
| `(foreign-string-alloc string)`, `(foreign-string-to-lisp pointer)` | strings in and out of C memory |
| `(with-foreign-string (var string) body...)` | a C copy of `string` for `body` |
| `(make-pointer address)`, `(pointer-address pointer)`, `(null-pointer)`, `(null-pointer-p pointer)`, `(inc-pointer pointer offset)`, `(pointer-eq a b)` | pointers |

## Structures

```lisp
(defcstruct tm
  (sec :int) (min :int) (hour :int) (mday :int) (mon :int) (year :int)
  (wday :int) (yday :int) (isdst :int) (gmtoff :long) (zone :pointer))

(with-foreign-object (parts '(:struct tm))
  (gmtime-r now parts)
  (foreign-slot-value parts 'tm 'year))
```

`(defcstruct name (field type &key count)...)` lays a structure out as C
does on x86_64 and aarch64: each field at the next offset its alignment
allows, an array field taking `count` elements, and the size rounded up
to the largest alignment a field has. A base type's alignment is its
size, and a structure's is its largest field's. `(:struct name)` is the
type, which `foreign-type-size`, `foreign-type-alignment`,
`foreign-alloc` and `with-foreign-object` take.

`(foreign-slot-value pointer 'name 'field)` reads a field, and `setf`
writes it. A field that is an array or a structure reads as a pointer to
it. `foreign-slot-offset`, `foreign-slot-pointer` and
`foreign-slot-names` give the rest of the layout. A structure is passed
to and from C by pointer, not by value.

A Lisp `defstruct` whose slots all have a `:type` can be given a C
layout too. `(defcstruct-from-defstruct name)` lays out a slot of type
`(signed-byte N)` or `(unsigned-byte N)`, for N of 8, 16, 32 or 64, as
the C integer of that size, `fixnum` as `:long`, `single-float` as
`:float`, `double-float` as `:double` and `foreign-pointer` as
`:pointer`, in slot order. `(write-foreign-struct instance pointer)`
copies an instance's slots into C memory, and
`(read-foreign-struct pointer name)` makes a new instance from it.

## Callbacks

`(defcallback name return-type ((param type)...) body...)` defines a Lisp
function C can call, and `(callback name)` is the pointer to pass for it.
`docs/ffi-callbacks.md` says how it works and what it does not cover.
