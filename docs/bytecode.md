# Bytecode

`compile` turns a lambda expression into a function that runs on a stack
machine instead of being walked by the interpreter. The compiler is in
`src/compiler/`: `convert.zig` and `emit.zig` are its two passes,
`bytecode.zig` holds the instruction set, and `vm.zig` runs it.

With `ext:*evaluator-mode*` set to `:compile`, `eval`, `load` and the
REPL compile every top-level form as the body of a function of no
arguments and call it. A top-level `progn` is taken a form at a time, so
a macro one form defines is there for the next. The default is
`:interpret`.

## Compiling

The first pass macroexpands the form completely and resolves every
variable, building a tree. While it runs it keeps the interpreter's
environment frames up to date with what is in scope: a lexical variable
or local function is bound to a placeholder, `macrolet` binds the
expander it builds, and `symbol-macrolet` binds its expansion. That is
the environment a macro's `&environment` parameter receives, and it is
how a local binding hides a global macro or symbol macro of the same
name.

The tree records what the second pass has to know before it emits a
binding:

- which variables a closure captures, and which are assigned;
- for each `block` and `tagbody`, whether an exit reaches it from
  another function or through an `unwind-protect`, which makes it
  dynamic: established at run time so the exit can find it;
- for each local exit, whether it passes anything that changes the stack
  depth or the dynamic state on the way out.

The second pass emits each function's code, children first. A form is
compiled for one of four destinations: for effect, one value on the
stack, every value in the values register, or the function's own return.
A call in return position is a tail call.

## Encoding

An instruction is a 32-bit word: the opcode in the low 8 bits and
operand A in the upper 24. An instruction with more operands takes the
words after it. Jump targets are offsets into the function's words.

A call's operand packs the argument count in its low 20 bits and the
mode above it: push the primary value, leave every value in the values
register, or return from the caller with whatever the callee returns.

## Functions

A compiled function is an object in the collected heap holding its code
and the values it closed over. Its code holds:

- the instructions;
- the constants they refer to, in a pool of the function's own, where
  constants that are `equal` share one entry;
- one jump table for each dynamic `tagbody`;
- how many required and optional parameters it takes, whether it takes
  `&rest` or `&key`, how many other slots it needs, and the most values
  its body keeps on the stack at once;
- the symbol each slot was bound for.

`disassemble` lists a compiled function's instructions, one to a line
with its offset and operands, and then its pool under `Constants:`. A
function it is handed that is not compiled yet is compiled first.

A function inside another is kept as a compiled function in the outer
one's constants, closing over nothing. `make_closure` copies its code
into a new function with the values it captures.

Every code object is registered with the evaluator, and their constants
are roots. A compiled function the tenured space holds is not reached by
a collection of the nursery, and neither is what its code refers to.

## Frames

One operand stack, of 2^20 slots, holds every compiled call in progress.
A call pushes the arguments; the callee's frame starts at the first of
them. Slot i of a frame is its parameter i while i is below the number
of positional parameters, and one of its other locals past that. Above
the locals is what the frame is working on.

When a call passes more arguments than there are positional parameters,
which only a function with `&rest` or `&key` accepts, the extra ones are
moved above the locals, where `rest_arg`, `key_arg` and `check_keys`
read them. Positional parameters a call did not supply and every other
local start as NIL, so a collection never reads a stale slot.

A call from one compiled function to another pushes a frame on the same
stack instead of recursing on the host stack. A tail call to a compiled
function replaces the calling frame. A call to a native or an
interpreted function goes through the evaluator, and a compiled function
called from there starts a nested run on the same stack, above what the
outer run holds.

A run of more than 2^19 frames, or one that would pass the end of the
stack, signals `storage-condition`. The last 2^14 slots and 2^12 frames
are kept back for the handlers that run while that is signaled.

A run counts as an evaluation in progress, so no collection moves an
object while one is going. Every slot below the top of the stack is
marked.

## Call caches

Each `call` and `call_global` has a cache of the functions it has
called, numbered by the instruction's last operand. A site starts empty
and is monomorphic once it has called one function. A call to a second
makes it polymorphic, holding up to four. A fifth makes it megamorphic,
after which it looks each callee up in one table the whole machine
shares.

Redefining a global function starts a new epoch, and a cache made in an
older one is empty again: `defun`, `(setf symbol-function)`,
`(setf fdefinition)` and `fmakunbound` all do that. The functions a
cache holds are roots until then, so a function a cache names is never
reclaimed and its address handed to another while the cache could
mistake one for the other. A collection that moves objects empties the
shared table, which is keyed on addresses.

