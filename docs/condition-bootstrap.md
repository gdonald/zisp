# Conditions as classes

A condition type is a CLOS class, and a condition is an instance of one.
This is how that is put together and how the failures natives raise
become conditions.

## The classes

`condition` is a class whose metaclass is `condition-class`, with `t` as
its only superclass, so a condition is not a `standard-object`. Every
other condition type is a subclass of it with the same metaclass.
`condition-class` is one of the metaclasses whose instances reach their
slots the standard way, so slot access, `make-instance` and dispatch on a
condition take the same routes they take for a `standard-class`.

`define-condition` expands to `defclass` with `(:metaclass
condition-class)`, `condition` standing in for an empty list of parent
types. The slot options and `:default-initargs` are `defclass`'s, so
readers, writers and accessors are generic functions, and a slot's
`:type` is checked on a write.

`make-condition` makes an instance of the class its type names. A
compound type specifier such as `(or program-error type-error)` makes one
of the first condition class that is of that type.

## Reporting

`:report` becomes a `print-object` method on the condition's class that
runs the report when `*print-escape*` is nil and leaves an escaped print
to the method below it. The method on `condition` itself prints
`#<TYPE>`. `princ`, `princ-to-string` and `~A` bind `*print-escape*` to
nil before `print-object` runs, which is how they get the report.

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
than a name. A failure a native raised where no handler was established
carries no object, so those two hand back the keyword and `%coerce-caught` builds a condition of the type
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
`%catch-error`, which is where a failure that unwinds past every handler
is caught.

A failure a native raised goes through the clusters as well. When it
unwinds out of `eval`, the evaluator builds its condition with
`%coerce-caught` and hands it to `%run-handlers`. If every handler
declines, the condition is left in `error_condition`, so the frames
further out pass it on without offering it again and `%catch-error`
hands back that same object.
