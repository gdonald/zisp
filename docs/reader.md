# The reader

`read`, `read-preserving-whitespace`, `read-from-string`,
`read-delimited-list`, `load` and `compile-file` all read through one
reader. It takes the text one character at a time and does what the
current readtable says that character means, following CLHS 2.2:
whitespace is skipped, a macro character calls its function, and anything
else starts a token. A token is a number when it has number syntax in
`*read-base*`, and a symbol otherwise.

    (let ((*read-base* 16)) (read-from-string "ff"))   ; => 255, 2

## Readtables

`*readtable*` holds the readtable in effect, and `copy-readtable`,
`readtable-case`, `set-syntax-from-char`, `set-macro-character`,
`get-macro-character`, `make-dispatch-macro-character`,
`set-dispatch-macro-character` and `get-dispatch-macro-character` work on
one as the standard describes. A readtable argument of NIL names the
standard readtable where the standard allows it.

`:invert` inverts the case of a token only when its unescaped letters
are all one case, so `Foo` reads as the symbol named `Foo`.

The function `get-macro-character` returns for a standard macro
character, `(`, `'` or `#` among them, reads from the stream it is called
with the way the reader would have.

## Macro functions written in Lisp

A function given to `set-macro-character` is called with the stream
being read and the character, and one given to
`set-dispatch-macro-character` with the stream, the sub-character and the
numeric argument or NIL. The reader carries on from wherever the function
leaves the stream. A function that returns no values reads nothing, the
way a comment does.

    (set-macro-character #\! (lambda (stream char)
                               (declare (ignore char))
                               (list 'not (read stream t nil t))))
    (read-from-string "!x")   ; => (NOT X), 2

`load` and `read-from-string` read text that no stream holds, so a macro
function they call is given a string stream over that text.

## The reader variables

`*read-base*`, `*read-eval*`, `*read-suppress*` and
`*read-default-float-format*` hold their standard values. A float with no
exponent marker, or with `e`, reads as the type
`*read-default-float-format*` names. `load` and `compile-file` look at it
again before each top-level form, so a form that sets it at compile time
changes how the forms after it read.

With `*read-suppress*` on, every token reads as NIL and so does every
object a standard macro character reads, which is how the branch `#+`
leaves out can name a package this image does not have.

## Where the standard leaves a choice

- The text is UTF-8. A byte that does not start a well-formed sequence
  reads as the Latin-1 character it encodes.
- `,.` reads as `,@`.
- `#S(name slot value ...)` makes the structure with NAME's keyword
  constructor. Each slot is named by a string designator, so `:a`, `a`
  and `"A"` all name the slot `a`.
- A feature expression is read with `*package*` as `KEYWORD`, and a
  symbol in it is true when it is `eq` to a member of `*features*`.
- A package prefix naming no package, a single colon before a symbol that
  is not external, and a float too large for its format are each a
  `reader-error`.
