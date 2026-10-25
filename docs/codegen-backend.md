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

LLVM through `zig cc`, for `compile-file`, with bytecode kept for
`compile` and as the fallback wherever no Zig toolchain is found.

It is the only option with measured output quality, and that quality is
the best of the three: TAK runs 25 times as fast as bytecode with
tagged values and 34 times with unboxed ones. It needs one emitter for
both targets, and debug information comes with it.

What that costs:

- native compilation at run time needs a 250 MB toolchain present;
- each compilation unit takes about 100 ms to build, which rules it out
  for compiling every form at a REPL;
- native code lives in shared libraries, so a saved image has to find
  and load those libraries again, or carry their contents and write
  them back out, when it starts.

Cranelift would remove the first two at the price of a Rust build
dependency, and the hand-rolled backend would remove all three at the
price of the largest implementation effort.

## Sign-off

- [ ] Approved, with the backend named here: ______ (initials)
