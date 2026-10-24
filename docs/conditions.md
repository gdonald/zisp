# Conditions

A condition is an object describing something that happened, and a
handler is a function that gets offered one. Signaling and handling are
separate: what signals decides what to say, and what handles decides what
to do about it.

A condition type is a CLOS class. `docs/condition-bootstrap.md` covers
how that is put together, and `docs/clos.md` covers the object system.

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
`:allocation`, `:type` and `:documentation`, as a `defclass` slot does. A
value written to a slot with a `:type` has to be of that type. A slot no
initarg filled and with no initform is unbound rather than nil.

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
takes it, with a `muffle-warning` restart that skips the printing.
`cerror` signals an error with a `continue` restart whose report is its
first argument; invoking it makes `cerror` return nil.

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

A failure the implementation raises, `(car 1)` among them, is turned
into a condition of the type it stands for, a `type-error` for that
call, and offered to the `handler-bind` handlers where it was raised,
before anything unwinds. A handler that declines leaves it to
`handler-case` or `ignore-errors` further out, which receive the same
condition object.

## Restarts

A restart is a named way to carry on from a point in the program. A
handler picks one, which lets the code that signaled say what recovery is
possible and the code that handles say which one to take.

`restart-case` establishes restarts around a form. Invoking one unwinds
to its clause and returns the clause's value:

```lisp
(restart-case (parse-line text)
  (skip-line ()
    :report "Skip this line."
    nil)
  (use-text (replacement)
    :report "Parse other text instead."
    :interactive (lambda () (list (read-line *query-io*)))
    (parse-line replacement)))
```

`:report` takes a string or a function of a stream, and is what `~A`
prints for the restart. `:interactive` returns the argument list
`invoke-restart-interactively` uses. `:test` takes a function of a
condition, and a restart whose test returns nil is not visible.

`restart-bind` establishes restarts without unwinding: the restart
function runs where it is invoked and its value goes back to the
invoker.

`invoke-restart` takes a restart or a name and the arguments. Invoking a
name with no visible restart is a `control-error`. `find-restart` returns
the innermost visible restart with a name, and `compute-restarts` returns
every visible one, innermost first. Given a condition, both leave out
restarts associated with other conditions.

`with-condition-restarts` associates restarts with a condition. Where
the form of a `restart-case` is a call to `signal`, `error`, `cerror` or
`warn`, its restarts are associated with the condition that call
signals, so a handler for a second condition signaled inside the first
handler does not see them.

`with-simple-restart` establishes a restart that returns nil and t.

### Standard restarts

`abort`, `continue`, `muffle-warning`, `store-value` and `use-value`
invoke the restart of the same name. `abort` and `muffle-warning` signal
a `control-error` where there is none; the others return nil.

| Restart | Established by |
| --- | --- |
| `abort` | The REPL, around each form it evaluates |
| `continue` | `cerror`, `assert` |
| `muffle-warning` | `warn` |
| `store-value` | `check-type`, `ccase`, `ctypecase`, an unbound variable |
| `use-value` | An unbound variable |

`store-value` puts the new value in the place and tries again, while
`use-value` uses the value once and leaves the place as it was:

```lisp
(handler-bind ((unbound-variable (lambda (c) (use-value 0 c))))
  (+ undefined-total 1))                    ; => 1, still unbound
```

## The debugger hook

`invoke-debugger` calls the function in `*debugger-hook*` with the
condition and the hook itself, binding `*debugger-hook*` to nil while it
runs. An `error` that no handler takes goes to `invoke-debugger`, so the
hook sees every unhandled error. A hook usually leaves with a non-local
exit. Where there is no hook, or the hook returns, the REPL enters the
default debugger. In batch mode (`--eval`, `--load`, a script) there is
no one to ask, so the condition unwinds to whatever catches it, and the
driver reports it and exits non-zero if nothing does.

```lisp
(block done
  (let ((*debugger-hook* (lambda (c hook) (declare (ignore hook))
                           (return-from done c))))
    (error "reported through the hook")))
```

## The default debugger

The REPL enters the debugger where the condition was signaled, before
anything unwinds. That holds for a failure a native raised, such as
`(car 5)`, as well as for `error`. It prints the condition's report and
the restarts, then reads from where the REPL's input has got to:

```
;; Debugger entered on SIMPLE-ERROR:
;;   Only 3 of 5 seats are free.
;; Restarts:
;;   0: [CONTINUE] Book the seats that are left.
;;   1: [ABORT] Return to the top level.
Debug>
```

| Input | What it does |
|---|---|
| an integer | invokes the restart listed under it |
| `:r NAME` | invokes the restart of that name |
| `:b` | prints the backtrace |
| any other form | evaluates it where the condition was signaled and prints its values |
| end of input, or input that does not read | invokes the innermost `abort` restart |

A restart with an `:interactive` function, such as `use-value` for an
unbound variable, asks for its arguments. A form is evaluated with the
lexical bindings of the place the condition was signaled from, so a
`let` variable there can be read. An error in such a form enters a
debugger one level in, prompting `Debug[2]>`, whose first restart returns
to the outer one.

`(break "Pausing at ~a." x)` enters the debugger without signaling, so no
handler sees its condition. Its `continue` restart returns nil from the
call.

## Backtraces

`ext:backtrace` returns the calls in progress, innermost first, each as
`(name position arguments)`. The name is a string, nil for an anonymous
function. The position is `(file line column)` for where the call was
written, and it is recorded for code read by `load`. A call a macro built
is placed where the macro's own call was written. Taken from a debugger
hook or the debugger, the backtrace starts at the call that signaled.

```lisp
(defun descend (n)
  (if (= n 1) (error "Reached the bottom.") (1+ (descend (1- n)))))

(block captured
  (let ((*debugger-hook* (lambda (c hook) (declare (ignore c hook))
                           (return-from captured (ext:backtrace)))))
    (descend 2)))
;; => (("DESCEND" ("/path/descend.lisp" 2 49) (1))
;;     ("DESCEND" ("/path/descend.lisp" 7 5) (2)))
```

A call in tail position replaces the frame that made it, so that frame is
not in the backtrace. Calls to `error`, `cerror`, `signal`, `warn`,
`break` and `invoke-debugger` keep the frame that made them.
