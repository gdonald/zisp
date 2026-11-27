# Compiler IR

The compiler turns a function into an intermediate representation, the
IR, before it makes code. The bytecode emitter and the native backend
both start from it. This document defines the IR: its values and their
representations, its control flow, every op, how each op lowers to the
bytecode in `docs/bytecode.md`, and one function followed from source
to aarch64 and x86_64 code.

The passes, in order:

1. `convert.zig` macroexpands the form and builds the tree of nodes, as
   it does now.
2. `infer.zig` gives each node a type, as it does now.
3. Building turns the typed tree of one function into IR.
4. Representation selection decides where a value is kept unboxed.
5. Either lowering to bytecode, or the native backend for x86_64 or
   aarch64. A function the native backend cannot compile yet is lowered
   to bytecode.

## Functions, blocks and values

An IR function belongs to one `Lambda` of the tree. It has:

- its parameters and its frame slots, numbered as the bytecode numbers
  them: slot i is parameter i while i is below the number of positional
  parameters, and another local past that;
- its constants, which become the code object's pool;
- the IR functions of the lambdas inside it, each of which becomes a
  constant that `make_closure` copies;
- its basic blocks, the first of which is the entry.

A basic block is a list of phi nodes, then a list of instructions, then
one terminator. Control enters a block only at its top and leaves only
through its terminator, or through the raise edge described under
"Raising and handlers".

An instruction defines at most one value. A value is defined once and
never assigned, and every use of it is dominated by its definition. A
value has a representation, which says what bits it is, and a type,
which says what Lisp objects it can stand for.

This document writes the IR as text:

    B3:
      %7 = fix_add %3, %4          : val fixnum
      %8 = fix_inc %4              : val fixnum
      jump B1

`%n` is a value, `Bn` a block, a bare number an immediate operand, `k`
a constant, `i` a frame slot and `c` a closed-over value of the
function.

## Value representation

| Representation | Bits | Holds |
| --- | --- | --- |
| `val` | a tagged word, as `docs/tagging.md` lays it out | any Lisp object |
| `sf` | an IEEE 754 binary32 number in the low 32 bits | a single-float, unboxed |
| `bool` | a condition, true or false | the result of a test that has not been made into T or NIL |
| `mv` | the values register | the values a form returned, every one of them |
| `saved` | the values register's contents and count, held in the frame | values put aside while other code runs |
| `spread` | arguments collected in the frame, with their count in a slot | the arguments of a `multiple-value-call` being built |
| `pending` | what an `unwind-protect`'s cleanup forms run with | an exit or failure in flight, or the protected form's saved values |
| none | | an instruction run for its effect |

A fixnum is a `val`. Its tag is 000, so two tagged fixnums add,
subtract and compare as machine words without untagging, and keeping a
fixnum boxed costs nothing. Only multiplication untags one operand. A
double-float, bignum, ratio or complex is a `val` pointing into the
heap.

A single-float is a `val` with its bits in the high 32. Unboxing one is
a shift right by 32 and boxing one a shift left by 32 and an or of the
tag 110, so boxing never allocates. Arithmetic is done on `sf` values,
which sit in floating-point registers in native code.

### Types

Every value carries one of the types `infer.zig` uses: `unknown`, a
fixnum range `fixnum[lo,hi]`, or `single_float`. A type is a claim the
compiler relies on, and the representation follows from it.

- Building copies each node's type onto the value it defines.
- A constant's type is its own: `fixnum[n,n]` for a fixnum n,
  `single_float` for a single-float.
- `check_type` and `unbox_sf` give their result the type they check or
  assume.
- A phi for a declared variable has the declared type. A phi for any
  other variable has the join of its incoming values' types when none
  of them comes in along a loop's back edge, and `unknown` otherwise.
  The IR does not iterate to a fixed point, so it finds no type the tree
  pass did not find.
- `bool`, `mv`, `saved`, `spread` and `pending` values have no type.

Building sets the types and no later pass changes them. Representation
selection, lowering and the native backend read them.

### Representation selection

Building emits `sf_` ops where `infer.zig` found every operand to be a
single-float, which is where `emit.zig` emits the `_single_floats`
instructions. An operand that is a `val` gets an `unbox_sf` in front of
it, and an `sf` result that flows into an op that takes a `val` gets a
`box_sf` after it. Representation selection then moves the boxing out
of loops:

- a phi whose every incoming value is `box_sf %x` is rewritten to a phi
  of the `%x` values, of representation `sf`, followed by one `box_sf`
  of the new phi for the uses that want a `val`;
- `unbox_sf (box_sf %x)` is replaced by `%x`;
- a `box_sf` or `unbox_sf` with no uses is removed.

In the float dot product of `tests/lisp/unboxing-bench.lisp` this leaves
the running sum in a floating-point register for the whole loop.

