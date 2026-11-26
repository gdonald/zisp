# Native code backend

Compiled functions run as bytecode on the VM described in
`docs/bytecode.md`. This document compares three ways of turning them
into machine code instead, and recommends one. No native code is written
until the recommendation is signed off at the end.

The three:

- **LLVM through `zig cc`.** The compiler writes C for a compilation
  unit, runs `zig cc -O2 -shared` on it, and loads the shared library
  with `dlopen`. `zig cc` is clang with LLVM inside the Zig toolchain.
- **Cranelift.** The code generator Wasmtime uses, a Rust library. zisp
  would link it through a small Rust crate exposing a C interface, and
  use its JIT module to put code in executable memory.
- **Hand-rolled.** zisp encodes aarch64 and x86_64 instructions itself,
  into memory it maps executable.

## What was measured

    tests/run-codegen-tak.sh

`tests/codegen/tak.c` is TAK the way a C-emitting code generator would
write it, with values tagged the way zisp tags them. One version checks
that every operand is a fixnum before using it and calls itself through
a function cell, as a call to a global function has to. The other uses
plain integers and direct calls, which is what the same function comes
to once type inference knows its arguments are fixnums.
`tests/codegen/tak.lisp` runs the same TAK compiled to bytecode. Each
computes `(tak 24 16 8)`.

| Measured on | Bytecode | C, tagged | C, unboxed | `zig cc -O2` build |
| --- | --- | --- | --- | --- |
| macOS, aarch64, 2026-10-24 | 54.4 to 63.3 ms | 2.2 to 2.4 ms | 1.6 to 1.7 ms | 101 to 204 ms |

The build time is for one file of three functions, from starting `zig
cc` to the binary being written. The first build of a session took 204
ms and the later ones 101 ms.

Cranelift was not measured: building it would download its crates,
which this comparison did not do. The hand-rolled backend was not
measured: there is no prototype of it. The figures below for those two
are therefore reasoning, and say so.

## Implementation effort

**LLVM through `zig cc`.** One emitter, from the compiler's IR to C, for
both targets. clang does instruction selection, register allocation and
scheduling. The emitted code has to cooperate with the runtime in three
ways it does not get for free:

- a value a C local holds across an allocation has to be on the VM's
  stack, where the collector sees it, since the collector is precise;
- a non-local exit or a failure has to leave the C function the way a
  Zig error leaves a Zig one, so each function returns a status and
  every call checks it;
- calls into natives go through a table of runtime entry points handed
  to the library when it is loaded.

**Cranelift.** One emitter, from the IR to Cranelift's IR, for both
targets, plus the Rust crate that exposes it, its build, and the C
interface between it and Zig. The same three runtime obligations apply,
with stack maps available from Cranelift for the first.

**Hand-rolled.** Two instruction encoders, a register allocator, the
calling conventions of both targets, unwind information so a backtrace
and a non-local exit can walk native frames, and executable memory
handling, which on macOS on Apple silicon means `MAP_JIT` and switching
the thread between writing and running. The same three runtime
obligations apply. This is several times the work of either other
option.

## Output quality on cl-bench arithmetic

**LLVM through `zig cc`.** Measured above: tagged C runs TAK about 25
times as fast as bytecode, and unboxed C about 34 times.

**Cranelift.** Not measured. Cranelift does less optimization than LLVM
at `-O2`, so the expectation is code between bytecode and LLVM's.

**Hand-rolled.** Not measured. A simple code generator without a
register allocator of note would also land between bytecode and LLVM's
output, closer to bytecode the less work goes into it.

## Dependency cost

**LLVM through `zig cc`.** Nothing new to build zisp: it is built with
Zig already. Compiling to native code at run time needs a Zig toolchain
where zisp runs. The one measured here is 250 MB. Without one, zisp
keeps compiling to bytecode.

**Cranelift.** A Rust toolchain to build zisp, and Cranelift's crates,
fetched and compiled as part of the build. Nothing at run time.

**Hand-rolled.** None.

## Debug information

**LLVM through `zig cc`.** `-g` gives DWARF line tables and variables,
and `#line` directives in the emitted C can point them at the Lisp
source. Debuggers and profilers read the result as they read any shared
library.

**Cranelift.** It produces unwind information. How far its DWARF
support for JIT code goes was not checked for this comparison.

**Hand-rolled.** Whatever zisp writes itself. Unwind information is
needed regardless; line tables and a `perf` map are further work.

## Build-time impact

**LLVM through `zig cc`.** None on building zisp. Compiling a unit takes
the `zig cc` run: about 100 ms for the measured file, which is fine for
`compile-file` and too slow for `compile` on every function at a REPL,
where bytecode stays the default.

**Cranelift.** The crates join zisp's build. Compiling a function at run
time is fast, which is what Cranelift is built for.

**Hand-rolled.** None on building zisp, and compiling a function at run
time is the fastest of the three.

## Recommendation

The hand-rolled backend, for x86_64 and aarch64, used by both `compile`
and `compile-file`, with bytecode kept as the fallback for any form the
backend does not yet handle.

zisp then depends on Zig to build and on nothing at run time. Native
code is bytes zisp writes into its own heap, so a saved image carries it
like any other object, and `compile` at the REPL starts no external
process.

What that costs:

- two instruction encoders, a register allocator, both calling
  conventions, unwind information and executable-memory handling
  (`MAP_JIT` on macOS) are zisp's own code to write and test;
- output quality is unmeasured. The `zig cc` figures above (25 and 34
  times bytecode on TAK) are the target to measure the backend against
  with `tests/run-codegen-tak.sh`;
- debug information beyond unwind tables is further work.

LLVM through `zig cc` was not chosen because of its 250 MB run-time
toolchain and 100 ms per unit, and Cranelift because of its Rust build
dependency.

## Sign-off

- [x] Approved, with the backend named here: hand-rolled
