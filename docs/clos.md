# CLOS

The object system is written in Lisp, in `src/lisp/clos.lisp`, over a
few objects and natives the runtime provides in
`src/builtins/instances.zig`. It is loaded at boot after the sequence
functions and before the condition system, which is built on it.

## Instances

A standard instance is a heap structure whose name field holds its class
where a `defstruct` instance holds a symbol. It has two fields: a simple
vector of slot values and the wrapper its class had when that vector was
laid out. An unbound slot holds `*%slot-unbound*`.

A funcallable instance, which is what a generic function is, is a
function object of its own kind carrying the same class, slot vector and
wrapper, along with the function a call to it runs.

`class-of` is native. For an instance it is the class the instance
holds. For anything else it is the class kept on a symbol's property list
under `%class`: the structure's name for a structure, and otherwise the
name of the most specific built-in class the object belongs to, such as
`fixnum`, `null` or `string`.

## Metaobjects

Classes, generic functions, methods, slot definitions, method
combinations and eql specializers are instances too. Each kind keeps its
slots at fixed positions in the slot vector, listed in `*%class-layout*`,
`*%gf-layout*`, `*%method-layout*`, `*%slotd-layout*`,
`*%combination-layout*` and `*%eql-layout*`, and the code reaches them
with `%class-ref` and the macros beside it rather than through
`slot-value`. A class lists its first superclass's slots ahead of its own,
so a subclass of a metaobject class keeps those positions. The natives
read a few of them by number, and a check at boot fails if the layouts
move.

The classes the protocol is made of are built by hand at boot: a shell
for each, then superclasses, direct slots, and finalization, with the
wrappers filled in last. Until `*%clos-booted*` is set, the code calls the
standard behavior directly instead of going through generic functions.

The metaobject protocol's names are exported from the package `ZISP-MOP`,
whose nickname is `MOP`. `COMMON-LISP` exports only the names the
standard gives it.

## Class precedence lists

A class precedence list is the topological sort CLHS 4.3.5 specifies:
each class precedes its superclasses, the superclasses keep the order the
definition lists them in, and where several classes could come next the
one with a direct subclass furthest right in the list so far is taken. A
hierarchy with no such order is an error when the class is defined. The
sort is native, `%topological-cpl`.

## Slots

`slot-value`, `(setf slot-value)` and `slot-boundp` try a native fast
path first. It applies to an instance whose metaclass is
`standard-class`, `funcallable-standard-class` or `condition-class` and
whose layout is current, and for a write, to a slot with no `:type`.
Everything else goes through the Lisp below it: an instance whose class
was redefined is brought up to date first, a missing slot calls
`slot-missing`, an unbound one `slot-unbound`, a typed slot has its new
value checked, and an instance of another metaclass goes through
`slot-value-using-class`.

A shared slot, one with `:allocation :class`, keeps its value in a cell
owned by the class that defines it, and a subclass that inherits the slot
shares the cell.

## Redefinition

Redefining a class finalizes it again, and the classes below it. Where
the list of local slots changed, the class gets a new wrapper, which makes
every existing instance obsolete without touching it. The next slot
access on one moves it to the new layout and calls
`update-instance-for-redefined-class` with the slots added, the slots
discarded, and the values the discarded ones had. `make-instances-obsolete`
gives a class a new wrapper with the same slots.

`change-class` gives an instance a new class and storage in place, so it
keeps its identity.

## Generic functions

Calling a generic function runs `%gf-dispatch`, which is native. It
looks up the effective method in the generic function's cache: a tree of
`eq` hash tables, one level for each argument position some method
specializes, keyed by the argument's class or by the eql specializer it
matches. A miss calls `%gf-dispatch-miss` in Lisp, which checks the
argument count, works out the applicable methods and the effective
method, and stores it.

A cache is dropped when a method is added or removed and when a class
already in use gets a different precedence list, which `*%dispatch-epoch*`
counts. A class defined for the first time has no entries to drop.

A method function takes the list of arguments and the list of next
methods. Its body binds the method's lambda list with
`destructuring-bind`, and reaches `call-next-method` and `next-method-p`
through global macros of those names, which read the method function's
own variables. A body that takes either as a function object, with
`#'call-next-method`, gets them as local functions instead.
`call-next-method` with arguments checks that they have the same
applicable methods as the original ones.

## Method combinations

The standard method combination on a `standard-generic-function` builds
its effective method as a closure directly. Every other combination, and
any generic function of another class, builds an effective method form
through `compute-effective-method`, which is turned into a function with
`call-method` and `make-method` as local macros.

The operator combinations `+`, `and`, `or`, `list`, `append`, `nconc`,
`min`, `max` and `progn` are defined with the short form of
`define-method-combination`. The long form sorts the applicable methods
into its method groups, most specific first, each going to the first
group whose qualifier patterns or predicate accept it. Its `:arguments`
variables are lined up with the generic function's own parameters
position by position.

## Initialization

`make-instance` defaults the initargs, checks them against the slots'
initargs and the keywords the applicable methods of `make-instance`,
`allocate-instance`, `initialize-instance` and `shared-initialize`
accept, and then allocates and initializes. Where only the standard
methods of those apply to the class, which is worked out once for each
set of methods those generic functions have, it does the same work
without calling them.

## Printing

The printer has a hook for objects it does not print itself. Every
instance goes to `print-object`, called with a fresh string stream and
with `*print-escape*` and `*print-readably*` bound to what the printer
was asked for, so a method runs for an instance anywhere the printer
meets one: at the top level, inside a list or a vector, inside another
instance's method, or under `format`. A structure goes to `print-object`
once some `print-object` method is defined for a structure type. The
method on `t` hands the object back to the printer. An error inside a
method reaches the caller of the printing function as the error it was.

## Structures

`defstruct` defines a `structure-class` for the structure type, below the
type named by `:include` or below `structure-object`, with a slot for
each slot of the structure at the position the structure keeps it.
`class-of`, `typep`, `subtypep` and `slot-value` work on structures
through that class.

## Compiled files

A fasl holds its forms as source. An object of a class that defines
`make-load-form` is written as a `#.` reference into a table the fasl
fills as it loads: its creation form is written ahead of the first form
that refers to it, once the objects that form refers to have been, and
its initialization form follows as early as what it refers to allows.
