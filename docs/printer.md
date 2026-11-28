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
escapes whatever `*print-escape*` would have left bare, prints the whole
object whatever `*print-level*`, `*print-length*` and `*print-lines*`
hold, and prints symbols for the standard readtable. An object that
cannot be read back signals `print-not-readable`: a function, a stream,
a package, a readtable, an array whose element type is not T other than
a string or a bit vector, an array with a dimension of zero ahead of a
nonzero one, a logical pathname, and a pathname whose namestring parses
back differently, such as one with a type and no name. A random state
prints as `#.` and a call that makes it again. `princ` and `~A` print
with `*print-readably*` off, whatever it holds.

`*print-base*` is the radix integers and ratios print in, between 2 and
36. `*print-radix*` adds the marker that says which radix it was: `#b`,
`#o`, `#x`, or `#nnR` for anything else, and a trailing `.` for base ten.

`*print-case*` is how a symbol's name is cased, together with the case of
`*readtable*` (CLHS 22.1.3.3.2). Under a readtable that upcases,
`*print-case*` applies to the name's upper case letters: `:upcase`
leaves them, `:downcase` lowers them, `:capitalize` leaves the first of
each run of letters and digits and lowers the rest. Under one that
downcases it applies the same way to the lower case letters. `:preserve`
prints the name as it is, and `:invert` inverts a name whose letters are
all one case. A letter the readtable would fold to the other case is
escaped where the output must read back, and so is a name that would
read as a number in `*print-base*`.

`*print-level*` is how many levels down to print before an object stands
in as `#`, and `*print-length*` how many elements of a list, vector or
structure to print before the rest stands in as `...`. Both are null by
default, which prints everything. Only an object with parts is
abbreviated: a number at any depth prints as itself, and so do a string
and a bit vector. Each list of a multidimensional array's contents is a
level, and holds as many elements as `*print-length*` allows.

`*print-gensym*` marks an uninterned symbol with `#:`.

`*print-circle*` labels shared structure as `#n=` and `#n#`, counting
only the parts `*print-length*` and `*print-level*` let print.

`*print-array*` off prints an array other than a string as `#<...>`.

`*print-pretty*`, `*print-right-margin*`, `*print-miser-width*`,
`*print-lines*` and `*print-pprint-dispatch*` belong to the pretty
printer. `*print-pretty*` is off by default.

## The pretty printer

With `*print-pretty*` on, a list is printed as a logical block, and so is
what `pprint-logical-block` and `~<...~:>` print. A block's output is
laid out once its outermost block ends, following CLHS 22.2.1.1: a
linear newline breaks when the section containing it does not fit on one
line, a fill newline when the section after it does not fit on the rest
of the line or the section before it did not go out on one line, a miser
newline as a linear one does but only in miser style, and a mandatory
newline always. A block is in miser style when its text starts within
`*print-miser-width*` columns of the right margin, and in it
`pprint-indent` is ignored. A broken line starts with the per-line
prefixes of the blocks it is in, then blanks out to the block's
indentation, and the blanks that were about to end the line before the
break are dropped. A newline written as text starts a line with the
per-line prefixes and no indentation. Once `*print-lines*` lines are out
the output ends with ` ..` and the suffixes of the open blocks.

`pprint-newline`, `pprint-indent` and `pprint-tab` do nothing with
`*print-pretty*` off or on a stream that is not a pretty stream.
`pprint-pop` writes `...` past `*print-length*`, and `. ` and the rest of
the list where it is not a list or is shared structure under
`*print-circle*`.

An object whose type has an entry in `*print-pprint-dispatch*` is printed
by that entry's function, a symbol or number as well as a list. Of the
entries that match, the one with the highest priority is used, and a
second entry for a type replaces the first. `(copy-pprint-dispatch nil)`
is a table with none of the program's entries in it, and
`set-pprint-dispatch` changes the table it is given,
`*print-pprint-dispatch*` when it is given none.

## Character names

A graphic character prints as `#\` and the character, a space included:
`#\a`, `#\ `. One that is not graphic prints as `#\` and its name:
`#\Newline`, `#\Rubout`. One that has no name of its own is spelled
`#\U+` and its code in hexadecimal, which `char-name` gives back and the
reader takes.

    (char-name (code-char 1))   ; => "U+0001"

## Conditions

A condition prints as its report where nothing asked for output that
reads back, and as `#<TYPE>` where something did. `princ` and `~A` give
the report, `prin1` and `~S` the type.

## Standard syntax

`with-standard-io-syntax` binds every variable above, and `*package*` and
`*readtable*` with them, to what the standard says it holds. A form that
has to print the same whatever the program had set goes inside it.

    (with-standard-io-syntax (prin1-to-string 255))   ; => "255"
