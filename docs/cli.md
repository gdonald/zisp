# Command-line interface

## Synopsis

```
zisp [OPTIONS] [FILE [ARGS...]]
```

## Options

| Option | Description |
|--------|-------------|
| `--version` | Print version and exit 0 |
| `--help`, `-h` | Print usage and exit 0 |
| `--eval EXPR`, `-e EXPR` | Read, evaluate, print EXPR. May be repeated. (Phase 2) |
| `--load FILE`, `-l FILE` | Load FILE. May be repeated. (Phase 2) |
| `--batch` | Process options and exit; suppress REPL. (Phase 2) |
| `--quiet`, `-q` | Suppress startup banner. (Phase 2) |
| `--script FILE` | Treat FILE as a script; remaining args bound to `*command-line-arguments*`. (Phase 2) |
| `--` | End of options |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | User error — bad arguments, file not found, etc. |
| `2` | Internal error — assertion failure, memory exhaustion, etc. |
| `3` | Lisp test failures (used by `tests/run-ansi.sh`) |
| `64`–`78` | Reserved (matches `sysexits.h` for compatibility with Unix conventions) |

## Examples

```sh
zisp --version
zisp --help
zisp --eval '(+ 1 2)'              # Phase 2
zisp --load init.lisp --batch       # Phase 2
zisp script.lisp arg1 arg2          # Phase 2
```