Comparisons give a `bool`. A `bool` used as a branch condition is
consumed there. A `bool` used as data goes through `box_bool`, which
gives T or NIL.

### Values and the collector

The collector is precise, never moves an object while a VM run is in
progress, and marks every VM stack slot below the top. An instruction
that can allocate or raise is a safepoint, since raising runs the
`handler-bind` handlers, which can run any Lisp code. At a safepoint:

- every `val` that is live after it is in a VM frame slot below the
  stack top;
- no frame slot below the top holds an `sf` or anything else that is not
  a tagged word. An `sf` value live across a safepoint is boxed into a
  slot and unboxed after.

Bytecode keeps every value on the VM stack or in a slot, so this holds
for it. The native backend's register allocator stores live `val`
registers to slots before each safepoint, as in the example at the end.
Values do not have to be loaded back after one, since nothing moved.

## Storage that is not SSA

Some variables stay in frame slots or cells instead of becoming values,
and are read and written with the slot ops:

- a variable a closure captures and something assigns lives in a cell,
  as it does now;
- a variable assigned inside a handler region and used outside it, or
  in a landing block, lives in its frame slot. A raise can leave the
  region from any raising instruction in it, and the variable's value at
  that point is in its slot, where the landing block reads it;
- a special variable is read and written with the global ops;
- the state slots `save_state` and `save_dynamic` write, the id slot of
  a dynamic `block` or `tagbody`, and the list slot a destructuring
  pattern takes apart.

Every other lexical variable becomes SSA values: its binding and each
`setq` of it define a new value, and a block where two of its
definitions meet starts with a phi for it. A captured variable nothing
assigns is a value, copied into the closure by `make_closure`.

## Control flow

### Blocks and phis

A phi `%n = phi [Ba: %x] [Bb: %y]` takes the value from whichever
predecessor control came from. Each predecessor appears in it once.
Phis read their inputs at the end of the predecessor, all at once, so
the order of phis in a block does not matter.

A phi of representation `mv` is allowed when each incoming value is the
last `mv` its predecessor made. It costs nothing: every predecessor
leaves its values in the one values register.

### Terminators

| Terminator | Operands | Successors |
| --- | --- | --- |
| `jump` | | B |
| `branch` | `%c`: `val` (NIL is false) or `bool` | Btrue, Bfalse |
| `branch_unbound` | `%v`: `val` | Bunbound, Bbound |
| `branch_bound` | k: symbol | Bbound, Bunbound |
| `branch_atom` | l: slot | Batom, Bcons |
| `return` | `%v`: `val` | |
| `return_mv` | `%m`: `mv` | |
| `call`, `call_global`, `apply`, `call_spread` in tail mode | as the call | |
| `return_from` | `%id`: `val`, `%m`: `mv` | |
| `go` | `%id`: `val`, tag index | |
| `throw` | `%tag`: `val`, `%m`: `mv` | |
| `end_cleanup` | `%p`: `pending` | B |

`return_from`, `go` and `throw` never fall through: they raise, and the
raise goes to whatever handler takes it. `end_cleanup` raises again what
was in flight, and continues to B when the protected form was left
normally.

### Raising and handlers

An op marked "raises" in the tables below can signal or exit
non-locally. Each block records the innermost handler in effect where
it starts, established by one of the `enter_` ops and given up by
`leave` or `unwind`. A raising op has an edge to the landing block of
that handler, besides its normal successor. When the raise is for this
handler, control goes to its landing block, and when it is not, control
goes to the next handler out, and from the outermost one out of the
function. Building puts the instruction after a raising op in the same
block, so raise edges are not block boundaries.

A landing block starts with one `landing` instruction and has no phis.
Nothing in it uses a value defined inside the region, because building
keeps every variable assigned in the region in a slot. Values defined
before the `enter_` op dominate the landing block and are used
directly. A raise edge carries no value to the landing block other than
what `landing` gives.

| Handler | Landing gives |
| --- | --- |
| `enter_block` | `mv`: the values `return_from` passed |
| `enter_tagbody` | nothing: control lands at the block for the tag `go` named |
| `enter_catch` | `mv`: the values `throw` passed |
| `enter_cleanup` | `pending`: the exit or failure in flight |
| `enter_errors` | `mv`: `(values nil condition)` for `ignore-errors`, the condition for `handler-case` |

## Ops

