# WebAssembly

zisp builds for `wasm32-wasi`, which runs under any WASI preview 1 host
with files, and for `wasm32-freestanding`, which runs in a browser
without them.

## wasm32-wasi

```sh
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe   # zig-out/bin/zisp.wasm
node scripts/run-wasi.mjs zig-out/bin/zisp.wasm --batch --eval '(print (expt 2 100))'
zig build wasi-test                                     # the corpora, under Node
```

`scripts/run-wasi.mjs` runs the module with Node's `node:wasi`, passing
the arguments after the module's path to zisp, with the current
directory preopened as `.`.

### Files

A WASI module reaches only the directories its host preopens, and names
files relative to them. `open`, `load`, `compile-file`, `probe-file`,
`directory`, `rename-file`, `delete-file` and `ensure-directories-exist`
all work inside a preopened directory. WASI has no `realpath`, so
`truename` and `probe-file` give back the name they were given once the
file is found, not an absolute path.

### 32-bit addresses

`wasm32` has 32-bit pointers. A Lisp value is still 64 bits, so fixnums
keep their 61 bits and the tags in `docs/tagging.md` are unchanged. An
address is taken out of a value as a `usize`, and heap objects keep
their 64-bit length fields.

### The foreign function interface

WASI has no dynamic loader, so the `ZISP-FFI` package exists but
`defcfun` and the memory functions have no natives under them.

## wasm32-freestanding

```sh
zig build wasm         # zig-out/web/: index.html, zisp.js, zisp-wasm.js, zisp.wasm
zig build wasm-test    # run the demo through zisp.js under Node
```

`zig-out/web/index.html` is a REPL: forms typed into the text area are
evaluated when Evaluate is pressed, and what they print and what they
log to the JavaScript console are shown under it. It opens from disk,
since `zisp-wasm.js` carries the module as base64 and the demo program
from `examples/wasm-repl/demo.lisp`. Opening it with `#demo` at the end
of the address runs the demo when the page loads.

`src/wasm.zig` holds the exports the page calls, and
`examples/wasm-repl/zisp.js` is the loader. A freestanding build has no
file system: `open`, `load` and the rest signal `file-error`.
`docs/wasm-interop.md` covers `js:call`.
