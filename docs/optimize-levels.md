# Optimize levels

The bytecode compiler reads the four `optimize` qualities from
`(declaim (optimize ...))`, which sets them for everything compiled
afterwards, and from `(declare (optimize ...))` at the head of a body,
which sets them inside it. Each quality is 0, 1, 2 or 3, and every one is
1 until something says otherwise. `(optimize speed)` with no level means
`(speed 3)`.

What follows is everything each level changes.

## Safety

At 0, a call does not check how many arguments it was passed. A missing
argument reads as NIL, and arguments past the last parameter are
dropped. `(the type form)` does not check the value, and neither does
binding or assigning a variable declared with a type. Code is smaller,
and a value of the wrong type is used as if it were right.

At 1, 2 and 3, every argument count is checked, and every `the` and every
declared variable type is checked with `typep` where the value is bound
or assigned, signaling `type-error` when it does not hold.

## Speed

At 0, the arithmetic, comparison, list and `eq` functions the VM has
instructions for are called like any other function, and no function is
expanded inline.

At 1 and 2, those functions are compiled to their instructions: `+`,
`-`, `<`, `>`, `<=`, `>=` and `=` of two arguments, `1+`, `1-`, `eq`,
`cons`, `car`, `cdr`, `not` and `null`. Where every argument is known to
be a fixnum, through a type declaration, a `the`, or a fixnum constant,
the instruction is one that does not check them. A function declared
inline is expanded at a call when speed is not below space.

At 3, a function declared inline is expanded whatever space is.

    zig build optimize-bench -Doptimize=ReleaseFast

times one loop compiled both ways and fails when `(speed 3)` is less
than twice as fast as `(speed 0)`:

| Measured on | `(speed 0)` | `(speed 3)` | Ratio |
| --- | --- | --- | --- |
| macOS, aarch64, 2026-10-24 | 89.8 ms | 17.0 ms | 5.3x |

## Debug

At 0, no variable names are kept, so `disassemble` and a debugger have
none to show.

At 1 and 2, each slot's variable name is kept.

At 3, as well as the names, the line and column each call was written on
are kept, and `disassemble` shows the line beside the call and the
source file at the top. A call in tail position does not replace its
caller's frame, so a backtrace shows every call in progress.

## Space

At 0, 1 and 2, a function declared inline is expanded where speed
allows.

At 3, a function declared inline is called instead of expanded, unless
speed is 3, which makes the code smaller.

## Inline expansion

A function is expanded inline when it is declared inline, by
`(declaim (inline name))` or by `(declare (inline name))` where the call
is, and is not declared `notinline` closer in. The expansion is what the
function's `defun` was, kept when the `defun` ran or was compiled with
the function already proclaimed inline and with nothing lexical around
it. The expansion binds the parameters to the arguments and sees the
global environment and none of the caller's. A lambda list with `&key`
or `&aux`, a supplied-p parameter, or an argument count the lambda list
does not accept is called instead, and so is a function whose expansion
is already being expanded three deep, which is what ends a recursive
one.