The tables give each op's operands and result. An operand written `%v:
val` is a value of that representation. "Raises" is yes where the op
can signal, exit non-locally or call Lisp code, which also makes it a
safepoint. An op that allocates and does not raise is a safepoint too,
and the tables say so.

### Constants

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `const` | k: any object | `val` | no |
| `const_sf` | f: binary32 bits | `sf` | no |

### Parameters and arguments

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `param` | p: parameter number | `val`: the argument, or the unbound marker for an optional parameter that was not passed | no |
| `rest_arg` | | `val`: the arguments past the positional ones, as a list | allocates |
| `check_keys` | k: vector of keywords, allow: 0 or 1 | none | yes |
| `key_arg` | k: keyword | `val`: the value passed for it, or the unbound marker | no |

### Destructuring

The list being taken apart is in slot l.

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `pop_list` | l | `val`: the car of slot l, leaving its cdr there | yes, when slot l is not a cons |
| `check_end` | l | none | yes, when slot l is not NIL |
| `list_key` | k: keyword, l | `val`: its value in the property list, or the unbound marker | no |
| `check_list_keys` | k: vector of keywords, l, allow | none | yes |

### Slots, cells and closed-over values

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `load_slot` | i | `val` | no |
| `store_slot` | i, `%v: val` | none | no |
| `make_cell` | i | none: slot i now holds a cell with its old value | allocates |
| `load_cell` | i | `val` | no |
| `store_cell` | i, `%v: val` | none | no |
| `load_closed` | c | `val` | no |
| `load_closed_cell` | c | `val` | no |
| `store_closed_cell` | c, `%v: val` | none | no |

### Globals, specials and definitions

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `load_global` | k: symbol | `val` | yes, `unbound-variable` |
| `store_global` | k: symbol, `%v: val` | none | no |
| `load_function` | k: symbol | `val` | yes, `undefined-function` |
| `store_function` | k: symbol, `%v: val` | none | no |
| `proclaim` | k: symbol, constant: 0 or 1 | none | no |
| `bind_special` | k: symbol, `%v: val` | none | allocates |
| `unbind` | n | none | no |
| `save_dynamic` | i | none: slot i gets the dynamic depth | no |
| `restore_dynamic` | i | none | no |
| `save_state` | i | none: slots i and i+1 get the stack and dynamic depths | no |
| `progv_bind` | `%symbols: val`, `%values: val` | none | yes |

### Closures and calls

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `make_closure` | k: IR function, `%v...: val` | `val` | allocates |
| `call` | `%f: val`, `%a...: val`, mode | `val` in single mode, `mv` in multiple mode | yes |
| `call_global` | k: symbol, `%a...: val`, mode | as `call` | yes |
| `apply` | `%f: val`, `%a...: val`, mode | as `call` | yes |
| `spread_start` | | `spread` | no |
| `spread` | `%s: spread`, `%m: mv` | `spread` | no |
| `call_spread` | `%f: val`, `%s: spread`, mode | as `call` | yes |

The mode is single, multiple or tail. A call in tail mode is a
terminator and has no result.

### Multiple values

An `mv` value is the values register, and it is good only until the
next op that writes the register: another op that gives an `mv`, a call,
or a raising op. Building puts each use of an `mv` before that point,
and `save_mv` keeps values longer.

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `to_mv` | `%v: val` | `mv` | no |
| `values` | `%v...: val` | `mv` | no |
| `values_list` | `%l: val` | `mv` | yes, when `%l` is not a proper list |
| `mv_primary` | `%m: mv` | `val`: the first value, or NIL | no |
| `mv_ref` | `%m: mv`, j | `val`: value j, or NIL | no |
| `mv_list` | `%m: mv` | `val` | allocates |
| `save_mv` | `%m: mv` | `saved` | allocates |
| `restore_mv` | `%s: saved` | `mv` | no |
| `errors_ok` | `%m: mv` | `mv`: NIL ahead of the values | no |

### Handlers

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `enter_block` | i: id slot, Bland | none | allocates |
| `enter_tagbody` | i: id slot, Btag... | none | allocates |
| `enter_catch` | `%tag: val`, Bland | none | allocates |
| `enter_cleanup` | Bcleanup | none | no |
| `enter_errors` | kind, Bfail | none | no |
| `leave` | | none | no |
| `unwind` | level, i: state slot | none | no |
| `landing` | | `mv`, `pending` or none, by handler | no |
| `pending_normal` | `%s: saved` | `pending` | no |

Each `enter_` op also carries its level, the number of the function's
handlers in effect where it runs, which building counts.

### Generic primitives

Each works on fixnums, on two single-floats for `add`, `sub` and `mul`,
and calls the standard function for anything else.

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `add`, `sub`, `mul` | `%a: val`, `%b: val` | `val` | yes |
| `inc`, `dec` | `%a: val` | `val` | yes |
| `less`, `greater`, `less_equal`, `greater_equal`, `num_equal` | `%a: val`, `%b: val` | `bool` | yes |
| `eq` | `%a: val`, `%b: val` | `bool` | no |
| `not` | `%a: val` | `bool` | no |
| `cons` | `%a: val`, `%b: val` | `val` | allocates |
| `car`, `cdr` | `%a: val` | `val` | yes, when `%a` is not a list |

### Fixnum primitives

Every operand has a fixnum type. A result outside the fixnums is made
into a bignum by the standard function, so these raise only through
that call, which allocates.

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `fix_add`, `fix_sub`, `fix_mul` | `%a: val`, `%b: val` | `val` | on overflow |
| `fix_inc`, `fix_dec` | `%a: val` | `val` | on overflow |
| `fix_less`, `fix_greater`, `fix_less_equal`, `fix_greater_equal`, `fix_num_equal` | `%a: val`, `%b: val` | `bool` | no |

An op whose result range, from `infer.zig`, lies within the fixnums
cannot overflow, and has no overflow path in native code.

### Single-float primitives

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `sf_add`, `sf_sub`, `sf_mul` | `%a: sf`, `%b: sf` | `sf` | on overflow or underflow, through the standard function |
| `sf_less`, `sf_greater`, `sf_less_equal`, `sf_greater_equal`, `sf_num_equal` | `%a: sf`, `%b: sf` | `bool` | no |

### Conversions and checks

| Op | Operands | Result | Raises |
| --- | --- | --- | --- |
| `box_sf` | `%a: sf` | `val` | no |
| `unbox_sf` | `%a: val`, of type `single_float` | `sf` | no |
| `box_bool` | `%a: bool` | `val`: T or NIL | no |
| `check_type` | `%v: val`, k: type specifier | `val`: `%v`, with the checked type | yes, `type-error` |
| `interpret` | k: form | `mv` | yes |

## Building from the tree

Each node becomes these ops. Where a node is compiled for effect, its
result is not used, and an op with no other effect and no uses is
removed.

| Node | Ops |
| --- | --- |
| `constant` | `const` |
| `local_ref`, `local_set` | the variable's current value and a new one, or the slot ops |
| `global_ref`, `global_set` | `load_global`, `store_global` |
| `function_ref` | `load_function` |
| `call_global`, `call`, `apply` | the call op, in the mode the node's destination gives |
| `primitive` | the generic, fixnum or single-float op, as `emit.zig` picks the instruction |
| `if_` | `branch` to two blocks that meet in a third, with a phi for each variable assigned in either branch and one for the value |
| `progn` | its forms in order |
| `let` | each binding's value, then `bind_special` for a special one, and `unbind` after the body unless the body returns |
| `lambda` | `make_closure` |
| `local_functions` | `make_closure` for each, through cells for `labels` functions a closure captures |
| `block` | nothing, when it is not dynamic. A dynamic one is `enter_block` and a landing block |
| `return_from` | a jump to the block's end with the value, `unwind` first where the exit crosses state, or the `return_from` terminator for a dynamic exit |
| `tagbody` | a block for each tag, and `enter_tagbody` when it is dynamic |
| `go` | a jump to the tag's block, `unwind` first where needed, or the `go` terminator |
| `catch_`, `throw` | `enter_catch`, `throw` |
| `unwind_protect` | `enter_cleanup`, `save_mv` and `pending_normal` on the normal path, the cleanup block, `end_cleanup` |
| `errors` | `enter_errors`, and `errors_ok` on the normal path for `handler-case` |
| `values`, `values_list`, `mv_list` | the op of that name |
| `mv_call` | `spread_start`, a `spread` per argument form, `call_spread` |
| `mv_prog1` | `save_mv`, the other forms, `restore_mv` |
| `mv_bind` | `mv_ref` for each variable |
| `progv` | `save_dynamic`, `progv_bind`, the body, `restore_dynamic` |
| `destructure` | `store_slot` of the list, then the destructuring ops |
| `interpret` | `interpret` |
| `the_` | `check_type` where it checks, and nothing else |
| `define_function` | `make_closure`, `store_function`, and `call_global` of `%PUT-INLINE-EXPANSION` when it has an expansion |
| `define_variable` | `proclaim`, `branch_bound` for `defvar`, `store_global` |

A `block` or `tagbody` that needs its state recorded gets `save_state`
at its start, where `convert.zig` marks it as needing one, so the slots
are numbered as they are now.

## Lowering to bytecode

### Blocks

Blocks are laid out in the order building made them, which is source
order. A block no path from the entry reaches is left out. A `jump` to
the block laid out next is left out. A `branch` to two blocks the first
of which comes next is `jump_if_nil` to the other, and otherwise
`jump_if_nil` to the false block and `jump` to the true one.

### Where each value is kept

The bytecode machine keeps values on its operand stack or in frame
slots. Lowering gives each value one place:

- the stack, when the value has one use, in its own block, and every
  value defined after it and before that use is used up first. Building
  from a tree makes nearly every value like this, and lowering pushes it
  where it is defined and the op that uses it pops it;
- its variable's slot, for a value that is a definition of a lexical
  variable or a phi for one, when no other value of that variable is
  live where it is defined. Lowering stores it there where it is
  defined, and loads it at each use;
- a hidden slot, for any other value.

A value kept in a slot whose definition is followed at once by a use on
the stack is stored with `dup` and the store, as `(print (setq x 1))`
does now.

### Phis

A phi's place is a slot: its variable's, or a hidden one. Each
predecessor stores its incoming value into that slot before its
terminator. When the incoming value is a definition of the same
variable, it was already stored there and nothing is added. Where a
predecessor stores several phis, it stores them in the order their
values are on the stack, top first. An `mv` phi needs no store.

### `unwind` and the stack

The stack depth at each point is known from the places above. Where
control goes to a block at a smaller depth without an `unwind`, lowering
adds `drop n`, or `slide n` when the value on top goes along. An
`unwind` keeps the top value when the target block's place for it is
the stack.

### Each op

Where an op's operand is "on the stack", it was pushed by its own
definition or loaded from its place, in operand order, before the op.

#### `const`

`load_nil` for NIL, `load_t` for T, `load_fixnum n` for a fixnum within
the signed 24-bit range, and `load_const k` for anything else.

#### `const_sf`

`load_const k`, where k is the single-float.

#### `param`

Nothing: parameter p is in slot p. Its uses load slot p.

#### `rest_arg`

`rest_arg i`, where i is the slot the result is kept in.

#### `check_keys`

`check_keys k`, with allow in the next word.

#### `key_arg`

A `key_arg` whose one use is a `branch_unbound` is lowered with it:
`key_arg k` followed by the words i and target, where i is the slot of
the phi the value flows into and target is the bound successor. The
unbound successor follows, and stores the default into slot i.

#### `pop_list`

`pop_list l`.

#### `check_end`

`check_end l`.

#### `list_key`

With its `branch_unbound`, as `key_arg` is: `list_key k`, then the
words l, i and target.

#### `check_list_keys`

`check_list_keys k`, then the words l and allow.

#### `load_slot`, `store_slot`

`load_local i`, `store_local i`.

#### `make_cell`

`make_cell i`.

#### `load_cell`, `store_cell`

`load_cell i`, `store_cell i`.

#### `load_closed`

`load_closed c`.

#### `load_closed_cell`, `store_closed_cell`

`load_closed_cell c`, `store_closed_cell c`.

#### `load_global`, `store_global`

`load_global k`, `store_global k`.

#### `load_function`, `store_function`

`load_function k`, `store_function k`.

#### `proclaim`

`proclaim k`, with the constant flag in the next word.

#### `bind_special`

The value on the stack, then `bind_special k`.

#### `unbind`

`unbind n`. A return from the frame undoes its bindings, so an `unbind`
directly before `return`, `return_mv` or a tail call is left out.

#### `save_dynamic`, `restore_dynamic`

`save_dynamic i`, `restore_dynamic i`.

#### `save_state`

`save_state i`.

#### `progv_bind`

Symbols and values on the stack, then `progv_bind`.

#### `make_closure`

The captured values on the stack, then `make_closure k` with their
count in the next word.

#### `call`

The function and the arguments on the stack, then `call` with the
argument count and mode in operand A and the next call-site number in
the next word. In tail mode, `return_mv` follows, for a callee the
machine cannot replace the frame with.

#### `call_global`

The arguments on the stack, then `call_global k`, the argument count
and mode, and the call-site number. In tail mode, `return_mv` follows.

#### `apply`

As `call`, with `apply` and no call-site word.

#### `spread_start`

`load_fixnum 0` and `store_local i`, where i is a hidden slot that
counts the arguments.

#### `spread`

`mv_spread i`, with the same slot.

#### `call_spread`

`call_counted i` with the mode, after the function and every `spread`
have pushed their values.

#### `to_mv`

`to_mv`.

#### `values`

The values on the stack, then `values n`.

#### `values_list`

`values_list`.

#### `mv_primary`

`mv_primary`.

#### `mv_ref`

The `mv_ref`s of one `mv` for j from 0 to n-1, in a row, are one
`mv_push n`, which leaves value 0 lowest on the stack.

#### `mv_list`

`mv_list`.

#### `save_mv`, `restore_mv`

`save_mv`, `restore_mv`. A `saved` value is two stack entries, the
values and their count.

#### `errors_ok`

`errors_ok`.

#### `enter_block`

`enter_block i`, then the words for the landing block's offset and the
level.

#### `enter_tagbody`

`enter_tagbody i`, then the words for the jump table's number and the
level. The table holds the offset of each tag's block.

#### `enter_catch`

The tag on the stack, then `enter_catch` with the landing block's
offset in operand A, then the level.

#### `enter_cleanup`

`enter_cleanup` with the cleanup block's offset in operand A, then the
level.

#### `enter_errors`

`enter_errors` with the failure block's offset in operand A, then the
kind and the level.

#### `leave`

`leave`.

#### `unwind`

`unwind level`, then a word holding the state slot, with the keep flag
at bit 23.

#### `landing`

Nothing. The machine puts the values in the register, or the in-flight
exit on the stack, before it continues at the block.

#### `pending_normal`

`load_fixnum -1`, on top of the two entries `save_mv` pushed. That is
the marker `end_cleanup` reads as a normal exit.

#### `add`, `sub`, `mul`, `inc`, `dec`

`add`, `sub`, `mul`, `inc`, `dec`.

#### `less`, `greater`, `less_equal`, `greater_equal`, `num_equal`

`less`, `greater`, `less_equal`, `greater_equal`, `num_equal`. These
push T or NIL, which is how every `bool` is kept in bytecode.

#### `eq`, `not`, `cons`, `car`, `cdr`

`eq`, `not`, `cons`, `car`, `cdr`. A `branch` on a `not` whose one use
is the branch is `jump_if_true` on the operand of the `not`.

#### `fix_add`, `fix_sub`, `fix_mul`, `fix_inc`, `fix_dec`

`add_fixnums`, `sub_fixnums`, `mul_fixnums`, `inc_fixnum`,
`dec_fixnum`.

#### `fix_less`, `fix_greater`, `fix_less_equal`, `fix_greater_equal`, `fix_num_equal`

`less_fixnums`, `greater_fixnums`, `less_equal_fixnums`,
`greater_equal_fixnums`, `num_equal_fixnums`.

#### `sf_add`, `sf_sub`, `sf_mul`

`add_single_floats`, `sub_single_floats`, `mul_single_floats`. These
read and write boxed single-floats, so an `sf` value is kept boxed in
bytecode.

#### `sf_less`, `sf_greater`, `sf_less_equal`, `sf_greater_equal`, `sf_num_equal`

`less_single_floats`, `greater_single_floats`,
`less_equal_single_floats`, `greater_equal_single_floats`,
`num_equal_single_floats`.

#### `box_sf`, `unbox_sf`, `box_bool`

Nothing. Bytecode keeps single-floats boxed and conditions as T or NIL
already.

#### `check_type`

`check_type k`, which leaves the value on the stack as the result.

#### `interpret`

`interpret k`.

#### `jump`

`jump target`, unless the target is laid out next.

#### `branch`

As under "Blocks".

#### `branch_unbound`

On a `param`: `optional_arg p` with the bound block's offset in the next
word, falling into the unbound block. On a `key_arg` or `list_key`, as
lowered with it above.

#### `branch_bound`

`jump_if_bound k` with the bound block's offset in the next word.

#### `branch_atom`

`jump_if_atom l` with the atom block's offset in the next word.

#### `return`, `return_mv`

`return`, `return_mv`.

#### `return_from`

The values in the register and the block id on the stack, then
`return_from`.

#### `go`

The tagbody id on the stack, then `go` with the tag index.

#### `throw`

The tag on the stack and the values in the register, then `throw`.

#### `end_cleanup`

`end_cleanup`, followed by the block it continues to.

## Native code

Native code for a function is called by the VM, or by other native
code, after its frame has been set up as for a bytecode function: the
arguments are in the first slots, every other local is NIL, and the VM
stack top is past the locals. Its arguments are, in the platform's C
calling convention:

- the address of a context record, with fields `CTX_STACK` (address of
  VM stack slot 0), `CTX_SP` (the VM stack top, as an index),
  `CTX_DYNAMIC` (the evaluator's dynamic binding depth) and `CTX_NIL`;
- the address of the frame's slot 0.

It returns two words, in x0 and x1 on aarch64 and rax and rdx on
x86_64: a value and a status. Status 0 means the value is the one value
returned. Status 1 means the values are in the values register. Status
2 means an error or a non-local exit is in flight, held in the context
record, and the caller handles it as the VM handles a Zig error: at the
innermost handler that takes it, or by returning status 2 itself. A
non-local exit through native frames is a chain of returns, so no
unwinder walks them.

A runtime entry the native code calls for a slow path returns a value
and a status the same way. `zisp_fallback(ctx, which, args, count)`
calls the standard function for a primitive, as `VM.fallback` does, with
its arguments in frame slots so they are marked.

The prologue raises the VM stack top by the number of spill slots the
function needs and fills them with NIL. Every slot native code writes
is below the top, so a collection marks it. The VM pops the frame when
the function returns.

## Example: `sum-below`

`tests/disassemble-golden/sum-below.lisp`:

```lisp
(defun sum-below (limit)
  (declare (type (integer 0 1000000) limit)
           (optimize (safety 0)))
  (let ((sum 0)
        (i 0))
    (declare (type fixnum sum i))
    (tagbody
     next
       (when (>= i limit)
         (return-from sum-below sum))
       (setq sum (+ sum i))
       (setq i (1+ i))
       (go next))))
