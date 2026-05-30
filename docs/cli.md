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
| `--eval EXPR`, `-e EXPR` | Read, evaluate, print EXPR. May be repeated. (planned) |
| `--load FILE`, `-l FILE` | Load FILE. May be repeated. (planned) |
| `--batch` | Process options and exit; suppress REPL. (planned) |
| `--quiet`, `-q` | Suppress startup banner. (planned) |
| `--script FILE` | Treat FILE as a script; remaining args bound to `*command-line-arguments*`. (planned) |
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
zisp --eval '(+ 1 2)'              # planned
zisp --load init.lisp --batch       # planned
zisp script.lisp arg1 arg2          # planned
```
