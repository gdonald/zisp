# zisp

Common Lisp implementation written in Zig, targeting the ANSI INCITS 226-1994
standard.

## Requirements

- Zig 0.17.0 (pinned in `build.zig.zon`)
- Bash (only for `tests/run-ansi.sh`)
- Node (only for `zig build wasi-test` and `zig build wasm-test`)
- Linux or macOS — Windows is a non-goal

## Cloning

The ANSI test suite ships as a git submodule under `vendor/ansi-test/`
(GPL — kept separate from the zisp tree). After cloning:

```sh
git clone <url> zisp
cd zisp
git submodule update --init --recursive
```

If you cloned without `--recurse-submodules`, run the `submodule update`
line above. To pull upstream submodule changes later:

```sh
git submodule update --remote vendor/ansi-test
```

## Build

```sh
zig build              # build the zisp binary into zig-out/bin/
zig build run          # build and run the REPL
zig build tests        # run unit tests
zig build coverage     # run unit tests under kcov; report in ./coverage/
zig build ansi-test    # run the ANSI compliance suite
zig build wasi-test    # run the corpora in the wasm32-wasi build under Node
zig build wasm         # build the browser REPL into zig-out/web/
zig build wasm-test    # run the browser REPL's demo under Node
```

### Build options

```sh
zig build -Doptimize=ReleaseFast    # standard Zig optimization modes
zig build -Dansi-tests=true         # include ansi-test in the default build
zig build -Dprofile=true            # enable profiling hooks (placeholder)
zig build -Dfreestanding=true       # leave out the file system and the FFI
```

## Documentation

- [docs/tagging.md](docs/tagging.md) — value representation
- [docs/cli.md](docs/cli.md) — command-line interface
- [docs/ansi-test.md](docs/ansi-test.md) — running the compliance suite
- [docs/macros.md](docs/macros.md) - macro non-hygiene and gensym
- [docs/gc.md](docs/gc.md) - the collector
- [docs/printer.md](docs/printer.md) - the printer variables
- [docs/ffi.md](docs/ffi.md) - calling C functions
- [docs/wasm.md](docs/wasm.md) - the WebAssembly builds
- [docs/wasm-interop.md](docs/wasm-interop.md) - calling JavaScript from Lisp

## License

Zisp itself is MIT-licensed; see [LICENSE](LICENSE). The ansi-test suite
under `vendor/ansi-test/` is GPL — referenced but not redistributed inside
this tree.
