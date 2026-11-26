# Embedding zisp

A Zig program starts a zisp session with `zisp.repl.Repl.init`, which
takes the allocator for everything the session holds, a writer for what
it prints, and an optional `std.Io` for files:

```zig
const repl = try zisp.repl.Repl.init(gpa, &output.writer, null);
defer repl.deinit();
try repl.run("(+ 1 2)");
```

With no `std.Io`, the session has no file system. `-Dfreestanding=true`
also leaves out the foreign function interface.

## Supplying memory

zisp takes all of its memory from the allocator passed to `Repl.init`.
No part of the runtime, evaluator or reader uses a global allocator.

A host without a Zig allocator, such as a microcontroller with a C heap
or a pool over a static buffer, describes its heap as a
`zisp.HostAllocator`. That is two functions and a context pointer:

```zig
pub const HostAllocator = struct {
    context: ?*anyopaque,
    alloc: *const fn (context: ?*anyopaque, len: usize, alignment: std.mem.Alignment) ?[*]u8,
    free: *const fn (context: ?*anyopaque, memory: []u8, alignment: std.mem.Alignment) void,
};
```

- `alloc` returns `len` bytes aligned to `alignment`, or null when it has none.
- `free` receives memory `alloc` returned, with the same length and alignment.

`HostAllocator.allocator()` turns it into the `std.mem.Allocator` that
`Repl.init` takes. It never resizes in place. When zisp grows a buffer,
it allocates a new one, copies the contents and frees the old one.

```zig
extern fn board_malloc(len: usize) ?[*]u8;
extern fn board_free(ptr: [*]u8) void;

fn boardAlloc(_: ?*anyopaque, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
    if (alignment.toByteUnits() > 8) return null;
    return board_malloc(len);
}

fn boardFree(_: ?*anyopaque, memory: []u8, _: std.mem.Alignment) void {
    board_free(memory.ptr);
}

const board_heap: zisp.HostAllocator = .{ .context = null, .alloc = boardAlloc, .free = boardFree };

const repl = try zisp.repl.Repl.init(board_heap.allocator(), &output.writer, null);
```

When `alloc` returns null while the session boots, `Repl.init` returns
`error.OutOfMemory` and frees everything it took.