```

`(sum-below 10)` returns 45.

### Tree and types

The block `sum-below` is not dynamic and is in tail position, so the
`return-from` is a return. The tagbody is not dynamic. `limit` has the
type `fixnum[0,1000000]`. `sum` and `i` are declared `fixnum` and are
assigned, so their phis have the type of the whole fixnum range.
`(+ sum i)` and `(1+ i)` can overflow, so their results are `unknown`. Safety is 0, so no declaration is
checked.

Slots: 0 is `LIMIT`, 1 and 2 are the block's state, 3 is `I` and 4 is
`SUM`.

### IR

```
B0:
  %0 = param 0                    : val fixnum[0,1000000]   ; LIMIT
  save_state 1
  %1 = const 0                    : val fixnum[0,0]         ; SUM
  %2 = const 0                    : val fixnum[0,0]         ; I
  jump B1

B1:                                                         ; tag NEXT
  %3 = phi [B0: %1] [B3: %6]      : val fixnum              ; SUM
  %4 = phi [B0: %2] [B3: %7]      : val fixnum              ; I
  %5 = fix_greater_equal %4, %0   : bool
  branch %5, B2, B3

B2:
  return %3

B3:
  %6 = fix_add %3, %4             : val unknown             ; SUM
  %7 = fix_inc %4                 : val unknown             ; I
  jump B1
