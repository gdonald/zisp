# The collector

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

## Marking

Mark bits live in a bitmap on the region, one bit per 8-byte granule,
set on the granule an object starts at. That is what lets a cons carry
no header of its own.

The traversal runs off an explicit worklist rather than the host stack,
so a list of a million cells marks without overflowing. The mark bit
doubles as the record of what has been descended into, so a cycle stops
on its second visit. Two things live outside the collected heap and
need their own visited sets: symbols, which come from the interner's
arena, and environment frames, which a closure holds by pointer.

## Sweeping

The sweep walks each region in address order and rebuilds the free lists
from scratch. A run of neighbouring dead blocks becomes a single free
block, which is the whole of the coalescing: nothing merges blocks
afterwards, because a free list is only ever built from runs. Marks are
cleared as the walk passes them.

A dead object's payload arrays (string characters, array storage, bignum
limbs, hash table entries, stream buffers) go back to the host allocator
through a finalizer before the block is reclaimed.

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

CI runs the whole test suite this way, which is what keeps the rule
enforced: a constructor holds the values handed to it, and anything else
that keeps a value across an allocation holds it on the Lisp stack.
Holding reclaimed blocks back means the run keeps every byte it ever
allocated, so it needs several gigabytes and takes a few times longer
than the plain suite.

## When it runs

A collection runs at a safe point: the top of the loop that reads and
evaluates one top-level form at a time. Nowhere else is safe yet,
because a native builtin part-way through its work holds values in Zig
locals that no root scan can see.

`(gc)` asks for a collection, which runs when the evaluator is next back
at a top level form. A collection also fires on its own once more than
`*gc-trigger*` bytes have been handed out since the last one. Setting
`*gc-verbose*` reports what each one reclaimed. `(room)` returns the
heap figures as a property list, and `(room t)` prints them as well.
