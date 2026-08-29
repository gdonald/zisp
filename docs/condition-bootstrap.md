# Condition bootstrap

Conditions are classes, and zisp has no classes yet. Large parts of the
standard library signal and handle conditions, so the condition system
cannot wait for CLOS. This is the plan for the small class system that
carries it until CLOS lands and takes over.

The whole of it lives in `src/runtime/proto_class.zig`. Nothing else
defines a class, a slot, or a precedence list, so the file name is what a
later grep looks for when CLOS deletes it.

The claim this doc makes is that nothing outside that file has to change
when it goes: the names, the slots, the initargs and the accessors are
the ones CLOS will end up with, and only what is behind them differs.

## What zisp has now

An error is a Zig error value out of `NativeError`: `TypeError`,
`UnboundVariable`, `DivisionByZero`, and the rest. `%catch-error` turns
the one that came out into a keyword named after it, and that keyword is
what `handler-case` hands its clause. `handler-bind` is a stub that
evaluates its handlers and drops them. A handler cannot dispatch on a
type, because a keyword has no type to dispatch on, and it cannot read a
datum, because nothing carries one.

The evaluator records `error_symbol` at the raise sites that know a name,
which is how the driver says which variable was unbound. That is the
only piece of an error's payload that survives today.

## The object

A condition instance is a heap structure, which is the layout
`defstruct` already uses: a header, one `Value` naming what the object
is, and a run of slot values. A `defstruct` instance names itself with a
symbol and a condition names itself with its class object, so the two
are told apart by what that one field holds and the collector needs no
new case.

A class is a heap structure as well, naming itself with the symbol
`%condition-class`. That is what `%condition-class-p` reads, and through
it what `%condition-p` reads.

CLOS keeps this layout. What it replaces is what the field points at.

## The class

A class is a heap object too, holding:

- `name`, the symbol it was defined under.
- `direct_supers`, the list of class objects it was defined over.
- `precedence`, the list of class objects it and its supers linearize to.
- `slots`, the effective slot list, in the order instances store them.
- `report`, the `:report` function or `nil`.

`precedence` is computed once, at definition, by the standard
topological sort: a class precedes its supers, and the supers keep the
order the definition gave them. Conditions may not be redefined here, so
nothing recomputes it. `typep` against a class is a membership test on
`precedence`, and `subtypep` between two classes is the same test.

The hierarchy has no metaclass, no `validate-superclass`, no
`change-class`, no slot with `:allocation :class`, and no multiple
dispatch. A condition needs none of them.

## The slots

An effective slot is a name, the list of initarg keywords that fill it,
an initform closure or `nil`, and the reader and writer function names
`define-condition` was told to generate. `:type` is parsed and ignored,
matching what `defstruct` does today.

The effective slot list is the direct slots of each class in `precedence`
order, least specific first, with a slot named twice keeping the most
specific definition and its original position. An instance stores one
`Value` per effective slot, in that order, so a reader is an index and a
bounds check rather than a search.

A slot that no initarg filled and that has no initform is unbound, which
is a distinct marker value rather than `nil`: `slot-boundp` has to tell
the two apart, and `unbound-slot` is one of the conditions being defined.

## Accessors

`define-condition` generates a native reader per `:reader` and
`:accessor`, closing over the slot index, and a writer per `:accessor`
and `:writer`. They are ordinary functions, not generic functions. A
reader called on an object that is not an instance of the class it came
from signals `type-error`, which is what a real generic function would do
by failing to find a method.

`slot-value` and `(setf slot-value)` work on these instances by looking
the name up in the class's slot list.

## Reporting

A class keeps the function its `:report` option named, and a class with
none of its own uses the nearest one it descends from. `princ`,
`princ-to-string` and `~A` print a condition by running that function,
which is what a program reads. `prin1` and `~S` print `#<TYPE>` instead,
since a condition has no form that reads back.

CLOS replaces this with a `print-object` method, and the two agree on
what comes out.

## Where the Zig errors go

Each member of `NativeError` maps to one condition class, and the raise
sites fill the slots that class defines. Three fields go on the
evaluator alongside `error_symbol`, set at the raise site and read when
the condition is built:

- `error_datum`, the object that was wrong.
- `error_expected`, the type specifier it failed.
- `error_message`, the format control and arguments where the raise site
  had them.

A condition an `error` builds rides through the unwind on the evaluator,
so `%catch-error` and `ignore-errors` hand back the object itself rather
than a name. A failure a native raised carries no object, so those two
hand back the keyword and `%coerce-caught` builds a condition of the type
`*native-condition-types*` maps that name to. Either way what a handler
sees is a condition it can dispatch on and read slots from.

## The handler stack

Handlers live in `*handler-clusters*`, a special variable holding one
cluster per `handler-bind`. Binding it rather than pushing onto a stack
is what unwinds them: a non-local exit out of the body restores the outer
clusters with no cleanup of its own.

`signal` walks the clusters from the innermost outward, calls each
handler whose type the condition belongs to, and carries on past a
handler that returns. Each handler runs with only the clusters outside
its own bound, which is what keeps a condition a handler signals from
reaching that handler again.

`handler-case` is `handler-bind` around a `tagbody`: its handler records
the condition and jumps out, so the clause body runs after the unwind
rather than inside the handler's extent. It also wraps the body in
`%catch-error`, since a failure a native raised never went through the
clusters and can only be caught on the way out.

## What CLOS deletes

`src/runtime/proto_class.zig` is deleted whole. What replaces each
piece:

| Bootstrap | CLOS |
| --- | --- |
| the class object | `standard-class`, through `defclass` |
| `precedence` computed at definition | `compute-class-precedence-list` |
| the effective slot list | `compute-slots` and effective slot definitions |
| generated native readers and writers | generic functions with methods |
| `typep` against a class by list membership | `typep` through the class hierarchy |
| the `report` function | `print-object` |

`define-condition` stays, rewritten over `defclass`. The condition
classes, their slot names, their initargs and their accessors keep the
names they have, so nothing outside this file changes. The instance
layout stays as it is.

## What says it worked

- `tests/lisp/handler-search.lisp`, covering nested `handler-bind` with
  mixed condition types, a handler that declines, mixed
  `handler-bind`/`handler-case` nesting, and a handler that signals a
  different condition.
- The `conditions/` slice of ansi-test, through
  `tests/run-rt-tests.sh conditions`.
- Once CLOS has taken over, `grep -r proto_class src/` finds nothing and
  the same `conditions/` slice still passes.
