# Conditions

A condition is an object describing something that happened, and a
handler is a function that gets offered one. Signaling and handling are
separate: what signals decides what to say, and what handles decides what
to do about it.

`docs/condition-bootstrap.md` covers how the class layer underneath is
built and what CLOS replaces it with.

## Defining one

`define-condition` takes a name, the types it is built on, its slots, and
options:

```lisp
(define-condition parse-failed (error)
  ((line :initarg :line :reader parse-failed-line)
   (text :initarg :text :initform "" :reader parse-failed-text))
  (:report (lambda (condition stream)
             (format stream "line ~a: ~a"
                     (parse-failed-line condition)
                     (parse-failed-text condition)))))
```

A slot takes `:initarg`, `:initform`, `:reader`, `:writer`, `:accessor`,
`:type` and `:documentation`. `:type` is accepted and not enforced, which
is what `defstruct` does as well. A slot no initarg filled and with no
initform is unbound rather than nil.

`:report` takes a string, which reports itself, or a function of the
condition and a stream. A type with no report of its own uses the nearest
one it is built on.

`:default-initargs` supplies initargs `make-condition` falls back to.

Every type in the standard hierarchy is defined, from `condition` down
through `error`, `warning`, `type-error`, `unbound-variable`,
`reader-error` and the rest, with the readers the standard names for
each.

## Making and printing one

`(make-condition 'parse-failed :line 12)` builds one. `conditionp` says
whether an object is one, and `typep` and `subtypep` answer for condition
types the way they do for any other.

`princ`, `princ-to-string` and `~A` print a condition by running its
report. `prin1` and `~S` print `#<PARSE-FAILED>`, since a condition has
no form that reads back.

## Signaling

`signal` offers a condition to the handlers and returns nil where none of
them took it. `error` offers it and, where none took it, gives up: the
call does not return.

Each takes a condition, a symbol naming a type to make one of, or a
format control and its arguments:

```lisp
(error 'parse-failed :line 12 :text "unexpected )")
(error "cannot parse line ~a" 12)          ; a simple-error
(signal 'finished)
```

`warn` signals a warning and prints it to `*error-output*` where nothing
takes it. `cerror` signals an error the way `error` does; the `continue`
restart it should establish waits on the restart machinery.

`*break-on-signals*` holds a type. A condition of that type stops rather
than being offered to the handlers.

## Handling

`handler-bind` runs its handler where the condition was signaled, with
the stack still standing:

```lisp
(handler-bind ((parse-failed (lambda (c) (log-it c))))
  (parse-everything))
```

A handler that returns has declined, and the search carries on to the
next one outward. A handler that leaves through `return-from`, `go` or
`throw` stops the search there. While a handler runs, only the handlers
outside its own are in scope, so a condition it signals cannot reach it
again.

`handler-case` unwinds first and runs its clause afterwards:

```lisp
(handler-case (parse-everything)
  (parse-failed (c) (list :failed (parse-failed-line c)))
  (error (c) (list :other c))
  (:no-error (result) (list :ok result)))
```

A clause matches on the condition's type rather than on the order the
clauses were written. `:no-error` runs with the values of the body where
nothing was signaled.

`ignore-errors` returns the body's values, or nil and the condition:

```lisp
(multiple-value-bind (value condition) (ignore-errors (parse-everything))
  ...)
```

## Failures from inside the implementation

A failure the implementation raises, `(car 1)` among them, does not pass
through the handlers established between it and whatever catches it: it
unwinds first and is turned into a condition on the way out. So
`handler-case` and `ignore-errors` see it as the type it stands for, a
`type-error` for that call, while a `handler-bind` handler around it does
not run. Conditions signaled from Lisp reach `handler-bind` normally.