```

Building also made a block after the tagbody for its NIL result, and
one for the `when` with no `else`. No path reaches the first, since the
tagbody ends in a `go`, and the second is empty and folded into the
`branch`, so neither is in the IR.

### Bytecode

Places: `%0` is slot 0. `%1` and `%2` are definitions of `SUM` and `I`
and go to slots 4 and 3, and so do the phis `%3` and `%4` and the new
definitions `%6` and `%7`, since no two values of one variable are live
at once. `%5` is used by the next op and stays on the stack.

B0 pushes `%1` and `%2` and stores the phis' slots, top first: `I`,
then `SUM`. B3's definitions were stored to the phis' slots where they
were made, so its `jump` adds no stores.

```
    0  SAVE_STATE 1
    1  LOAD_FIXNUM 0
    2  LOAD_FIXNUM 0
    3  STORE_LOCAL 3  ; I
    4  STORE_LOCAL 4  ; SUM
    5  LOAD_LOCAL 3  ; I
    6  LOAD_LOCAL 0  ; LIMIT
    7  GREATER_EQUAL_FIXNUMS
    8  JUMP_IF_NIL 11
    9  LOAD_LOCAL 4  ; SUM
   10  RETURN
   11  LOAD_LOCAL 4  ; SUM
   12  LOAD_LOCAL 3  ; I
   13  ADD_FIXNUMS
   14  STORE_LOCAL 4  ; SUM
   15  LOAD_LOCAL 3  ; I
   16  INC_FIXNUM
   17  STORE_LOCAL 3  ; I
   18  JUMP 5
