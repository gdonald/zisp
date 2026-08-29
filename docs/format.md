# format

`format` reads a control string and writes what it says to a
destination: `t` for the console, `nil` for a fresh string, or a stream.
The directives below are what the control language covers.

## Output

`~A` prints an object as `princ` would and `~S` as `prin1`. Both take
`mincol,colinc,minpad,padchar` and pad on the right, or on the left with
`@`. `:` prints an empty list as `()`. `~W` prints as `prin1` does and
takes no parameters.

`~C` writes one character. `~:C` writes its name instead where it has
one, `~@C` writes the `#\` form the reader takes back.

`~%` writes a newline, `~&` one only where the line has something on it,
`~|` a page separator, and `~~` a tilde. Each takes a repeat count.
A tilde before a literal newline drops that newline, and the indentation
after it as well unless `:` keeps it.

## Numbers

`~D` prints an integer in decimal, `~B` in binary, `~O` in octal, `~X` in
hexadecimal. Each takes `mincol,padchar,commachar,comma-interval`, prints
a leading `+` with `@`, and groups digits with `:`. An argument that is
not an integer prints as if by `~A` in that radix.

`~R` takes the radix as its first parameter and the four above after it.
With no parameters it spells the number out: `~R` in words, `~:R` as an
ordinal, `~@R` in Roman numerals, and `~:@R` in the older Roman form that
has no subtractive pairs.

`~F` prints a float in fixed format, taking `w,d,k,overflowchar,padchar`.
`d` is how many places follow the point and `k` a power of ten to scale
by. Without `d` the value keeps as many digits as `w` leaves it, and
always shows one after the point; where even that overruns `w`, the zero
before the point goes instead.

`~E` prints a float in exponential format, taking
`w,d,e,k,overflowchar,padchar,exponentchar`. `e` is how many digits the
exponent takes and `k` how many digits stand before the point, one by
default. `~G` picks between the two by the size of the value, and `~$`
prints a fixed two places after the point, taking `d,n,w,padchar`.

`~P` writes the plural suffix for its argument: `s` unless the argument
is 1, or the `y`/`ies` pair with `@`. `:` re-reads the previous argument.

## Layout

`~T` moves to a column, `~<...~>` lays segments out across a line, and
`~_`, `~I` and `~<...~:>` are the pretty printer's conditional newline,
indentation and logical block.

## Control

`~[...~]` picks one clause by an index, by truth with `:`, or runs its
one clause only for a true argument with `@`. `~{...~}` repeats its body
over a list, drawing from the remaining arguments with `@` and treating
each element as its own argument list with `:`. `~^` leaves the enclosing
clause when the arguments run out, and `~:^` the whole iteration.

`~*` skips an argument, `~:*` backs up, `~@*` jumps to an index. `~?`
takes a control string and an argument list and runs them here.
`~(...~)` converts the case of what its body wrote. `~/name/` calls a
function with the stream, the argument and the modifiers.

## Parameters

A parameter is written before the directive character, separated by
commas: `~10,'0D`. `v` takes the parameter from the next argument and `#`
from how many arguments are left. Giving a directive more parameters than
it takes is an error.
