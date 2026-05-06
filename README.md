# zisp

Common Lisp implementation written in Zig, targeting the ANSI INCITS 226-1994
standard. See [ROADMAP.md](ROADMAP.md) for the phased plan and compliance
targets.

Status: Phase 0 (foundations).

## Requirements

- Zig 0.16.0 (pinned in `build.zig.zon`)
- Bash (only for `tests/run-ansi.sh`)
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
zig build test         # run unit tests
zig build coverage     # run unit tests under kcov; report in ./coverage/
zig build ansi-test    # run the ANSI compliance suite (Phase 1+)
```

### Build options

```sh
zig build -Doptimize=ReleaseFast    # standard Zig optimization modes
zig build -Dansi-tests=true         # include ansi-test in the default build
zig build -Dprofile=true            # enable profiling hooks (Phase 9 placeholder)
zig build -Dfreestanding=true       # embedded build (Phase 10 placeholder)
```

## Documentation

- [docs/tagging.md](docs/tagging.md) — value representation
- [docs/cli.md](docs/cli.md) — command-line interface
- [docs/ansi-test.md](docs/ansi-test.md) — running the compliance suite

## License

Zisp itself is MIT-licensed; see [LICENSE](LICENSE). The ansi-test suite
under `vendor/ansi-test/` is GPL — referenced but not redistributed inside
this tree.