`(%call-site-counters function)` gives one property list for each site
of a compiled function: the state its cache is in, how many calls took
each path, how many missed, and how many times the site turned
polymorphic and megamorphic. `(%call-cache-counters)` adds every site's
counts together.

## Variables

A lexical variable lives in a slot of the frame that binds it. One that
a closure captures and that is also assigned lives in a cell, a cons
whose car holds the value, so every closure over the binding and the
frame itself see one value. A captured variable nothing assigns is
copied into the closure.

A special variable's binding is made on the evaluator's dynamic binding
stack, the one the interpreter uses, and undone when the scope ends or a
non-local exit leaves it. A return from a frame undoes whatever the
frame left bound.

## Values

The values register is the evaluator's list of the values the last form
produced. Most forms are compiled to put their value on the stack, and
only a form whose values someone reads uses the register.

## Non-local exits and handlers

A handler is a record of something a frame established: a dynamic
`block` or `tagbody`, a `catch`, an `unwind-protect`, or the error catch
`handler-case` and `ignore-errors` are built on. It records the stack
depth, the dynamic binding depth and the offset to continue at.

A non-local exit is a Zig error carrying the id of its target, the way
the interpreter makes one: `return_from`, `go` and `throw` raise
`BlockReturn`, `Go` and `Throw`. A failure a native raises, or one the
VM raises itself, is first offered to the `handler-bind` handlers where
it happened, and then unwinds the same way. The VM hands either to the
innermost handler of the run that takes it: the frames above it are
given up, the stack and the dynamic bindings are put back, and execution
continues where the handler says. A run with no handler for it gives up
its frames and passes the error to its caller.

`catch` pushes onto the evaluator's catch stack, so a `throw` from
interpreted code finds a compiled `catch`, and the other way round.

An `unwind-protect` that is left by an exit or a failure runs its
cleanup forms with what was in flight saved on the stack, and
`end_cleanup` raises it again. Left normally, the cleanup forms run with
the protected form's values saved instead.

A local exit that crosses nothing is a jump, after dropping the values
above the target's depth. One that crosses a handler, a dynamic binding
or a region whose depth is not known at compile time restores the depth
and the dynamic state the target recorded on entry, with `unwind`. An
exit through an `unwind-protect` or out of a closure is dynamic.

## Instructions

Stack and constants:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `load_const` | k | push constant k |
| `load_nil`, `load_t` | | push NIL or T |
| `load_fixnum` | n | push n, a signed 24-bit immediate |
| `pop` | | drop the top value |
| `drop` | n | drop the top n values |
| `slide` | n | drop the n values below the top one |
| `dup` | | push the top value again |

Lexical variables, where i is a slot of the frame and c a slot of the
closure:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `load_local`, `store_local` | i | push slot i, pop into slot i |
| `load_closed` | c | push closed-over value c |
| `make_cell` | i | replace slot i with a cell holding its value |
| `load_cell`, `store_cell` | i | through the cell in slot i |
| `load_closed_cell`, `store_closed_cell` | c | through closed-over cell c |

Special variables and definitions, where k is a constant holding a
symbol:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `load_global` | k | push the symbol's value, or signal `unbound-variable` |
| `store_global` | k | pop into the symbol's value |
| `bind_special` | k | pop a value and bind the symbol to it dynamically |
| `unbind` | n | undo the latest n dynamic bindings |
| `save_dynamic`, `restore_dynamic` | i | record the dynamic depth in slot i, undo back to it |
| `save_state` | i | record the stack depth in slot i and the dynamic depth in slot i+1 |
| `progv_bind` | | pop values and symbols and bind them as `progv` does |
| `proclaim` | k, constant | make the symbol special, and constant when the second operand is 1 |
| `jump_if_bound` | k, target | jump when the symbol has a value |
| `load_function` | k | push the symbol's global function, or signal `undefined-function` |
| `store_function` | k | pop into the symbol's function |

Calls and returns:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `make_closure` | k, n | pop n values and close the function in constant k over them |
| `call` | argc, mode | call the function below the arguments |
| `call_global` | k; argc, mode | call the symbol's global function |
| `apply` | argc, mode | as `call`, spreading the last argument |
| `call_counted` | i, mode | as `call`, with the argument count in slot i |
| `return` | | return the top value as the only value |
| `return_mv` | | return what the values register holds |

