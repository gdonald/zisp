# The collector

There are two generations. Everything is allocated in the nursery, a
pair of regions handed out by bump pointers and sharing a 1 MB budget:
one holds conses and one holds the objects that carry a header, so
either can be walked. A collection copies whatever is still reachable
there into the tenured space and puts the bump pointers back to zero, so
a program that makes garbage and drops it pays nothing for the garbage.

The tenured space is where the copies land, and it is collected by
marking and sweeping. The rest of this document describes it.

Most collections are minor: they are about the nursery, and reach what
it holds through the roots and the cards. A major one marks and sweeps
everything, and is what reclaims the tenured space. One is due once the
tenured space has grown fourfold since the last, and never below
`*gc-major-floor*`, where there is nothing to reclaim yet. `(room)`
reports both counts, as `:collections` and `:major-collections`.

Objects come out of 64 KB regions rather than one host allocation each,
so a sweep can walk them in address order. Conses live in regions of
their own: a cons is 16 bytes with no header, so a cons region is walked
in fixed steps, while an object region is walked by each block's
recorded size.

## Blocks

Every block in an object region carries an 8-byte prefix holding the
payload size. Sizes are multiples of the 8-byte alignment, so the low
bit is spare and records whether the block is free. A free block threads
a `next` pointer through its payload and sits on one of five lists: four
size classes (16, 32, 64, 128 bytes) and one for anything larger.

An allocation takes the first block big enough, from its own class or a
larger one, and splits off the remainder when what is left over can hold
a block of its own. A request that no free block serves comes off the
region's bump pointer.

## Evacuating the nursery

A collection starts by copying. Each reference is followed, and one that
points into the nursery has its target copied into the tenured space:
the object's bytes are moved as they are, since a heap object records
its own size and the arrays it points at stay on the host allocator.

What is left behind says where the object went. A cons gets a car of
`FORWARDED`, a tag no real value carries, and a cdr holding the new
value. A heap object gets the `forwarded` bit in its header set and the
new value written into its second word. Anything reaching the old
address afterwards is handed the new one instead, so a graph with shared
structure comes out with that sharing intact, and a cycle terminates.

Because references are rewritten, this walks slots rather than values: a
root, a slot inside an object, or a binding in a frame. An object that
is already tenured is left where it is and not descended into: a young
object it holds is reached through its card. So the walk covers the
cards, the roots, and whatever the copies themselves point at, rather
than the whole live heap.

An object the collected heap does not own is followed all the same. A
closure comes off the host allocator rather than out of a region, so it
sits on no card and nothing else would record what it captured.

Two things are keyed on an address and are fixed up afterwards: the
source-position table, whose entries move with the cons they describe,
and `eq` and `eql` hash tables, whose buckets are rebuilt when a key
moved.

**A `Value` in a Zig local is stale across a collection.** The root scan
rewrites the copy on the Lisp stack, the pin list, or wherever else it
was registered, but it cannot write back into the local. Read the value
again from where it was registered.

## The card table

A collection of the nursery has to find every reference into it, and a
tenured object holding one is the case the roots do not reach. Every
region carries a second bitmap for that: one bit per 512 bytes, marked
when something in that span is made to point at a young object.

The mark happens at the three places a value is written into an object
that already exists, `setCar`, `setCdr` and `setSlot`, which is why they
take the heap. A store whose target is not young, or whose container is
not tenured, marks nothing: the roots reach both ends of it either way.

Two cases a store cannot have recorded mark their cards anyway. A young
region handed to the tenured space held young containers when the stores
ran, so retiring one marks every card it has. An allocation the nursery
could not serve is built in the tenured space out of values that are
young, and a constructor writes its fields rather than storing into
them, so the spilled block's card is marked as it is handed out. The
copies the collector itself makes need none of this: it rewrites every
reference it copies.

The evacuation reads the cards before it reads the roots, and forgets
them all once it is done: nothing points into the nursery afterwards.
A cons region is read a card at a time, since cells are all one size and
a card covers a whole number of them. A cell on a free list is passed
over, which is what the marker in its first word is for. An object
region is walked instead, because a card can start part way through a
block, and a region with no dirty card is not walked at all.

