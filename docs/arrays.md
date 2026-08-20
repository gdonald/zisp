# Arrays

One heap object covers every array, vectors included. It holds the rank,
the dimensions, the element type, an optional fill pointer, the adjustable
flag, and either its own storage or a displacement to another array.
Dimensions and storage are held indirectly, so `adjust-array` and
`vector-push-extend` can resize an array without moving the object other
values already point at.

Elements are stored one `Value` slot each whatever the element type. The
element type restricts what may be written and is what
`array-element-type` reports:

```lisp
(setf (aref (make-array 2 :element-type 'bit) 0) 2)   ; type error
(array-element-type (make-array 2 :element-type '(unsigned-byte 8)))
; => (unsigned-byte 8)
```

A `bit` array therefore behaves as a bit vector without packing eight bits
to the byte. Packing is a space optimization, not a semantic one, and it
is not done yet.

## Strings are character vectors

A one-dimensional array of characters is a string, so `make-array` with
`:element-type 'character` returns one and it has the string
representation described in [strings.md](strings.md) rather than a slot
per character:

```lisp
(stringp (make-array 3 :element-type 'character))     ; => T
(stringp (make-array '(2 2) :element-type 'character)) ; => NIL
```

Strings carry the same fill pointer and adjustable flag as any other
vector, so `vector-push-extend` works on them. They cannot be displaced;
`:displaced-to` with a character element type is an error.

## Displacement

A displaced array has no storage of its own and indexes into its target at
an offset. The target may itself be displaced, and the chain is followed
to whichever array owns the storage, so a write through the outermost
array lands in the innermost one.

`adjust-array` on a displaced array without a new `:displaced-to` detaches
it and gives it storage of its own.

## Fill pointers

`length` stops at the fill pointer; `aref` and `row-major-aref` do not, and
reach the whole array. `vector-push` returns NIL rather than growing when
the array is full, while `vector-push-extend` extends it.
