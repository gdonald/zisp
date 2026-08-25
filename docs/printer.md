# The printer

`prin1`, `princ`, `print`, `write-to-string` and the `format` directives
that print an object all go through one driver. What that driver does is
settled by the printer variables, which are read out of the dynamic
environment at each call, so binding one covers everything printed inside
the binding.

    (let ((*print-base* 16)) (prin1-to-string 255))   ; => "FF"

## What each variable does

`*print-escape*` decides whether what comes out can be read back:
strings are quoted, symbols that need it are wrapped in `|...|`, and a
symbol outside the current package carries its package prefix. `prin1`
prints with it on and `princ` with it off, whatever the variable holds.

`*print-readably*` says the output must read back as the same object. It
escapes whatever `*print-escape*` would have left bare.

`*print-base*` is the radix integers and ratios print in, between 2 and
36. `*print-radix*` adds the marker that says which radix it was: `#b`,
`#o`, `#x`, or `#nnR` for anything else, and a trailing `.` for base ten.

`*print-case*` is how a symbol's name is cased: `:upcase` leaves it as it
is, `:downcase` lowers it, `:capitalize` raises the first character of
each run of letters and digits and lowers the rest. A name that has to be
escaped is printed as it stands, since the escape is what makes it read
back.

`*print-level*` is how many levels down to print before an object stands
in as `#`, and `*print-length*` how many elements of a list, vector or
structure to print before the rest stands in as `...`. Both are null by
default, which prints everything. Only an object with parts is
abbreviated: a number at any depth prints as itself.

`*print-gensym*` marks an uninterned symbol with `#:`.

`*print-circle*` labels shared structure as `#n=` and `#n#`.
`*print-pretty*`, `*print-right-margin*`, `*print-miser-width*` and
`*print-pprint-dispatch*` belong to the pretty printer.

`*print-array*` and `*print-lines*` are defined and hold their standard
values. Nothing reads them yet.

## The reader variables

`*read-base*`, `*read-eval*`, `*read-suppress*` and
`*read-default-float-format*` are defined and hold their standard values.

## Standard syntax

`with-standard-io-syntax` binds every variable above, and `*package*` and
`*readtable*` with them, to what the standard says it holds. A form that
has to print the same whatever the program had set goes inside it.

    (with-standard-io-syntax (prin1-to-string 255))   ; => "255"