## Marking

Mark bits live in a bitmap on the region, one bit per 8-byte granule,
set on the granule an object starts at. That is what lets a cons carry
no header of its own.

A minor collection marks the nursery alone. The walk stops at an object
the tenured space holds, since what such an object refers to in the
nursery arrives through its card instead, and the cards are read as roots
before the roots themselves. So a minor collection costs what the
program has just made rather than everything it has kept. An object the
collected heap does not own is followed whatever the reach, having
neither a mark bit nor a card.

The traversal runs off an explicit worklist rather than the host stack,
so a list of a million cells marks without overflowing. The mark bit
doubles as the record of what has been descended into, so a cycle stops
on its second visit. Two things live outside the collected heap and
need their own visited sets: symbols, which come from the interner's
arena, and environment frames, which a closure holds by pointer.

## Sweeping

A minor collection sweeps the nursery and leaves the tenured space to
the major that marked it. Each generation keeps its own free lists, so
neither hands out the other's blocks.

A young cons region more than half full of survivors is handed to the
tenured space rather than shrinking the nursery to whatever the
survivors leave. That happens after the region has been swept, never
before: a dead cell that had not been swept would still hold whatever it
held when it died, and a card scan would read it as live. The cells it
gave up move onto the tenured free list with it.

The sweep walks each region in address order and rebuilds the free lists
from scratch. A run of neighbouring dead blocks becomes a single free
block, which is the whole of the coalescing: nothing merges blocks
afterwards, because a free list is only ever built from runs. Marks are
cleared as the walk passes them.

A dead object's payload arrays (string characters, array storage, bignum
limbs, hash table entries, stream buffers) go back to the host allocator
through a finalizer before the block is reclaimed.

## Weak pointers

`ext:make-weak-pointer` hands back a reference the collector does not
follow. What it refers to is reclaimed as if nothing held it, and
`ext:weak-pointer-value` then returns `(values nil nil)` rather than
`(values obj t)`. The second value is what tells a broken pointer from
one that was handed nil to begin with.

Neither the mark phase nor the copy descends through one. Each collects
the weak pointers it reached and looks at them again when it is done: the
mark phase breaks the ones whose referent it did not mark, and the copy
follows the ones whose referent moved and breaks the rest. A broken
pointer holds `BROKEN`, a tag no value a program can make ever carries.

A young collection marks the nursery alone, so it breaks only a referent
that was there. One in the tenured space is left as it is, because that
collection has not established whether it is dead.

## Finalization

`ext:finalize` says what to run once an object has been reclaimed, and
`ext:cancel-finalization` takes it back. The registration holds the
object through a weak pointer, so registering an action is not what keeps
the object alive. An action that refers to the object would be, which is
why one is written to close over what it needs rather than over the
object itself.

A collection is no place to run one: it is where allocating is not
allowed. So a collection only moves the actions whose object has gone
onto a queue, and whatever was evaluating runs them at the next safe
point, which is where a collection would have been allowed to start.

An action may allocate and so set off a collection of its own. What that
collection finds goes on the back of the queue and waits for the next
pass. A pass runs the entries it started with and never starts inside
another, so nothing is run twice and nothing is skipped.

## Roots

- Every symbol in every live package, through its value, function and
  property cells. This covers the REPL's history variables and any
  stream a variable names.
- The environment frames currently in scope, their parents, and the
  frames live closures captured. The environment's list of every frame
  it has handed out is deliberately not a root: it never shrinks, so
  scanning it would keep every binding a finished call made alive.
- The Lisp stack: call arguments, and whatever a native is holding.
- The evaluator's value channels, its block, tagbody, catch and dynamic
  binding stacks, the form being evaluated, and the logical host table.
- Whatever is pinned.

Source positions are keyed on a cons address, so an entry whose cons
died is dropped before that address can be handed out again.

## The Lisp stack

