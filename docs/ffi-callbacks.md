# Callbacks

A callback is a Lisp function C code can call through a function
pointer, such as the comparator `qsort(3)` takes.

```lisp
(defcallback compare-ints :int ((a :pointer) (b :pointer))
  (let ((x (mem-ref a :int)) (y (mem-ref b :int)))
    (cond ((< x y) -1) ((> x y) 1) (t 0))))

(defcfun "qsort" :void (base :pointer) (count :size-t) (size :size-t) (compare :pointer))
(qsort array 100 4 (callback compare-ints))
```

## How a callback is made

C calls a function pointer, so a callback needs machine code at an
address. The usual ways to get it are libffi's closures, or trampolines
written out at run time for each architecture. zisp uses neither. It
compiles a fixed pool of entry points into the binary: 32 that return an
integer and 32 that return a double, each a C function taking six
integers and eight doubles.

That one shape serves every callback, for the reason it serves every
call in `docs/ffi.md`: on x86_64 and aarch64, a call that is not variadic
passes integers and pointers in integer registers in order and floats
and doubles in float registers in order, each class independently of the
other. Whatever a C caller passes lands in the entry point's
parameters, and the registers it did not use hold values the entry
point ignores. A `float` arrives in the low 32 bits of its register, and
a `float` result goes back the same way.

Against the alternatives:

- **libffi** needs a C library at build time on every platform, and its
  closures allocate executable memory, which on macOS on Apple silicon
  means `MAP_JIT` and switching the thread between writing and running.
- **Trampolines written at run time** need the same executable memory,
  plus an encoder for each architecture's instructions.
- **A compiled pool** needs neither, and works on any target Zig
  compiles for whose calling convention passes the two classes this way.
  It limits how many callbacks exist at once to the pool's size.

## What `defcallback` does

`(defcallback name return-type ((param type)...) body...)` claims a slot
in the pool for `name`, from the 32 returning integers or the 32
returning doubles as the return type needs, and records the Lisp
function and the C types in `*%callbacks*`, a vector of 64 entries. A
second `defcallback` of the same name keeps its slot. `(callback name)`
is a pointer to the slot's entry point, and `(get-callback name)` the
same for a name that is evaluated.

When C calls the entry point, it reads its slot's entry from
`*%callbacks*`, turns each argument into a Lisp value by its C type as a
call's result is turned, calls the function, and turns what it returns
into the return type as a call's argument is turned. A `:pointer`
parameter is a `foreign-pointer`. The entry point does not hold the Lisp
function itself, so the collector sees it only through `*%callbacks*`,
and a saved image keeps the callbacks and finds the entry points at
their new addresses in the next process.

## Non-local exits

A Lisp function a callback runs can signal an error, throw, or return
from a block outside it. Unwinding cannot pass through the C frames
between the callback and the foreign call that led to it. So the entry
point returns 0 to C instead, and the exit is taken when that foreign
call returns. Until then the C code goes on with 0 as the callback's
result. A handler or restart inside the callback runs as usual, since
it does not leave the callback.

## Out of scope

- Variadic callbacks. A variadic C function receives its variable
  arguments on the stack on aarch64 macOS, and by a different register
  convention on x86_64, so the pool's shape does not fit them.
- Parameters and results that are structures passed by value.
- More than 6 integer and pointer parameters or 8 float and double
  parameters.
- `:string` results, since nothing would free the C copy.
- Calls from threads other than the one running zisp.
- More than 32 callbacks of each result class at once.