```

`emit.zig` today makes the same code with three more words, all of
which no path reaches: a `JUMP 12` after the `RETURN`, and `LOAD_NIL`
and `RETURN` for the tagbody's result.
`tests/disassemble-golden/sum-below.expected` holds that listing, and
changes to the one above when the IR replaces `emit.zig`.

### Native code

Nothing in the loop is a safepoint except the two overflow paths, so
`LIMIT`, `SUM` and `I` stay in callee-saved registers. Their values are
tagged fixnums: the compare is a signed compare of the two words, the
add is an add of the two words, and `1+` adds 8, which is 1 shifted
left 3. A tagged fixnum has the range of a 64-bit word shifted right 3,
so a 64-bit signed overflow of the tagged add is a fixnum overflow, and
the overflow flag tests it.

The function needs two spill slots for the operands of a fallback call,
slots 5 and 6. At the `fix_add` slow path, `I` is live and is one of the
two operands, and `LIMIT` is in slot 0, which nothing assigns. At the
`fix_inc` slow path, `SUM` is live and is stored to its slot 4 first.

aarch64:

```
sum_below:                          ; x0 = context, x1 = slot 0
    stp   x29, x30, [sp, #-64]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    stp   x21, x22, [sp, #32]
    str   x23, [sp, #48]
    mov   x19, x0                   ; context
    mov   x20, x1                   ; frame
    ldr   x9, [x19, #CTX_SP]        ; two spill slots, NIL
    add   x9, x9, #2
    str   x9, [x19, #CTX_SP]
    ldr   x10, [x19, #CTX_NIL]
    stp   x10, x10, [x20, #40]
    sub   x9, x9, #2                ; save_state 1: stack depth
    lsl   x9, x9, #3                ;   as a fixnum
    str   x9, [x20, #8]
    ldr   x9, [x19, #CTX_DYNAMIC]   ;   and dynamic depth
    lsl   x9, x9, #3
    str   x9, [x20, #16]
    ldr   x23, [x20]                ; %0 LIMIT
    mov   x21, #0                   ; %1 SUM
    mov   x22, #0                   ; %2 I
B1:
    cmp   x22, x23                  ; %5 = fix_greater_equal I, LIMIT
    b.ge  B2
    adds  x9, x21, x22              ; %6 = fix_add SUM, I
    b.vs  add_overflow
    mov   x21, x9
after_add:
    adds  x9, x22, #8               ; %7 = fix_inc I
    b.vs  inc_overflow
    mov   x22, x9
    b     B1
B2:
    mov   x0, x21                   ; return SUM
    mov   x1, #0                    ; status: one value
epilogue:
    ldr   x23, [sp, #48]
    ldp   x21, x22, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #64
    ret
add_overflow:
    stp   x21, x22, [x20, #40]      ; operands to slots 5 and 6
    mov   x0, x19
    mov   w1, #FALLBACK_ADD
    add   x2, x20, #40
    mov   x3, #2
    bl    zisp_fallback
    cbnz  x1, epilogue              ; status 2 goes to the caller
    mov   x21, x0                   ; the bignum
    b     after_add
inc_overflow:
    str   x21, [x20, #32]           ; SUM is live: slot 4
    str   x22, [x20, #40]           ; operand to slot 5
    mov   x0, x19
    mov   w1, #FALLBACK_INC
    add   x2, x20, #40
    mov   x3, #1
    bl    zisp_fallback
    cbnz  x1, epilogue
    mov   x22, x0
    b     B1
```

x86_64, System V:

```
sum_below:                          ; rdi = context, rsi = slot 0
    push  rbx
    push  r12
    push  r13
    push  r14
    push  r15
    mov   rbx, rdi                  ; context
    mov   r12, rsi                  ; frame
    add   qword [rbx + CTX_SP], 2   ; two spill slots, NIL
    mov   rax, [rbx + CTX_NIL]
    mov   [r12 + 40], rax
    mov   [r12 + 48], rax
    mov   rax, [rbx + CTX_SP]       ; save_state 1: stack depth
    sub   rax, 2
    shl   rax, 3                    ;   as a fixnum
    mov   [r12 + 8], rax
    mov   rax, [rbx + CTX_DYNAMIC]  ;   and dynamic depth
    shl   rax, 3
    mov   [r12 + 16], rax
    mov   r15, [r12]                ; %0 LIMIT
    xor   r13d, r13d                ; %1 SUM
    xor   r14d, r14d                ; %2 I
.B1:
    cmp   r14, r15                  ; %5 = fix_greater_equal I, LIMIT
    jge   .B2
    mov   rax, r13                  ; %6 = fix_add SUM, I
    add   rax, r14
    jo    .add_overflow
    mov   r13, rax
.after_add:
    mov   rax, r14                  ; %7 = fix_inc I
    add   rax, 8
    jo    .inc_overflow
    mov   r14, rax
    jmp   .B1
.B2:
    mov   rax, r13                  ; return SUM
    xor   edx, edx                  ; status: one value
.epilogue:
    pop   r15
    pop   r14
    pop   r13
    pop   r12
    pop   rbx
    ret
.add_overflow:
    mov   [r12 + 40], r13           ; operands to slots 5 and 6
    mov   [r12 + 48], r14
    mov   rdi, rbx
    mov   esi, FALLBACK_ADD
    lea   rdx, [r12 + 40]
    mov   ecx, 2
    call  zisp_fallback
    test  rdx, rdx
    jnz   .epilogue                 ; status 2 goes to the caller
    mov   r13, rax                  ; the bignum
    jmp   .after_add
.inc_overflow:
    mov   [r12 + 32], r13           ; SUM is live: slot 4
    mov   [r12 + 40], r14           ; operand to slot 5
    mov   rdi, rbx
    mov   esi, FALLBACK_INC
    lea   rdx, [r12 + 40]
    mov   ecx, 1
    call  zisp_fallback
    test  rdx, rdx
    jnz   .epilogue
    mov   r14, rax
    jmp   .B1
```

The five pushes and the return address leave the stack 16-byte aligned
at each `call`, as System V requires.

The state `save_state` records is not read by anything in this
function, since no `unwind` crosses state here. It is kept so the frame
matches the bytecode one, and with it the slot numbers.

Once `SUM` holds a bignum after an overflow, the next `fix_add` treats
it as a fixnum. Safety 0 trusts the `fixnum` declaration, and the VM's
`ADD_FIXNUMS` does the same.
