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
| `--eval EXPR`, `-e EXPR` | Read, evaluate, print EXPR. May be repeated. |
| `--load FILE`, `-l FILE` | Load FILE. May be repeated. |
| `--batch` | Process options and exit; suppress REPL. |
| `--quiet`, `-q` | Suppress startup banner. |
| `--script FILE` | Treat FILE as a script; remaining args bound to `*command-line-arguments*`. |
| `--read-only FILE` | Parse FILE without evaluating; report parse-rate. |
| `--` | End of options |

Options and positional arguments are processed left to right. `--eval` and
`--load` run in command-line order. A bare `FILE` positional (or one after
`--`) is treated as a script, the same as `--script FILE`. After processing,
the REPL starts unless `--batch` was given or a script ran. `(quit N)` / `(exit
N)` and uncaught errors set the process exit code.

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
zisp --eval '(+ 1 2)'
zisp --load init.lisp --batch
zisp script.lisp arg1 arg2
```
