# The environment

What the standard leaves to the implementation in its environment
dictionary, CLHS chapter 25, and how zisp answers.

## Time

`get-universal-time` reads the wall clock. No time zone is known, so
local time is taken as UTC with no daylight saving: `decode-universal-time`
with no time zone reports zone 0, and `encode-universal-time` with none
encodes in it. A two-digit year passed to `encode-universal-time` is the
one within fifty years of the current year.

`time` writes how long its form took to `*trace-output*` after the form's
values are in hand:

    ; Evaluation took 0.000412 seconds of real time

## The machine

`lisp-implementation-type` is `"zisp"` and `lisp-implementation-version`
the build's version. `machine-type` and `software-type` name the CPU
architecture and the operating system the build targets, such as
`"aarch64"` and `"macos"`. `machine-version`, `machine-instance`,
`software-version`, `short-site-name` and `long-site-name` are NIL.
`user-homedir-pathname` is the directory `HOME` names.

## Tracing and inspecting

`trace` wraps each named global function so that each call and its values
are written to `*trace-output*`, and `untrace` puts the function back.
With no names, `trace` returns the names being traced and `untrace`
untraces all of them.

    ; SQ called with (3)
    ; SQ returned 9

`step` evaluates its form without stepping. `inspect` describes its
object. `dribble` keeps no transcript. `function-lambda-expression`
returns NIL for the lambda expression and the name, and T for whether the
function may be a closure.

## Modules

`provide` adds a module name to `*modules*`. `require` loads the
pathnames it is given unless the module is already there, and signals an
error when the module is not there and no pathnames are given.

## Asking the user

`y-or-n-p` and `yes-or-no-p` write their question to `*query-io*` and
read a line back, asking again until the answer is `y` or `n`, or `yes`
or `no`. An empty line is no.