A call's callee is a function, or a symbol naming one when the call is a
`funcall` or `apply`.

Values:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `to_mv` | | pop a value into the values register |
| `mv_primary` | | push the register's first value, or NIL |
| `values` | n | pop n values into the register |
| `values_list` | | pop a list into the register |
| `mv_list` | | push the register as a list |
| `mv_push` | n | push the register's first n values, NIL for the missing ones |
| `mv_spread` | i | push every value in the register and add their count to slot i |
| `save_mv`, `restore_mv` | | push the register and its count, pop them back |

Control:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `jump` | target | |
| `jump_if_nil`, `jump_if_true` | target | pop a value and jump on it |
| `enter_block` | i, target, level | establish a block, with its id in slot i |
| `enter_tagbody` | i, table, level | establish a tagbody, with its id in slot i |
| `enter_catch` | target, level | pop a tag and establish a catch for it |
| `enter_cleanup` | target, level | establish an `unwind-protect` |
| `enter_errors` | target, kind, level | establish an error catch |
| `leave` | | give up the innermost handler |
| `unwind` | level; slot, keep | give up the frame's handlers from level up, and restore the depths slot recorded, keeping the top value when keep is 1 |
| `return_from` | | pop a block id and exit to it with the register's values |
| `go` | tag | pop a tagbody id and go to its tag |
| `throw` | | pop a tag and throw the register's values to it |
| `end_cleanup` | | end an `unwind-protect`'s cleanup forms |
| `errors_ok` | | put NIL ahead of the register's values |

Arguments and destructuring, where `l` is a slot holding the rest of a
list being taken apart:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `optional_arg` | p, target | jump when argument p was passed |
| `rest_arg` | i | slot i gets the extra arguments as a list |
| `check_keys` | k, allow | check the extra arguments against the keywords in constant k |
| `key_arg` | k; i, target | when keyword k was passed, slot i gets its value and jump |
| `pop_list` | l | push the car of slot l and leave its cdr there |
| `jump_if_atom` | l, target | jump when slot l holds no more list |
| `check_end` | l | signal when slot l is not NIL |
| `list_key` | k; l, i, target | as `key_arg`, in the property list in slot l |
| `check_list_keys` | k; l, allow | as `check_keys`, for the property list in slot l |

Primitives work on fixnums themselves and call the standard function for
anything else, so the result is the one the function gives:

| Instruction | Function |
| --- | --- |
| `add`, `sub` | `+`, `-` of two arguments |
| `less`, `greater`, `less_equal`, `greater_equal`, `num_equal` | `<`, `>`, `<=`, `>=`, `=` of two arguments |
| `inc`, `dec` | `1+`, `1-` |
| `car`, `cdr` | `car`, `cdr` |
| `eq`, `cons`, `not` | `eq`, `cons`, `not` and `null` |

`interpret` k evaluates the form in constant k with the interpreter, in
the null lexical environment. It is what `defmacro`, `in-package`,
`declaim`, and the special forms the compiler does not know become.

## Dispatch

Each instruction has a handler in `vm.zig`, and `-Ddispatch` picks how
the VM goes from one to the next. All three are built from the same
handlers:

- `loop`, the default: one `switch` on the opcode inside a loop.
- `threaded`: a labeled `switch` whose every prong ends with
  `continue` to the next instruction's opcode, so each handler has its
  own jump to the next one. This is what Zig has in place of computed
  `goto`.
- `tail`: a table of one function per instruction, each of which ends
  by tail-calling the next instruction's function.

    tests/run-dispatch-bench.sh

builds each one as `ReleaseFast` and times the compiled Gabriel
benchmarks from cl-bench on it, best of three rounds each. The total,
in milliseconds of processor time, over three runs of the script:

| Measured on | `loop` | `threaded` | `tail` |
| --- | --- | --- | --- |
| macOS, aarch64, 2026-10-24 | 733.2 to 735.3 | 806.6 to 809.8 | 947.7 to 948.0 |

`loop` is the fastest of the three on every run and is the default.

## Speed

    zig build bytecode-bench -Doptimize=ReleaseFast

`tests/lisp/bytecode-bench.lisp` times
`(loop for i from 0 to 1000000 sum i)` interpreted and compiled, taking
the best of five rounds of processor time for each, and fails when the
compiled loop is less than three times as fast.

| Measured on | Interpreted | Compiled | Ratio |
| --- | --- | --- | --- |
| macOS, aarch64, 2026-10-24 | 181.6 ms | 9.0 ms | 20.2x |