Call arguments live on an explicit stack of `Value` rather than in Zig
locals, so a root scan sees them. It is a chain of chunks rather than one
array that grows in place: a slice handed to a native has to stay valid
for as long as that call runs, and reallocating a single array would move
it. A run of arguments that fills its chunk moves into a fresh one, so it
stays contiguous.

Any Zig function that holds a value in a local across an allocation puts
it there too:

    var held = ev.protect();
    defer held.close();
    try held.push(v);

## Checking the discipline

`-Dgc-torture=N` collects ahead of every Nth allocation and holds
reclaimed blocks back rather than handing them out again. A value a Zig
local keeps without putting it on the Lisp stack is then reclaimed under
it, and the next use of it aborts rather than reading whatever was
allocated over it later.

Reclaimed blocks are poisoned in a checked build: the second word of a
dead object is set to a pattern no live value can hold. Reading a cons,
asking a heap object its type, storing into a cons, holding a value on
the Lisp stack, and recording one in the value channel all check for it
first, so the abort names the line that used the reclaimed object rather
than surfacing as wrong output later. Every allocation also steps a
counter, which `room` reports as `:allocations`.

A hundred thousand random stores go through the mutators in
`tests/runtime/card_fuzz_test.zig`, against a population of conses,
vectors, structures and hash tables the collector has already promoted.
The tenured space is then read from end to end: every slot found
pointing at a young object has to sit on a marked card. A collection
follows, and the same walk has to find nothing pointing young at all. The
walk is written out in the test rather than shared with the collector, so
a mistake in one does not hide in the other, and the fuzz counts its own
crossings and fails if fewer than a tenth of the stores made one.

CI runs the whole test suite this way, which is what keeps the rule
enforced: a constructor holds the values handed to it, and anything else
that keeps a value across an allocation holds it on the Lisp stack.
Holding reclaimed blocks back means the run keeps every byte it ever
allocated, so it needs several gigabytes and takes a few times longer
than the plain suite.

## When it runs

A collection runs at a safe point: the top of the loop that reads and
evaluates one top-level form at a time. Nowhere else is safe, because
the copy moves objects and a native builtin part-way through its work
holds values in Zig locals nothing can write back into.

That is where the copy runs. A form that allocates for a long time does
not wait for it: the first young allocation the nursery cannot serve is
served from the tenured space and records the spill, and a collection
runs ahead of the next allocation once enough has been handed out since
the last one. Enough is half a nursery, or a quarter of what is live
once that is the larger, since a collection walks the whole live heap
and would otherwise cost more per allocated byte the more a program
retains. That collection reclaims the nursery in place rather than
copying, so the loop goes on reusing the same megabyte. Survivors are
promoted by the next copy, at the top of the form after.

A collection also runs from inside an allocation, once the nursery has
handed out its budget and a young allocation has had to come out of the
tenured space instead. Moving is not safe there, so that one marks and
sweeps in place: the nursery keeps its bump pointers where they are and
what died in it goes onto free lists of its own, which the next young
allocation draws from before the bump pointer. Nothing changes address,
so a value in a Zig local is still good afterwards. A torture collection
runs the same way.

Each generation has its own free lists. A tenured allocation is never
served out of a nursery block, so an object the collector copied out of
the nursery cannot land back in it.

`(gc)` asks for a collection, which runs when the evaluator is next back
at a top level form. A collection also fires on its own once the nursery
has handed out its budget, or once more than `*gc-trigger*` bytes have
been handed out since the last one. Setting
`*gc-verbose*` reports what each one reclaimed. `(room)` returns the
heap figures as a property list, and `(room t)` prints them as well.

Among those figures are what the collector has cost: `:gc-time-ns` is
how long collections have taken in total, `:gc-pause-max-ns` the longest
single one, and `:gc-pauses` a count per order of magnitude, longest
bucket last. Every collection lands in a bucket, so the buckets add up to
`:collections`. `docs/perf-baseline.md` records what those numbers come
to on a run built for speed, and what they are held to.
