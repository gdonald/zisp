# Macros

## Macros are not hygienic

Common Lisp macros are deliberately unhygienic. An expansion is spliced into
the caller's code as plain list structure, so a variable introduced by the
expansion can capture, or be captured by, a variable of the same name at the
call site:

```lisp
(defmacro bad-swap-add (a b)
  `(let ((tmp ,a)) (+ ,b tmp)))

(let ((tmp 7))
  (bad-swap-add tmp 3))   ; TMP in the expansion shadows the caller's TMP
```

This is by design. The standard tool for avoiding unwanted capture is
`gensym`, which returns a fresh uninterned symbol that cannot be eq to any
symbol appearing in user code:

```lisp
(defmacro good-swap-add (a b)
  (let ((tmp (gensym)))
    `(let ((,tmp ,a)) (+ ,b ,tmp))))
```

`gensym` names the symbol from a prefix (default `G`) and
`*gensym-counter*`, which it increments. With a string argument the string
replaces the prefix. With a non-negative integer argument that integer is
used as the counter and `*gensym-counter*` is left untouched. Uniqueness
comes from the symbol being uninterned, not from the name: two gensyms with
identical names are still different symbols.

`gentemp` instead interns the symbol it creates, probing `PREFIXn` names
until it finds one that is not already interned. It exists for completeness
and is deprecated in ANSI CL. Prefer `gensym`.
