# Roadmap

Zisp is a Common Lisp implementation written in Zig, targeting the ANSI INCITS 226-1994 standard. This roadmap is **compliance-driven**: each phase is gated by a slice of the [ansi-test](https://gitlab.common-lisp.net/ansi-test/ansi-test) suite that the implementation must pass before moving on.

The phases below are sequential. Earlier phases establish the runtime substrate; later phases lean on it.

**Stall-proofing.** Items historically prone to "I built something, call it done" have an explicit acceptance criterion embedded in the bullet: a specific test, corpus size, performance number, or cross-implementation diff. "Done" means the named criterion passes, not "I wrote the code." Items that can't be implementation-defined upfront (codegen backend, comptime-Lisp surface, embedded target choice) require a written design doc as a prerequisite, not after-the-fact justification.

---

Phase 0: Foundations

Establish the project skeleton and the lowest-level data representation everything else will be built on. No Lisp code runs yet.

- [x] 0.1. Build system
  - [x] 0.1.1. `build.zig` with `zig build`, `zig build tests`, `zig build run`
  - [x] 0.1.2. Module layout: `src/runtime/`, `src/reader/`, `src/eval/`, `src/builtins/`, `src/repl/`
  - [x] 0.1.3. Test runner wired into `zig build tests`
  - [x] 0.1.4. CI configuration (GitHub Actions) running tests on Linux. Local development on macOS catches Darwin issues; redundant macOS CI not needed. Windows out of scope (see Non-Goals)
  - [x] 0.1.5. `zig fmt` enforced in CI
  - [x] 0.1.6. Build options: `-Doptimize`, `-Dansi-tests=true`, `-Dprofile`, `-Dfreestanding` (Phase 10 placeholder)
  - [x] 0.1.7. `zig build ansi-test` step that invokes `tests/run-ansi.sh`
- [x] 0.2. Value representation
  - [x] 0.2.1. Decide tagging scheme (recommend low-3-bit pointer tagging on 64-bit)
    - [x] 0.2.1.1. Tag layout document committed to repo (`docs/tagging.md`)
    - [x] 0.2.1.2. `000` — fixnum (61-bit signed)
    - [x] 0.2.1.3. `001` — cons pointer
    - [x] 0.2.1.4. `010` — symbol pointer
    - [x] 0.2.1.5. `011` — heap object pointer (string, vector, etc.) with secondary type byte
    - [x] 0.2.1.6. `100`–`111` — reserved for immediates (characters, booleans, single-float, special markers)
  - [x] 0.2.2. `Value` type as a `packed struct` or `u64` newtype with helper accessors
  - [x] 0.2.3. Constructors: `fixnum(i61)`, `cons(*Cons)`, `sym(*Symbol)`, etc.
  - [x] 0.2.4. Type predicates: `isFixnum`, `isCons`, `isSymbol`, `isAtom`, `isNil`, `isTrue`
  - [x] 0.2.5. Untagging helpers with `comptime` type checks
  - [x] 0.2.6. `NIL` and `T` as compile-time constants — currently `pub var` populated by `initStandardSymbols` since they need real symbol-table addresses; revisit if compile-time interning becomes possible
  - [x] 0.2.7. Unit tests for round-tripping every immediate type
- [x] 0.3. Heap layout
  - [x] 0.3.1. `Cons` struct (`car: Value`, `cdr: Value`) — exactly 16 bytes
  - [x] 0.3.2. Generic `HeapObject` header (type tag, size, GC flags) — sized for future mark bits
  - [x] 0.3.3. Allocator interface plumbing — runtime accepts any `std.mem.Allocator`
  - [x] 0.3.4. Bump/arena allocator as the Phase 0 default (GC arrives in Phase 5)
  - [x] 0.3.5. `cons(car, cdr)` and `car(v)` / `cdr(v)` / `setCar` / `setCdr`
  - [x] 0.3.6. Stress test: allocate and traverse a 1M-cell list
- [x] 0.4. Symbols and interning
  - [x] 0.4.1. `Symbol` struct: name, value cell, function cell, plist, package pointer (Phase 4)
  - [x] 0.4.2. Global intern table (hash map keyed by name)
  - [x] 0.4.3. `intern(name)` returns canonical symbol pointer
  - [x] 0.4.4. Pre-intern at startup: `NIL`, `T`, `QUOTE`, `LAMBDA`, `&REST`, `&OPTIONAL`, `&KEY`, `&BODY`, `&AUX`, `&WHOLE`, `&ENVIRONMENT`, `&ALLOW-OTHER-KEYS`
  - [x] 0.4.5. Case folding policy (default: upcase on read) — interner is case-sensitive; case folding lives in the Phase 1 reader (1.1.11)
- [x] 0.5. Debug printer
  - [x] 0.5.1. Minimal `print(value)` — enough to inspect from Zig tests, not yet ANSI-compliant
  - [x] 0.5.2. Cycle-safe (uses a small `seen` set)
- [x] 0.6. Driver / CLI surface (minimum viable)
  - [x] 0.6.1. `zisp --version` prints version and exits 0
  - [x] 0.6.2. `zisp --help` prints usage and exits 0
  - [x] 0.6.3. Argument parser scaffold (will grow `--eval`, `--load`, `--batch` in Phase 2)
  - [x] 0.6.4. Exit-code conventions documented (`docs/cli.md`): 0 success, 1 user error, 2 internal error, 3 test failures
- [x] 0.7. ansi-test infrastructure
  - [x] 0.7.1. `vendor/ansi-test/` submodule added (GPL — kept separate, not redistributed inside our tree)
  - [x] 0.7.2. `tests/run-ansi.sh` harness stub committed (categories enumerated, prerequisite checks, TODO markers for invocation)
  - [x] 0.7.3. `docs/ansi-test.md` explaining how to run, how categories map to phases, where the rt framework lives
  - [x] 0.7.4. Submodule clone / update instructions in README
- [x] 0.8. Logging and tracing
  - [x] 0.8.1. Categorical logger: `gc`, `reader`, `eval`, `compile`, `cli`
  - [x] 0.8.2. Compile-out at `ReleaseFast`, full at `Debug`, selectable at `ReleaseSafe` via env var
  - [x] 0.8.3. `*trace-output*` placeholder (real version Phase 4 once streams exist)
- [x] 0.9. Documentation scaffold
  - [x] 0.9.1. `docs/` directory with `tagging.md`, `cli.md`, `ansi-test.md` stubs
  - [x] 0.9.2. README updated with build / test / run instructions

Exit criteria: can construct, traverse, mutate, and print arbitrary cons trees from Zig. All Phase 0 unit tests green. `tests/run-ansi.sh` runs and reports `STUB:` lines for every category (proves submodule + binary plumbing work end-to-end).

---

Phase 1: The Reader and Printer

A round-trippable reader/printer is the first externally visible milestone.

- [x] 1.1. Tokenizer
  - [x] 1.1.1. Whitespace: space, tab, newline, CR, page
  - [x] 1.1.2. Line comments (`;` to end of line)
  - [x] 1.1.3. Block comments (`#| ... |#`) with proper nesting
  - [x] 1.1.4. Integer literals (decimal, with optional sign)
  - [x] 1.1.5. Radix prefixes: `#b`, `#o`, `#x`, `#nnR`
  - [x] 1.1.6. Float literals (`1.0`, `1e10`, `1.5d0`). Acceptance: 100-value corpus in `tests/lisp/float-literal-corpus.lisp` covering normal floats, subnormals, smallest/largest representable, precision-edge cases (e.g. `1.0000001`), exponent variants (`e`, `s`, `f`, `d`, `l`); each parses to the bitwise-exact `f32`/`f64` SBCL produces. Tokenizer recognizes the lexeme; numeric value parsing waits for this bullet's corpus gate.
  - [x] 1.1.7. Ratio literals (`1/2`) — unevaluated until Phase 4
  - [x] 1.1.8. String literals with `\"` and `\\` escapes
  - [x] 1.1.9. Character literals: `#\a`, `#\Space`, `#\Newline`, `#\Tab`, `#\U+XXXX`
  - [x] 1.1.10. Keywords (`:foo` → symbol in `KEYWORD` package, stubbed until Phase 4)
  - [x] 1.1.11. Symbol parsing including `|escaped pipes|` and backslash escapes
- [ ] 1.2. Reader
  - [x] 1.2.1. Recursive-descent parser returning `Value`
  - [x] 1.2.2. Lists with proper handling of `.` for dotted pairs
  - [x] 1.2.3. Empty list reads as `NIL`
  - [x] 1.2.4. `'x` → `(quote x)`
  - [x] 1.2.5. `` `x `` → `(quasiquote x)`
  - [x] 1.2.6. `,x` → `(unquote x)`
  - [x] 1.2.7. `,@x` → `(unquote-splicing x)`
  - [x] 1.2.8. `#'fn` → `(function fn)`
  - [x] 1.2.9. `#(...)` → vector literal (stub vector type)
  - [ ] 1.2.10. `#+feature` / `#-feature` conditional reading including compound expressions: `(or sbcl ccl)`, `(and unix (not aix))`, `(not (or windows darwin))`, arbitrarily nested. Acceptance: 30 forms in `tests/lisp/feature-expr-corpus.lisp` evaluate identically to SBCL given matching `*features*`. At least 10 forms must be nested ≥4 levels deep; at least 5 must mix `and`/`or`/`not`
  - [ ] 1.2.11. Reader macro dispatch table (so users can extend later)
  - [ ] 1.2.12. Source position tracking on every cons (for error reporting)
  - [x] 1.2.13. Error type hierarchy: `EndOfInput`, `UnbalancedParens`, `BadToken`
- [ ] 1.3. Printer
  - [ ] 1.3.1. `prin1` (readable, with escapes)
  - [ ] 1.3.2. `princ` (human, no escapes)
  - [ ] 1.3.3. `print` (newline + prin1 + space)
  - [ ] 1.3.4. Variables: `*print-readably*`, `*print-escape*`, `*print-base*`, `*print-radix*`
  - [ ] 1.3.5. Cycle detection (`*print-circle*`) — at least the safe-from-infinite-loop minimum
  - [ ] 1.3.6. Pretty printer scheduled for Phase 4.10 (NOT "later" — has an explicit phase)
- [ ] 1.4. Source position tracking
  - [ ] 1.4.1. `(file, line, column)` recorded per cons during read
  - [ ] 1.4.2. Reader errors include source position
  - [ ] 1.4.3. Position info survives macroexpansion. Acceptance: `tests/lisp/source-pos-corpus.lisp` contains 10 NON-TRIVIAL macros (each synthesizes new forms, wraps user code in additional structure, or nests another macro expansion — pass-through identity macros disqualified) where errors originate at known positions inside expansions. For each: the runtime error reports the user's call-site source position (not the macro's), and macro-introduced forms carry the macro definition's position. NOT bail-able to "best-effort" or to trivial macros that work by accident
- [ ] 1.5. Test harness
  - [ ] 1.5.1. Golden-file tests: read a `.lisp` fixture file, print it, diff against expected
  - [ ] 1.5.2. Property test: `read(print(x)) == x` for randomly generated values
  - [ ] 1.5.3. Reader-only mode in `tests/run-ansi.sh`: parse every file in `vendor/ansi-test/reader/` without evaluating, count parse failures
  - [ ] 1.5.4. Fuzzing target: `zig build fuzz-reader` driven by stdlib fuzz infrastructure

Exit criteria: reader/printer round-trips every form in the ansi-test reader category.

ansi-test slice: `reader/` (17 files), `printer/` (39 files)

Compliance milestone: ~3% of total `.lsp` files parse without error (reader-only — no evaluation yet).

---

Phase 2: Evaluator and Special Forms

A tree-walking evaluator sufficient to run hand-written Lisp.

- [ ] 2.1. Environment
  - [ ] 2.1.1. Lexical environment as a linked list of frames
  - [ ] 2.1.2. Frame = parallel arrays of symbols and values (or hash map past a threshold)
  - [ ] 2.1.3. Lookup: walk frames, fall back to symbol's global value cell
  - [ ] 2.1.4. Separate function namespace (Lisp-2): `symbol-function` distinct from `symbol-value`
- [ ] 2.2. `eval` core
  - [ ] 2.2.1. Self-evaluating forms (numbers, strings, characters, keywords, T, NIL)
  - [ ] 2.2.2. Symbol evaluation (variable lookup)
  - [ ] 2.2.3. List evaluation: dispatch on `car`
    - [ ] 2.2.3.1. Special form dispatch table
    - [ ] 2.2.3.2. Macro expansion (Phase 3 fills this in; stub now)
    - [ ] 2.2.3.3. Function application
- [ ] 2.3. Special forms
  - [ ] 2.3.1. `quote`
  - [ ] 2.3.2. `if`
  - [ ] 2.3.3. `progn`
  - [ ] 2.3.4. `setq` (multiple pairs)
  - [ ] 2.3.5. `let` and `let*`
  - [ ] 2.3.6. `flet`, `labels`
  - [ ] 2.3.7. `lambda` (returns closure)
  - [ ] 2.3.8. `function` (looks up function namespace)
  - [ ] 2.3.9. `block` and `return-from`
  - [ ] 2.3.10. `tagbody` and `go` including: backward jumps (loop construction), forward jumps, jumps out of nested `tagbody` (target tag in outer scope), `go` from inside an `unwind-protect` cleanup (cleanup runs, jump completes), `go` to a tag in dynamically-distant scope (must error if tag is no longer in scope). Acceptance: 8 cases in `tests/lisp/tagbody-corpus.lisp` diffed against SBCL
  - [ ] 2.3.11. `catch` and `throw` including: throw past 5+ frames, throw to a tag established by an outer caller, throw from inside an `unwind-protect` (cleanup runs first, throw completes), throw to non-existent tag (signals `control-error`), interaction with multiple values (thrown values match `multiple-value-list` semantics). Acceptance: 6 cases in `tests/lisp/catch-throw-corpus.lisp`
  - [ ] 2.3.12. `unwind-protect` (full version waits for Phase 6, stub now)
  - [ ] 2.3.13. `the` (type declaration — accept and ignore for now)
  - [ ] 2.3.14. `declare` parsing (accept and ignore most)
  - [ ] 2.3.15. `multiple-value-bind`, `multiple-value-call`, `values`, `values-list`, `multiple-value-prog1`, `multiple-value-list`. `multiple-value-call` MUST handle multiple producers correctly: `(multiple-value-call #'list (values 1 2) (values 3 4))` returns `(1 2 3 4)`. Acceptance: 8 cases in `tests/lisp/multiple-values-corpus.lisp` covering 0-value producers, 1-value producers, many-value producers, and mixing producers with regular forms in the same call
  - [ ] 2.3.16. `eval-when` (Phase 3 makes this load-bearing)
- [ ] 2.4. Function calls and lambda lists
  - [ ] 2.4.1. Required parameters
  - [ ] 2.4.2. `&optional` with default forms and supplied-p flags
  - [ ] 2.4.3. `&rest`
  - [ ] 2.4.4. `&key` with default forms and supplied-p. Includes: `&allow-other-keys` in lambda list, `:allow-other-keys t` from caller side overriding lambda-list strictness, duplicate keys (first wins per CLHS 3.4.1.4.1), odd-argument-count errors at call site, interaction with `&rest` (rest list contains the keyword/value pairs). Acceptance: 25 cases in `tests/lisp/key-args-corpus.lisp` covering each behavior independently; cross-tested against SBCL
  - [ ] 2.4.5. `&aux`
  - [ ] 2.4.6. Argument-count checking with proper error messages
  - [ ] 2.4.7. Closures capturing lexical environment
  - [ ] 2.4.8. Tail calls — `(defun f () (f))` runs 10 seconds without stack overflow (trampoline acceptable here; real TCO is 9.2.6, don't conflate)
  - [ ] 2.4.9. Multiple return values plumbed through call sites
- [ ] 2.5. Minimal built-in functions
  - [ ] 2.5.1. `cons`, `car`, `cdr`, `caar` … `cddddr`, `first` … `tenth`, `nth`, `nthcdr`
  - [ ] 2.5.2. `list`, `list*`, `append`, `reverse`, `nreverse`, `length`
  - [ ] 2.5.3. `eq`, `eql`, `equal`, `equalp`
  - [ ] 2.5.4. `atom`, `consp`, `listp`, `null`, `endp`, `symbolp`, `numberp`, `integerp`, `stringp`
  - [ ] 2.5.5. Fixnum arithmetic: `+`, `-`, `*`, `/`, `mod`, `rem`, `1+`, `1-`, `abs`, `min`, `max`
  - [ ] 2.5.6. Comparisons: `=`, `/=`, `<`, `>`, `<=`, `>=`, `zerop`, `plusp`, `minusp`, `oddp`, `evenp`
  - [ ] 2.5.7. `not`, `and` (special form), `or` (special form), `when`, `unless`, `cond` (as macros once Phase 3 lands)
  - [ ] 2.5.8. `funcall`, `apply`
  - [ ] 2.5.9. `mapcar`, `mapc`, `mapcan` over lists, INCLUDING multi-list forms: `(mapcar #'+ '(1 2 3) '(10 20 30)) => (11 22 33)`; stops at shortest list. Sequence-generic `map`/`map-into` come at 4.2 once vectors exist
- [ ] 2.6. REPL
  - [ ] 2.6.1. Read–eval–print loop in `src/repl/`
  - [ ] 2.6.2. `*`, `**`, `***` and `+`, `++`, `+++` history variables
  - [ ] 2.6.3. Error → break loop with `:abort` and `:continue` options (full version Phase 6)
- [ ] 2.7. Driver / CLI surface (Phase 2 expansion)
  - [ ] 2.7.1. `--eval EXPR` / `-e` — read, eval, print, repeat for each occurrence
  - [ ] 2.7.2. `--load FILE` / `-l` — load a Lisp file
  - [ ] 2.7.3. `--batch` — no REPL after processing args; exit when done
  - [ ] 2.7.4. `--quiet` / `-q` — suppress banner
  - [ ] 2.7.5. `--script FILE` — treat first arg as script, remaining args bound to a variable
  - [ ] 2.7.6. `--` separator: end-of-options
  - [ ] 2.7.7. Exit code propagates from uncaught errors / `(quit N)`
- [ ] 2.8. Minimal "batch" builtins required by the test harness
  - [ ] 2.8.1. `load` (file path, no `:if-does-not-exist` yet)
  - [ ] 2.8.2. `quit` / `exit` with optional integer status
  - [ ] 2.8.3. `*standard-output*` writes via Zig's I/O
  - [ ] 2.8.4. `format t` with at least `~A`, `~S`, `~D`, `~%`
  - [ ] 2.8.5. `*features*` populated (`:zisp`, `:ansi-cl`, host OS, host arch)
- [ ] 2.9. Test harness goes live
  - [ ] 2.9.1. Fill in `--eval` invocation TODO in `tests/run-ansi.sh`
  - [ ] 2.9.2. Parse `PASS=N FAIL=M` from output, accumulate per category
  - [ ] 2.9.3. Print per-phase summary (mapping categories to ROADMAP phases)
  - [ ] 2.9.4. Non-zero exit on any failures
  - [ ] 2.9.5. CI runs `zig build ansi-test` and tracks the pass rate

Exit criteria: REPL evaluates non-trivial recursive functions (factorial, naive fib, list reversal, ackermann within reason). `tests/run-ansi.sh cons` produces real pass/fail numbers.

ansi-test slice: `cons/` (72), `eval-and-compile/` (26), `symbols/` (16, subset), `data-and-control-flow/` (77, subset)

Compliance milestone: ~15% of total tests pass (most cons + flow tests; symbol tests need package work in Phase 4).

---

Phase 3: Macros

Macros are what make the rest of Common Lisp implementable *in Lisp*.

- [ ] 3.1. `defmacro` machinery
  - [ ] 3.1.1. `defmacro` special form / top-level definer
  - [ ] 3.1.2. Macro lambda lists with full destructuring. Split per feature:
    - [ ] 3.1.2a. Single-level destructuring: required params, `&optional`, `&rest`, `&key`. 6 cases in `tests/lisp/destructuring/basic.lisp`
    - [ ] 3.1.2b. `&body` with declare/docstring extraction at body position. 4 cases
    - [ ] 3.1.2c. `&whole` captures the full unparsed form. 3 cases
    - [ ] 3.1.2d. `&environment` captures the macroexpansion env (verified by nested `macroexpand` inside the macro body). 3 cases
    - [ ] 3.1.2e. Nested destructuring patterns (one level deep). 5 cases
    - [ ] 3.1.2f. Nested patterns to arbitrary depth + recursive `&optional`/`&rest`/`&key` inside nested patterns. 5 cases
    - [ ] 3.1.2g. Integration: `vendor/ansi-test/data-and-control-flow/destructuring-bind*.lsp` ≥ 95% pass rate; 30-form `tests/lisp/macro-destructuring-corpus.lisp` expands `equal` to SBCL
  - [ ] 3.1.3. Macro expansion happens before evaluation in `eval`
  - [ ] 3.1.4. `macroexpand-1` and `macroexpand` built-ins
  - [ ] 3.1.5. `*macroexpand-hook*`
- [ ] 3.2. Backquote
  - [ ] 3.2.1. Backquote → `(quasiquote ...)` reader transform
  - [ ] 3.2.2. Quasiquote expander producing equivalent `cons`/`list`/`append` calls
  - [ ] 3.2.3. `,@` splicing — `(equal (eval ``(a ,@'(b c) d)) '(a b c d))` and 20 similar cases pass
  - [ ] 3.2.4. Nested backquote. Split into 4 milestones:
    - [ ] 3.2.4a. Implement basic backquote algorithm at depth 1 (`'`, `,`, `,@`). 10 simple forms in `tests/lisp/backquote-basic.lisp` expand correctly
    - [ ] 3.2.4b. Implement nesting (depth 2+): each backquote increments a depth counter, each unquote decrements; only depth-0 unquotes evaluate. 10 nested forms expand correctly
    - [ ] 3.2.4c. CLtL2 Appendix C examples — every form in sections C.1–C.4 (~12 forms, the Steele test cases — historically tricky) expands `equal` to SBCL's expansion
    - [ ] 3.2.4d. Extended corpus — 38 additional forms with nesting depth ≥3 mixing `,`/`,@` at multiple levels, all `equal` to SBCL
  - [ ] 3.2.5. Edge cases: `` `,x ``, `` `,@x `` at top level error correctly; `` ``(,(,x)) `` evaluates without crashing
- [ ] 3.3. Hygiene helpers
  - [ ] 3.3.1. `gensym` with `*gensym-counter*`
  - [ ] 3.3.2. `gentemp`
  - [ ] 3.3.3. Documented gotcha: CL macros are *not* hygienic; this is by design
- [ ] 3.4. Compile-time control
  - [ ] 3.4.1. `eval-when` per CLHS 3.2.3.1. Split:
    - [ ] 3.4.1a. Top-level `eval-when` with each single situation: `:compile-toplevel`, `:load-toplevel`, `:execute` (3 cases)
    - [ ] 3.4.1b. Top-level `eval-when` with situation combinations (`:compile-toplevel :load-toplevel`, etc.) — all 7 non-empty subsets (7 cases)
    - [ ] 3.4.1c. `eval-when` nested inside `progn` at top level — same 7 subsets (7 cases)
    - [ ] 3.4.1d. `eval-when` in non-top-level position behaves per CLHS rules (situations other than `:execute` ignored). 4 cases
    - [ ] 3.4.1e. Deprecated situation keywords (`compile`/`load`/`eval`) accepted with warning. 3 cases
    - [ ] 3.4.1f. Full state-table coverage: 21 cases in `tests/lisp/eval-when-corpus.lisp` (one per cell of 3-situation × 7-position table); each produces exactly SBCL's output. Diff is empty
  - [ ] 3.4.2. Top-level form processing distinguishes file-compile from REPL (required for 3.4.1 to be testable). `*compile-file-pathname*`, `*compile-file-truename*`, `*load-pathname*`, `*load-truename*` populated correctly during their respective operations
- [ ] 3.5. Standard macros implementable now in Lisp (each is one session — implement, test, commit)
  - [ ] 3.5.1a. `when`, `unless`
  - [ ] 3.5.1b. `cond`
  - [ ] 3.5.1c. `case`, `ecase`, `ccase`
  - [ ] 3.5.1d. `typecase`, `etypecase`, `ctypecase`
  - [ ] 3.5.2. `and`, `or` reimplemented as macros over `if`
  - [ ] 3.5.3. `prog1`, `prog2`
  - [ ] 3.5.4a. `push`, `pop`
  - [ ] 3.5.4b. `pushnew` (with `:test` and `:key`)
  - [ ] 3.5.5. `incf`, `decf` (require `setf` infrastructure)
- [ ] 3.6. `setf`
  - [ ] 3.6.1. `setf` as a macro dispatching on the place form
  - [ ] 3.6.2. Built-in setf expanders (one session each):
    - [ ] 3.6.2a. `(setf car)`, `(setf cdr)`
    - [ ] 3.6.2b. `(setf nth)`, `(setf elt)`
    - [ ] 3.6.2c. `(setf aref)` (for vectors; multi-dim deferred to 4.3)
    - [ ] 3.6.2d. `(setf gethash)`
    - [ ] 3.6.2e. `(setf symbol-value)`, `(setf symbol-function)`, `(setf symbol-plist)`
    - [ ] 3.6.2f. `(setf get)` (property list)
  - [ ] 3.6.3. `defsetf` short form, then `defsetf` long form. Long form is NOT skippable: a `defsetf` for `(my-getter obj k)` with side-effecting subforms must call each subform exactly once
  - [ ] 3.6.4. `define-setf-expander` (long form). Acceptance: `tests/lisp/setf-expander-corpus.lisp` contains 5 expanders covering: side-effect ordering (each subform evaluated once, left-to-right), multiple store-variables (e.g. for `gethash` returning two values), environment capture, getting and setting share computed temporary, and a generic-function-style place
  - [ ] 3.6.5. `get-setf-expansion` returns the 5-value protocol (temps, vals, store-vars, store-form, access-form) per CLHS 5.1.1.2
- [ ] 3.7. ansi-test framework boots
  - [ ] 3.7.1. `vendor/ansi-test/rt-package.lsp` loads without error
  - [ ] 3.7.2. `vendor/ansi-test/rt.lsp` loads — defines `deftest`, `do-tests`, `pending-tests`
  - [ ] 3.7.3. `vendor/ansi-test/gclload1.lsp` runs end-to-end
  - [ ] 3.7.4. `(deftest trivial 1 1)` registers, `(do-tests)` reports it as passing
  - [ ] 3.7.5. The `:cl-test` package can be entered

Exit criteria: `when`, `unless`, `cond`, `and`, `or` are defined as macros (not special forms). All `setf` places used internally work. The rt framework loads and runs a synthetic test — meaning every subsequent phase can use `(deftest)` directly.

ansi-test slice: full `cons/`, `eval-and-compile/`, `data-and-control-flow/`, plus the subset of `symbols/` and `printer/` not requiring full type infrastructure.

Compliance milestone: ~30% of total tests pass.

---

Phase 4: Core Data Types

Fill out the type system so real CL programs can load.

- [ ] 4.1. Strings
  - [ ] 4.1.1. `simple-string` (immutable-by-convention, contiguous)
  - [ ] 4.1.2. `string` (mutable, may have fill pointer)
  - [ ] 4.1.3. `make-string`, `string=`, `string-equal`, `string<`
  - [ ] 4.1.4. `char`, `schar`, `(setf char)`, `(setf schar)`
  - [ ] 4.1.5. `string-upcase`, `string-downcase`, `string-capitalize` and destructive variants
  - [ ] 4.1.6. `string-trim`, `string-left-trim`, `string-right-trim`
  - [ ] 4.1.7. `concatenate 'string ...`
  - [ ] 4.1.8. `format` — at least `~A`, `~S`, `~D`, `~%`, `~~`, `~*`, `~&`, `~T`
  - [ ] 4.1.9. `format` advanced directives: `~[`, `~]`, `~{`, `~}`, `~^`, `~?`, `~/foo:bar/`. Acceptance: `vendor/ansi-test/printer/format*.lsp` pass rate ≥ 90%. NOT deferrable: "later" was the historic bail surface
- [ ] 4.2. Sequences (generic over lists/vectors/strings)
  - [ ] 4.2.1. `length`, `elt`, `(setf elt)`, `subseq`, `copy-seq`
  - [ ] 4.2.2. `map`, `map-into`
  - [ ] 4.2.3. `reduce`, `count`, `count-if`, `count-if-not`
  - [ ] 4.2.4. `find`, `find-if`, `find-if-not`, `position`, `position-if`
  - [ ] 4.2.5. `remove`, `remove-if`, `delete`, `delete-if` (and `-not` variants)
  - [ ] 4.2.6. `substitute`, `nsubstitute`
  - [ ] 4.2.7. `sort`, `stable-sort`, `merge`. `sort` is destructive, not required to be stable; `stable-sort` IS stable. Acceptance: `tests/lisp/stable-sort.lisp` sorts 1000 `(key index)` pairs by key — for every pair of equal-key elements, the index ordering is preserved (stability gate). `:key` and `:test` honored on all three; `merge` preserves stability when both inputs are sorted
  - [ ] 4.2.8. `concatenate`, `reverse`, `nreverse`
- [ ] 4.3. Vectors and arrays
  - [ ] 4.3.1. One-dimensional vectors with element-type and fill-pointer support
  - [ ] 4.3.2. `make-array` with `:element-type`, `:initial-element`, `:initial-contents`, `:adjustable`, `:fill-pointer`, `:displaced-to`. Acceptance: `tests/lisp/array-options-corpus.lisp` covers the (displaced/adjustable/fill-pointer) × (general/specialized element-type) interaction matrix — at least 12 cases — including: displaced-to an adjustable array, adjusting a displaced array, fill-pointer on a displaced array, displaced-to with an offset, and the spec-required errors for invalid combinations
  - [ ] 4.3.3. Multi-dimensional arrays (row-major layout)
  - [ ] 4.3.4. `aref`, `(setf aref)`, `row-major-aref`
  - [ ] 4.3.5. `array-rank`, `array-dimensions`, `array-total-size`
  - [ ] 4.3.6. Specialized arrays (at least `bit-vector` and `(unsigned-byte 8)`)
  - [ ] 4.3.7. `vector-push`, `vector-push-extend`, `vector-pop`
  - [ ] 4.3.8. `adjust-array`
- [ ] 4.4. Hash tables
  - [ ] 4.4.1. `make-hash-table` with `:test`, `:size`, `:rehash-size`, `:rehash-threshold`
  - [ ] 4.4.2. Tests: `eq`, `eql`, `equal`, `equalp`
  - [ ] 4.4.3. `gethash`, `(setf gethash)`, `remhash`, `clrhash`
  - [ ] 4.4.4. `maphash`, `with-hash-table-iterator`
  - [ ] 4.4.5. `hash-table-count`, `hash-table-size`, `hash-table-test`
- [ ] 4.5. Numeric tower
  - [ ] 4.5.1. Bignums (arbitrary-precision integers). Split:
    - [ ] 4.5.1a. Decision: wrap Zig's `std.math.big.int` vs hand-rolled limbs. Document in `docs/bignum-impl.md`
    - [ ] 4.5.1b. `bignum` heap type defined; allocator wired through GC; `print-object` produces decimal output
    - [ ] 4.5.1c. Bignum + bignum and bignum + fixnum addition, subtraction
    - [ ] 4.5.1d. Bignum multiplication
    - [ ] 4.5.1e. Bignum division: `floor`, `ceiling`, `truncate`, `round` (each returns quotient and remainder as multiple values)
    - [ ] 4.5.1f. Bignum comparisons: `=`, `<`, `>`, `<=`, `>=` (mixed bignum/fixnum)
    - [ ] 4.5.1g. Bit operations on bignums: `logand`, `logior`, `logxor`, `lognot`, `ash`, `integer-length`
  - [ ] 4.5.2. Automatic promotion from fixnum on overflow in `+`, `-`, `*` (uses 4.5.1c–d). Verified: `(* most-positive-fixnum 2)` returns a bignum without crash
  - [ ] 4.5.3. Integer division: `floor`, `ceiling`, `truncate`, `round` (with two return values)
  - [ ] 4.5.4. Ratios as `(numerator . denominator)` reduced to lowest terms
  - [ ] 4.5.5. Single-float and double-float (Zig's `f32`/`f64`) with shortest-round-trippable printing. Split into 4 milestones:
    - [ ] 4.5.5a. Algorithm decision: `docs/float-printing.md` written choosing among Steele-White / Ryu / Grisu, with implementation effort, output quality, dependency cost compared. Sign-off required
    - [ ] 4.5.5b. Basic float printing (any correct format, may produce too many digits): `(prin1 1.5)` produces `"1.5"`, `(prin1 1d0)` produces `"1.0d0"`. Pass: 50-value corpus formats without crash
    - [ ] 4.5.5c. Shortest-round-trippable: `(read-from-string (prin1-to-string x)) = x` (bitwise) for the basic 50-value corpus
    - [ ] 4.5.5d. Hard-case corpus: 1000 values including subnormals, denormals, smallest/largest representable, ±0.0, and values that historically expose Dragon4 bugs (`5e-324`, `2.2250738585072014e-308`, `1e23`). Round-trip bitwise for every value. NOT bail-able to `printf("%g", x)` — this corpus immediately catches it
  - [ ] 4.5.6. Complex numbers including branch-cut compliance for `log`, `sqrt`, `asin`, `acos`, `atan`, `atanh`, `phase` per CLHS 12.1.5.3. Acceptance: `vendor/ansi-test/numbers/complex*.lsp` and `branch-cut*.lsp` ≥ 90% pass rate
  - [ ] 4.5.7. Numeric contagion rules (integer + float → float)
  - [ ] 4.5.8. `gcd`, `lcm`, `expt` (including edge cases: `(expt 0 0) => 1`, `(expt -2 1/2)` returns complex, `(expt 2 1000)` returns bignum), `isqrt`, `sqrt`, `log` (1-arg natural log; 2-arg arbitrary base; `(log 0)` signals `arithmetic-error`), `exp`, `sin`/`cos`/`tan`/`asin`/`acos`/`atan` (2-arg `atan` with proper quadrant handling), `sinh`/`cosh`/`tanh` and inverses. Acceptance: `vendor/ansi-test/numbers/` transcendental files (count, embed) ≥ 85% pass rate
  - [ ] 4.5.9. `random` and `*random-state*`
- [ ] 4.6. Characters
  - [ ] 4.6.1. Character object distinct from fixnum
  - [ ] 4.6.2. `char-code`, `code-char`, `char-name`, `name-char`
  - [ ] 4.6.3. `alpha-char-p`, `alphanumericp`, `digit-char-p`, `upper-case-p`, `lower-case-p`
  - [ ] 4.6.4. Full Unicode case mapping. Acceptance: 50 cases in `tests/lisp/unicode-cases.lisp` pass, MUST include: Turkish locale i/I/ı/İ pair behavior, German ß ↔ SS round-trip, Greek final sigma context (ς in word-final, σ elsewhere), ligatures (ﬃ → FFI), combining marks (composed vs decomposed equivalence), surrogate pair edge cases at the BMP boundary, and at least 5 cases from `SpecialCasing.txt` that Zig's stdlib doesn't handle (forces manual port of those rows). NOT bail-able to "ASCII + BMP" — the Turkish and ligature cases are explicit gates
- [ ] 4.7. Pathnames and streams
  - [ ] 4.7.1. `pathname` type with all six components (host/device/directory/name/type/version). Physical pathnames only at this phase — logical pathnames explicitly stubbed with a `feature-not-implemented` error and tracked as 4.7.9 below. NOT bail-able to "skip version" — the version component (`:newest`, `:wild`, integer) must round-trip through `make-pathname`/`pathname-version`
  - [ ] 4.7.2. `make-pathname`, `merge-pathnames`, `namestring`, `parse-namestring`. `merge-pathnames` follows the "missing component" rules from CLHS 19.2.2.4 exactly. Acceptance: `vendor/ansi-test/pathnames/` pass rate ≥ 85% on the non-logical-pathname subset; specifically, all 18 `merge-pathnames*.lsp` test cases pass
  - [ ] 4.7.3. Stream protocol: input, output, bidirectional, character vs binary
  - [ ] 4.7.4. `open`, `close`, `with-open-file` with full option matrix. Split into 5 milestones:
    - [ ] 4.7.4a. Basic `open`/`close` with `:direction :input` reading a file; `with-open-file` ensures close on normal exit AND on error. 4 cases
    - [ ] 4.7.4b. `:direction` variants: `:input`, `:output`, `:io`, `:probe`. 4 cases (one per direction)
    - [ ] 4.7.4c. `:if-exists` matrix: `:supersede`, `:append`, `:overwrite`, `:rename`, `:rename-and-delete`, `:error`, `:new-version`, `nil`. 8 cases
    - [ ] 4.7.4d. `:if-does-not-exist` matrix: `:create`, `:error`, `nil`. 3 cases
    - [ ] 4.7.4e. `:element-type` (`character`, `(unsigned-byte 8)`, `(signed-byte 16)`) and `:external-format` (`:utf-8`, `:latin-1`). 6 cases including byte-stream round-trip and UTF-8 round-trip
  - [ ] 4.7.5. `read-char`, `peek-char`, `unread-char`, `write-char`
  - [ ] 4.7.6. `read-line`, `write-line`, `write-string`
  - [ ] 4.7.7. String streams: `with-input-from-string`, `with-output-to-string`
  - [ ] 4.7.8. `*standard-input*`, `*standard-output*`, `*error-output*`, `*query-io*`, `*terminal-io*`
  - [ ] 4.7.9. Logical pathnames. `logical-pathname-translations`, `translate-logical-pathname`, `load-logical-pathname-translations`. Acceptance: `vendor/ansi-test/pathnames/logical*.lsp` pass rate ≥ 80%. MUST land in Phase 4 — Phase 4 is incomplete until 4.7.9 is checked. NOT bail-able to "rarely used, defer to Phase 10"
- [ ] 4.8. Packages
  - [ ] 4.8.1. `package` type
  - [ ] 4.8.2. Standard packages: `COMMON-LISP` (`CL`), `COMMON-LISP-USER` (`CL-USER`), `KEYWORD`
  - [ ] 4.8.3. `defpackage`, `make-package`, `delete-package`
  - [ ] 4.8.4. `in-package`, `*package*`
  - [ ] 4.8.5. Symbol movement and conflict resolution per CLHS 11.1.1.2.5. Split per operation:
    - [ ] 4.8.5a. `export` — internal symbol becomes external; symbol becomes accessible to packages that `use` this one
    - [ ] 4.8.5b. `import` (no conflict case) — symbol becomes internal in the package; multiple imports of the same symbol are no-ops
    - [ ] 4.8.5c. `import` conflict detection — importing a symbol when a different symbol of the same name is accessible signals `package-error`. 3 cases
    - [ ] 4.8.5d. `unintern` — basic case removes symbol from package
    - [ ] 4.8.5e. `unintern` of a shadowing symbol triggers conflict re-check among used packages. 2 cases
    - [ ] 4.8.5f. `shadow` — creates new internal symbol if none exists, marks existing symbol as shadowing
    - [ ] 4.8.5g. `shadowing-import` — resolves conflicts silently by replacing the inherited symbol
    - [ ] 4.8.5h. Use-package conflict at `use-package` time — two packages exporting same name signals `package-error`. 3 cases
    - [ ] 4.8.5i. Integration: 15-case `tests/lisp/package-conflict-corpus.lisp` covering all the above interactions; cross-tested against SBCL
  - [ ] 4.8.6. `use-package`, `unuse-package`
  - [ ] 4.8.7. Symbol resolution: internal vs external, `pkg:sym` vs `pkg::sym`
  - [ ] 4.8.8. `find-symbol`, `intern`, `find-package`
  - [ ] 4.8.9. `do-symbols`, `do-external-symbols`, `do-all-symbols`
- [ ] 4.9. Type system
  - [ ] 4.9.1. `typep` and `subtypep`. Split:
    - [ ] 4.9.1a. `typep` for atomic types: `null`, `cons`, `symbol`, `fixnum`, `bignum`, `integer`, `ratio`, `float`, `string`, `vector`, `array`, `hash-table`, `function`, `package`, `pathname`, `stream`, `character`, `t`, `nil`. One case per type
    - [ ] 4.9.1b. `typep` for compound numeric types: `(integer 0 100)`, `(real * 1.0)`, `(unsigned-byte 8)`, `(signed-byte 16)`, `(mod N)`. 6 cases
    - [ ] 4.9.1c. `typep` for compound combinators: `(or T T ...)`, `(and T T ...)`, `(not T)`, `(satisfies fn)`, `(member ...)`, `(eql x)`. 6 cases including nesting
    - [ ] 4.9.1d. `typep` for `deftype`-defined types (composes recursively). 4 cases
    - [ ] 4.9.1e. `typep` integration: `vendor/ansi-test/types-and-classes/typep*.lsp` ≥ 95%
    - [ ] 4.9.1f. `subtypep` two-value return per CLHS 4.3.2. Atomic-type lattice (e.g. `(subtypep 'integer 'number) => (t t)`). 10 cases
    - [ ] 4.9.1g. `subtypep` for compound numeric types (e.g. `(subtypep '(integer 0 5) '(integer 0 10))`). 8 cases
    - [ ] 4.9.1h. `subtypep` for compound combinators (`or`/`and`/`not` interactions). 10 cases
    - [ ] 4.9.1i. `subtypep` undecidable-case behavior: returns `(nil nil)` only where SBCL also does. Diff against SBCL on every `subtypep*.lsp` test
    - [ ] 4.9.1j. `subtypep` integration: `subtypep*.lsp` pass rate ≥ 80%. NOT bail-able to "always returns (nil nil)" — the SBCL diff catches it
  - [ ] 4.9.2. `deftype`
  - [ ] 4.9.3. Type specifiers: atomic, compound (`(integer 0 100)`, `(or string null)`)
  - [ ] 4.9.4. `check-type`, `coerce`
- [ ] 4.10. Pretty printer
  - [ ] 4.10.1. `pprint` writes to `*standard-output*` with `*print-pretty*` honored
  - [ ] 4.10.2. `pprint-logical-block`, `pprint-newline`, `pprint-indent`, `pprint-fill`, `pprint-tab`
  - [ ] 4.10.3. `*print-right-margin*` honored. Acceptance: 20-input corpus in `tests/lisp/pprint-corpus.lisp` MUST include: deeply-nested lists (depth ≥10), atoms wider than the right margin, mixed cons/vector/string in one form, recursive structures via `*print-circle*`, miser-mode triggers (forms too wide for right margin causing all-clauses-on-own-line). Output diffed against SBCL byte-for-byte
  - [ ] 4.10.4. Pretty-print dispatch tables: `set-pprint-dispatch`, `copy-pprint-dispatch`

Exit criteria: numeric tower behaves correctly across type boundaries; symbols resolve through packages; can read and write text files.

ansi-test slice: `strings.lsp`, `arrays.lsp`, `hash-tables.lsp`, `numbers.lsp`, `characters.lsp`, `packages.lsp`, `pathnames.lsp`, `streams.lsp`, `types-and-class.lsp`

---

Phase 5: Garbage Collector

Replace the arena with a real GC. Until this phase, long-running programs leak.

- [ ] 5.1. Mark-and-sweep baseline
  - [ ] 5.1.1. Mark bit added to `HeapObject` header (1 bit reserved in flags)
  - [ ] 5.1.2. Free list. Split:
    - [ ] 5.1.2a. Single global free list (simplest). Allocation pops from head; deallocation pushes to head
    - [ ] 5.1.2b. Free-list integrity test: 10000 alloc/free cycles, assert no double-free, no corruption (`tests/lisp/freelist-stress.lisp`)
    - [ ] 5.1.2c. Free list per size class (4 classes: 16/32/64/128 bytes). Larger requests go to a generic block allocator
    - [ ] 5.1.2d. Per-size-class fragmentation test: 1000 allocs of each class, free half, allocs of same class succeed without growing heap
  - [ ] 5.1.3. Mark phase. Split:
    - [ ] 5.1.3a. Mark a single object: set its mark bit. Test: mark a cons, verify bit is set
    - [ ] 5.1.3b. Recursive mark for cons cells (car + cdr). Test: mark root of 100-cell list, verify all cells marked
    - [ ] 5.1.3c. Type-dispatch in mark: extend to symbol (value/function/plist), string (no children), vector (each element), hash-table (each k/v)
    - [ ] 5.1.3d. Convert recursive mark to worklist (avoid Zig stack overflow on deep structures). Test: mark a 1M-cell list without crash
  - [ ] 5.1.4. Sweep phase: reclaim unmarked AND coalesce adjacent free blocks. Acceptance: `tests/lisp/gc-fragmentation.lisp` allocates 10000 cells of varying sizes, frees alternate cells (creating worst-case fragmentation), runs GC. After GC, `(room)` reports free-block count ≤ `(/ allocated-count 100)` — i.e. ≥99% of adjacent free blocks merged. NOT bail-able to "size classes hide fragmentation"
  - [ ] 5.1.5. Trigger heuristic: GC when allocated bytes since last GC > threshold
- [ ] 5.2. Root scanning
  - [ ] 5.2.1. Symbol table (every interned symbol's value/function cells)
  - [ ] 5.2.2. Global environment frames
  - [ ] 5.2.3. Active call stack — Lisp frames maintained explicitly (not Zig stack)
  - [ ] 5.2.4. `*` `**` `***` and other REPL state
  - [ ] 5.2.5. Open streams
  - [ ] 5.2.6. Pinned objects (for FFI)
- [ ] 5.3. Stack discipline
  - [ ] 5.3.1. Lisp call stack as an explicit growable array of `Value`
  - [ ] 5.3.2. Helper: "shadow stack" pattern for any Zig function holding live `Value`s during a possible GC
  - [ ] 5.3.3. No Zig function holds a raw `*Cons` (or any heap pointer) across a possible-GC point. Enforced mechanically: every allocation function increments a generation counter; in `Debug` builds, every dereference of a held heap pointer checks the counter and aborts if it changed across an allocation. CI runs the full test suite under `Debug` so violations break the build. NOT bail-able to "I read the code carefully" — the runtime check is the gate
- [ ] 5.4. Write barrier scaffolding
  - [ ] 5.4.1. Centralize all heap mutation through `setCar`, `setCdr`, `setSlot`
  - [ ] 5.4.2. Barrier is a no-op now; in place for generational upgrade
- [ ] 5.5. Generational follow-up
  - [ ] 5.5.1. Two generations: nursery + tenured
  - [ ] 5.5.2. Bump-pointer allocation in the nursery — verified via `(loop repeat 1000000 do (cons nil nil))` showing nursery growth in `(room)` with no tenured promotion until first GC
  - [ ] 5.5.3. Minor GC: copy survivors to tenured. Split into 4 milestones:
    - [ ] 5.5.3a-i. Copy phase for cons cells only: scan roots, copy reachable nursery cons to tenured, install forwarding pointer in old location. `tests/lisp/gc-copy-cons.lisp` — allocate 100 cons in nursery, force minor GC, all 100 accessible and now in tenured
    - [ ] 5.5.3a-ii. Forwarding-pointer follow during copy: a cons whose `car` points to an already-copied object uses the forwarding pointer (not a stale nursery address). Test: build a graph with shared substructure, copy, assert sharing preserved
    - [ ] 5.5.3a-iii. Extend copy to all heap types (symbol, string, vector, hash-table, function). One sub-test per type
    - [ ] 5.5.3a-iv. Update all roots after copy (symbol table, env frames, REPL state) to point at new locations. Test: a global variable bound to a nursery cons points to the tenured copy after GC
    - [ ] 5.5.3b. Trigger heuristic: minor GC auto-fires when nursery exceeds 1MB. `(loop for i below 200000 do (cons nil nil))` shows nursery peak ≤ 1.05MB (trigger fires within 5% of threshold)
    - [ ] 5.5.3c. Long-running stress: `(loop repeat 100000000 do (cons nil nil))` retaining every 1000th cell completes without OOM; tenured grows linearly with retained count
    - [ ] 5.5.3d. Pause-time gate: minor GC pause ≤ 5% of total mutator time over a 60-second run on the CI Linux runner (specs in `docs/perf-baseline.md`)
  - [ ] 5.5.4. Card table populated by the write barrier. Split into 4 milestones:
    - [ ] 5.5.4a. Write-barrier wired through 5.4.1's centralized mutation points: every `setCar`/`setCdr`/`setSlot` that creates an old→young pointer marks the corresponding card. NOT bail-able to "barrier off in production"
    - [ ] 5.5.4b. Card scan: minor GC scans dirty cards in tenured BEFORE scanning roots. `tests/lisp/card-scan.lisp` manually creates an old→young pointer, forces minor GC, verifies the young object survives (would be lost without card scan)
    - [ ] 5.5.4c. Fuzz verification: 100k random mutations seeded such that ≥10% create cross-generation pointers (fuzz harness asserts this via counter — if not, fuzzer bug). Full-scan of tenured then asserts every cross-gen pointer's card is marked
    - [ ] 5.5.4d. Performance gate: cl-bench `boyer` regression ≤ 5% vs. non-generational baseline (numbers committed to `docs/perf-baseline.md`)
  - [ ] 5.5.5. Major GC fallback (mark-sweep over tenured) — triggered when tenured exceeds 4× post-major size; verified by forcing repeated minor GCs and observing eventual major
- [ ] 5.6. Introspection and tuning
  - [ ] 5.6.1. `room` built-in
  - [ ] 5.6.2. `(gc)` to force a collection
  - [ ] 5.6.3. `*gc-verbose*`, `*gc-trigger*`
  - [ ] 5.6.4. Stats: bytes allocated, GC time, pause histogram
  - [ ] 5.6.5. `ext:weak-pointer` per CMUCL convention. `(make-weak-pointer obj)` returns a weak-pointer; `(weak-pointer-value wp)` returns `(values obj t)` if `obj` is still live, `(values nil nil)` if collected. Acceptance: `tests/lisp/weak-pointer.lisp` — create weak-pointer to a fresh cons, drop strong references, force GC, `weak-pointer-value` returns `(nil nil)`; with strong reference retained, value persists across 10 forced GC cycles
- [ ] 5.7. Finalization
  - [ ] 5.7.1. Finalizer registration on heap objects
  - [ ] 5.7.2. Finalizers run after GC completes, in a state where allocation is permitted (i.e. on the mutator thread, not inside the collector). Re-entrancy: a finalizer that allocates and triggers another GC must not re-enter the finalizer queue for entries currently being processed; pending finalizers from the inner GC are added to the back of the queue and run after the current pass completes. Acceptance: `tests/lisp/finalizer-recursion.lisp` runs 1000 cycles of allocate-with-finalizer-that-allocates without crash, deadlock, or skipped finalizers; finalizer count exactly matches expected

Exit criteria: ansi-test suite runs to completion without OOM; `cl-bench` runs and produces numbers.

---

Phase 6: Condition System

Common Lisp's condition system is more powerful than exceptions in most languages and is depended on by large parts of the standard library.

- [ ] 6.1. Conditions as classes
  - [ ] 6.1.1. `define-condition`. Bootstrap plan documented in `docs/condition-bootstrap.md` BEFORE implementation (covers: minimal class layout, slot model, what 7.4.7 will rip out). Acceptance: doc reviewed; minimal class system has a single source file `src/runtime/proto_class.zig` named so it's grep-able for 7.4.7's deletion
  - [ ] 6.1.2. Standard hierarchy: `condition`, `serious-condition`, `error`, `warning`, `simple-condition`, `simple-error`, `simple-warning`, `type-error`, `program-error`, `control-error`, `arithmetic-error`, `division-by-zero`, `floating-point-overflow`, `floating-point-underflow`, `cell-error`, `unbound-variable`, `undefined-function`, `unbound-slot`, `package-error`, `stream-error`, `end-of-file`, `file-error`, `parse-error`, `reader-error`, `print-not-readable`, `storage-condition`
  - [ ] 6.1.3. `make-condition`
  - [ ] 6.1.4. Condition slot access via standard CLOS-style accessors
- [ ] 6.2. Signaling
  - [ ] 6.2.1. `signal`, `error`, `cerror`, `warn`
  - [ ] 6.2.2. `*break-on-signals*`
  - [ ] 6.2.3. Type-coercion: `(error "msg ~A" x)` → `simple-error`
  - [ ] 6.2.4. Condition designators (symbol, condition, format string)
- [ ] 6.3. Handling
  - [ ] 6.3.1. `handler-case` (unwinding)
  - [ ] 6.3.2. `handler-bind` (non-unwinding)
  - [ ] 6.3.3. `ignore-errors`
  - [ ] 6.3.4. Handler search walks dynamically-bound handler stack: most-recently-bound matching handler fires first; `handler-bind` handlers can decline (return normally) and search continues to outer handlers; `handler-case` handlers always unwind. Acceptance: 10 cases in `tests/lisp/handler-search.lisp` covering: nested `handler-bind` with mixed condition types, `handler-bind` declining and falling through to outer handler, mixed `handler-bind`/`handler-case` nesting, handler that signals a different condition (must search from where it was bound, not from the original signal site)
- [ ] 6.4. Restarts (split per facility)
  - [ ] 6.4.1a. `restart-bind` (non-unwinding) — establishes named restarts available via `find-restart`/`invoke-restart`. 3 cases
  - [ ] 6.4.1b. `restart-case` (unwinding) — clauses with bodies; `invoke-restart` unwinds to the matching clause and runs its body. 4 cases
  - [ ] 6.4.1c. `restart-case` clause options: `:report`, `:test`, `:interactive`. 3 cases
  - [ ] 6.4.2a. `invoke-restart` by name and by restart-object. 2 cases
  - [ ] 6.4.2b. `invoke-restart-interactively` calls the `:interactive` function for arguments. 2 cases
  - [ ] 6.4.3. `find-restart`, `compute-restarts` — return all visible restarts; filtering by condition deferred to 6.4.5
  - [ ] 6.4.4a. Standard restart `abort` — always available, signals `control-error` if invoked when no abort point exists
  - [ ] 6.4.4b. Standard restart `continue` — `cerror` establishes; `(continue)` is the convenience function
  - [ ] 6.4.4c. Standard restart `muffle-warning` — `warn` establishes; suppresses the warning print
  - [ ] 6.4.4d. Standard restarts `store-value`, `use-value` — establishment by `signal`/`error`; differ in whether the value is stored back at the source or just used
  - [ ] 6.4.5. `with-condition-restarts` associates a restart set with a specific condition object so `compute-restarts` can filter by condition. Acceptance: 5 cases in `tests/lisp/with-condition-restarts.lisp` — establish 3 restarts under `with-condition-restarts` for condition A, signal A and B; `compute-restarts` for A returns the associated subset; for B returns only the unassociated restarts; restarts established outside `with-condition-restarts` are visible to all conditions
- [ ] 6.5. Debugger
  - [ ] 6.5.1. `*debugger-hook*`
  - [ ] 6.5.2. Default debugger. Split into 6 milestones:
    - [ ] 6.5.2a. Debugger entry banner: prints condition report (via `format`; `print-object` once 7.5.1 lands), lists numbered restarts with their reports, prompts `Debug>`. `tests/lisp/debugger-banner.lisp` asserts exact output for 3 conditions
    - [ ] 6.5.2b. Integer input selects restart by index. 1 scripted session
    - [ ] 6.5.2c. Lisp-form input is evaluated in the broken environment (lexical bindings of error site available). 2 scripted sessions including form that references a let-bound variable from the error site
    - [ ] 6.5.2d. Nested debugger entry: form evaluation that triggers another error opens an inner debugger; `abort` returns to outer. 1 scripted session
    - [ ] 6.5.2e. `:r NAME` selects restart by name match; `invoke-restart-interactively` prompts for arguments. 2 scripted sessions
    - [ ] 6.5.2f. Edge cases: condition with no restarts allows only form evaluation; `abort` at top-level returns to REPL or exits per CLI flags. 2 scripted sessions
  - [ ] 6.5.3. Backtrace produces every active Lisp frame (function name + source position from 1.4.3, plus argument values). Native code frames are added in Phase 9; the backtrace protocol is wired now and Phase 9 fills in additional information without changing the contract. Acceptance: `tests/lisp/backtrace-corpus.lisp` has 10 cases — each provokes an error N levels deep into a recursion (N from 1 to 10), captures `(*debugger-hook*)` invocation, asserts the backtrace lists exactly N frames with correct names and source positions. NOT bail-able to "current frame only" — the depth-N test is the gate
  - [ ] 6.5.4. `(break "msg" args)` enters the debugger with a continuable `simple-condition` of type `break`; the `continue` restart returns from the call. Acceptance: `(let ((x 0)) (break "test") x)` enters debugger, on `continue` returns `0`; `break` from inside a `handler-bind` for `condition` does NOT invoke the handler (break conditions explicitly bypass condition handlers per CLHS 25.1.7)
- [ ] 6.6. Unwinding
  - [ ] 6.6.1. `unwind-protect` runs cleanup on every non-local exit. Split into 5 milestones (each adds cases to `tests/lisp/unwind-protect-corpus.lisp`):
    - [ ] 6.6.1a. Normal exit + signaled error — cleanup runs in both. 4 cases
    - [ ] 6.6.1b. `throw` past 3+ frames; `return-from` past nested unwind-protects; `go` to outer `tagbody`. 6 cases
    - [ ] 6.6.1c. `abort` restart through nested handlers. 3 cases
    - [ ] 6.6.1d. Error during cleanup itself; `throw` during cleanup. 4 cases (subtle: subsequent cleanups must still fire)
    - [ ] 6.6.1e. Each case asserts exact cleanup ordering and final return state, diffed against SBCL. 3 additional adversarial cases (cleanup forms with side effects observable across exit paths)
  - [ ] 6.6.2. Cleanup order: cleanups fire in REVERSE order of unwind-protect frame entry; error during one cleanup does NOT prevent later cleanups from running. Verified by case set in 6.6.1d

Exit criteria: restartable errors work end-to-end from the REPL; can recover from `unbound-variable` by entering a value.

ansi-test slice: `conditions.lsp`

---

Phase 7: CLOS

The Common Lisp Object System. Large, but mostly implementable in Lisp once the metaobject hooks exist.

- [ ] 7.1. Classes
  - [ ] 7.1.1. `defclass`
  - [ ] 7.1.2. Slot specifications (one session per option):
    - [ ] 7.1.2a. `:initform` — default value evaluated when slot needs initialization
    - [ ] 7.1.2b. `:initarg` — keyword binding for `make-instance`
    - [ ] 7.1.2c. `:accessor` — generates both reader and writer generic functions
    - [ ] 7.1.2d. `:reader` and `:writer` — separate generation
    - [ ] 7.1.2e. `:allocation :class` — slot shared across all instances of the class
    - [ ] 7.1.2f. `:type` — slot writes assert type at `(safety > 0)`
    - [ ] 7.1.2g. `:documentation` — string accessible via `documentation`
    - [ ] 7.1.2h. Slot inheritance: combined slot definition merges options from each class in the MRO per AMOP. 4 cases
  - [ ] 7.1.3. `make-instance`, `initialize-instance`, `shared-initialize`, `reinitialize-instance`. Protocol ordering (per AMOP): `make-instance` → `allocate-instance` → `initialize-instance` (which in standard method calls `shared-initialize` with `t` for slot-names). `:before`/`:after` methods on `initialize-instance` and `shared-initialize` interleave correctly across the inheritance chain (most-specific `:before` first, least-specific `:after` last, around the primary chain). Acceptance: `tests/lisp/init-protocol.lisp` has 12 cases — each defines a class hierarchy with `:before`/`:after` methods on both `initialize-instance` and `shared-initialize` that record the call sequence into a list; asserted call sequence is `equal` to SBCL's
  - [ ] 7.1.4. `slot-value`, `(setf slot-value)`, `slot-boundp`, `slot-makunbound`
  - [ ] 7.1.5. `with-slots`, `with-accessors`
  - [ ] 7.1.6. Class redefinition with `update-instance-for-redefined-class`. Split into 4 milestones:
    - [ ] 7.1.6a. Lazy detection: redefining a class via `defclass` marks existing instances obsolete WITHOUT touching them. Next slot access triggers `update-instance-for-redefined-class`. `tests/lisp/class-redef-lazy.lisp` — redefine, sleep 100ms, access slot, verify protocol fires
    - [ ] 7.1.6b. Slot migrations — add slot (initform fires), remove slot (value passed to user method), retain slot (value preserved). 3 cases
    - [ ] 7.1.6c. User method using removed-slot values to populate new slots (migration pattern). 2 cases including a rename
    - [ ] 7.1.6d. Edge cases: change slot type (existing value violates new type → initform), redefine superclass list, multiple successive redefinitions on the same instance, redefine-then-`change-class` interaction. 4 cases
  - [ ] 7.1.7. `change-class` and `update-instance-for-different-class` — lazy migration: redefining a class doesn't touch existing instances until next access; `change-class` migrates slots correctly. Acceptance: 10 specific test cases in `tests/lisp/clos-redef.lisp` pass, including: shared-slot retention, slot-type widening, slot deletion
- [ ] 7.2. Generic functions and methods
  - [ ] 7.2.1. `defgeneric`
  - [ ] 7.2.2. `defmethod` with required and `&optional`/`&rest`/`&key` parameters
  - [ ] 7.2.3. Specialization on classes and on `eql` specializers
  - [ ] 7.2.4. Method combination — standard (`:before`, `:after`, `:around`, primary). Acceptance: a generic function with 2 `:before`, 2 `:after`, 2 `:around`, and 3 primary methods executes in correct order (test asserts the exact trace)
  - [ ] 7.2.5. Built-in method combinations: `+`, `and`, `or`, `list`, `append`, `nconc`, `min`, `max`, `progn`, `standard`. Acceptance: each combination has a 3-method test that asserts the combined return value
  - [ ] 7.2.6. `define-method-combination` short form — `(define-method-combination my-and :identity-with-one-argument t)` works with 4+ methods
  - [ ] 7.2.7. `define-method-combination` long form. Split into 4 milestones (this is THE bullet historically stopped at — no excuses, no "would you like to work on something else?"):
    - [ ] 7.2.7a. Parse the long-form syntax `(define-method-combination name lambda-list method-group-spec* options* body)`. `tests/lisp/dmc-parse.lisp` has 5 cases asserting the parsed AST matches expected
    - [ ] 7.2.7b. Method qualification matching: given a list of methods and a method-group-spec `(group-name pattern* options)`, correctly assign each method to a group OR signal `invalid-method-error`. 5 test cases including: simple qualifier match, predicate match, `*` wildcard, multi-qualifier match, no-match-error
    - [ ] 7.2.7c. Effective method body synthesis: substitute `call-method`/`make-method` bindings into the body and produce the effective method form. 4 test cases including a method combination that calls each group in non-default order
    - [ ] 7.2.7d. Full integration: `vendor/ansi-test/objects/define-method-combination*.lsp` ≥ 95% pass rate
  - [ ] 7.2.8. `call-next-method`, `next-method-p` — including `call-next-method` with new arguments
- [ ] 7.3. Class precedence
  - [ ] 7.3.1. Multiple inheritance
  - [ ] 7.3.2. C3 linearization for class precedence list. Inconsistent hierarchies (no valid linearization exists) MUST signal `error` at `defclass` time — silently producing a wrong order is the failure mode to prevent. Acceptance: 5 cases in `tests/lisp/c3-corpus.lisp` covering: diamond inheritance, multiple-inheritance ordering preservation, the canonical inconsistent hierarchy from the C3 paper (must error), depth-first-but-monotonic edge case, MRO across 5+ levels
  - [ ] 7.3.3. `class-precedence-list` reflection
- [ ] 7.4. Metaobject Protocol (AMOP subset)
  - [ ] 7.4.1. `class-of`, `find-class`, `(setf find-class)`
  - [ ] 7.4.2. `standard-class`, `standard-object`, `standard-generic-function`, `standard-method`
  - [ ] 7.4.3. `compute-applicable-methods`. Split:
    - [ ] 7.4.3a. Filter methods whose specializers match the call's argument classes (using class precedence list). 4 cases
    - [ ] 7.4.3b. Sort applicable methods by specificity per AMOP (left-to-right argument-position priority, then class precedence). 4 cases
    - [ ] 7.4.3c. `eql` specializers participate in matching and are most-specific. 3 cases
    - [ ] 7.4.3d. Verified with user-defined `:method-class` returning a custom subclass (proves the mechanism is overridable, not hard-coded). 1 case
  - [ ] 7.4.4. `compute-effective-method` — verified by a user-defined method combination producing correct effective methods for 3+ method definitions. The `:around` method MUST transform the inner result (e.g. wrap in `(list :around-result ...)`) — a no-op `:around` would pass a sloppy implementation, so the transformation is the assertion
  - [ ] 7.4.5. `slot-definition` introspection per AMOP. MUST expose: `slot-definition-name`, `slot-definition-type`, `slot-definition-allocation`, `slot-definition-initargs`, `slot-definition-initform`, `slot-definition-initfunction`, `slot-definition-readers`, `slot-definition-writers`. `class-slots` returns effective slot definitions; `class-direct-slots` returns direct (per-class) ones. Acceptance: 6 cases in `tests/lisp/slot-introspection.lisp` defining classes that exercise each accessor with non-default values; introspection results match the source declaration
  - [ ] 7.4.6. `validate-superclass` controls valid metaclass combinations. Default: `standard-class` permits only `standard-class`/`standard-object` superclasses. Acceptance: 3 cases in `tests/lisp/validate-superclass.lisp`: (a) defining a class with a metaclass-incompatible superclass signals `error` at `defclass` time, (b) a user metaclass with an explicit `validate-superclass` method allows the combination, (c) the error message names which superclass failed validation
  - [ ] 7.4.7. Phase 6's hand-rolled condition class system is **deleted** here; conditions are real CLOS instances. Acceptance: `grep -r "minimal-condition-class" src/` returns nothing; all `conditions/` ansi-test still passes
- [ ] 7.5. `print-object`, `describe-object`
  - [ ] 7.5.1. `print-object` as the universal printer hook. The Phase 1 printer is rewritten to dispatch through `print-object` for ALL recursive printing — top-level, nested in lists, nested in vectors, nested as slot values of other instances, inside `format` `~A`/`~S` directives. Acceptance: defining `(defmethod print-object ((x my-class) stream) (format stream "<MY ~A>" (slot-value x 'name)))` causes that method to fire in all 5 contexts; `tests/lisp/print-object-dispatch.lisp` asserts the literal output for each. NOT bail-able to "top-level dispatch only" — the recursive contexts are the test
  - [ ] 7.5.2. `describe`, `describe-object`

Exit criteria: can load a non-trivial CLOS-using library from Quicklisp (e.g. `alexandria`).

ansi-test slice: `objects.lsp`

---

Phase 8: LOOP and Heavy Iteration

`LOOP` is its own sub-language and gets its own phase.

- [ ] 8.1. Loop facility — done means: `vendor/ansi-test/iteration/loop*.lsp` pass rate ≥ 95% AND a 200-form corpus from "Practical Common Lisp" + CLHS section 6 expands identically to SBCL (`tests/lisp/loop-corpus.lisp`)
  - [ ] 8.1.1. `loop` macro — simple form (body repeated forever)
  - [ ] 8.1.2. Iteration clauses — one session each:
    - [ ] 8.1.2a. `for ... in` (list elements) and `for ... on` (cdr-walk)
    - [ ] 8.1.2b. `for ... = ... then ...` (assignment with optional step form)
    - [ ] 8.1.2c. `for ... from ... to ... by ...` (numeric, including `downto`, `below`, `above`)
    - [ ] 8.1.2d. `for ... across` (vector elements)
    - [ ] 8.1.2e. `for ... being the hash-keys/hash-values [using ...]`
    - [ ] 8.1.2f. `for ... being the symbols/external-symbols/present-symbols [of package]`
    - [ ] 8.1.2g. Multiple parallel `for` clauses (terminate when any source exhausts)
  - [ ] 8.1.3. Termination — one session each:
    - [ ] 8.1.3a. `while`, `until`
    - [ ] 8.1.3b. `repeat N`
    - [ ] 8.1.3c. `always`, `never`, `thereis` (boolean accumulators that double as terminators)
  - [ ] 8.1.4. Accumulation — one session each:
    - [ ] 8.1.4a. `collect`, `collecting` (and the `appending` family: `append`, `nconc`)
    - [ ] 8.1.4b. `count`, `counting`
    - [ ] 8.1.4c. `sum`, `summing`
    - [ ] 8.1.4d. `maximize`, `minimize` (require at least one value or return NIL — verify spec behavior)
  - [ ] 8.1.5. `into` accumulators with explicit interaction tests: `collect ... into x` + `count ... into y` + `finally (return (list x y))`
  - [ ] 8.1.6. `with` for local bindings (parallel and sequential)
  - [ ] 8.1.7. `initially`, `finally` (multiple of each, ordering matters)
  - [ ] 8.1.8. `if`/`when`/`unless`/`else`/`end` clauses — nested conditionals with `and`/`it` references
  - [ ] 8.1.9. `named` loops with `return-from`
  - [ ] 8.1.10. Type declarations: `for x fixnum ...` actually inform compilation (Phase 9)
- [ ] 8.2. Other iteration
  - [ ] 8.2.1. `do`, `do*` with multiple stepped variables, end-test, result form, body. `do` evaluates step forms in PARALLEL (all step forms reference the old values); `do*` evaluates SEQUENTIALLY (each step form sees prior steps' new values). Acceptance: 8 cases in `tests/lisp/do-corpus.lisp` distinguishing parallel-vs-sequential semantics — including `(do ((a 1) (b a)) ...)` failing in `do` (unbound `a` in `b`'s init context per spec) but working in `do*`
  - [ ] 8.2.2. `dolist`, `dotimes` — including optional result form, `return`/`return-from` to exit early, the variable being bound to NIL after normal completion (per spec). Acceptance: `vendor/ansi-test/iteration/do*.lsp` and `dolist*.lsp` pass rate ≥ 95%
  - [ ] 8.2.3. `dohash` helper (zisp extension, wraps `maphash` with the `dolist`-style binding form)
- [ ] 8.3. Loop testing
  - [ ] 8.3.1. Cross-test loop expansions against SBCL on a fixed corpus

ansi-test slice: `loop.lsp`, `iteration.lsp`

---

Phase 9: Compilation

Move beyond tree-walking. This is where Zig's strengths really show.

- [ ] 9.1. Bytecode VM (intermediate step)
  - [ ] 9.1.1. Instruction set design (`docs/bytecode.md`)
  - [ ] 9.1.2. Compiler from Lisp AST to bytecode — one session per form type:
    - [ ] 9.1.2a. Self-evaluating forms (constants pushed via `LOAD_CONST`)
    - [ ] 9.1.2b. Variable references (`LOAD_LOCAL` for lexical, `LOAD_GLOBAL` for special)
    - [ ] 9.1.2c. Function calls (`CALL` with arity)
    - [ ] 9.1.2d. `if`, `progn`
    - [ ] 9.1.2e. `setq` (`STORE_LOCAL`/`STORE_GLOBAL`)
    - [ ] 9.1.2f. `let`, `let*` (frame allocation + binding emit)
    - [ ] 9.1.2g. `lambda` (emit child function, `MAKE_CLOSURE` op capturing locals)
    - [ ] 9.1.2h. `block`/`return-from` (emit catch-tag and matching unwind)
    - [ ] 9.1.2i. `tagbody`/`go` (emit jump targets and indirect jump table)
    - [ ] 9.1.2j. `catch`/`throw` (dynamic catch frames)
    - [ ] 9.1.2k. `unwind-protect` (cleanup-frame emit)
    - [ ] 9.1.2l. Multiple values (`VALUES`/`MV_BIND` ops)
  - [ ] 9.1.3. Stack-based VM in Zig — one session per concern:
    - [ ] 9.1.3a. Operand stack as growable array of `Value`; basic push/pop ops work
    - [ ] 9.1.3b. Frame stack: each call frame holds locals + return PC + parent frame
    - [ ] 9.1.3c. Main dispatch loop with all ops from 9.1.2 implemented
    - [ ] 9.1.3d. Exception unwinding integrated with `throw`/`return-from`/`go`
    - [ ] 9.1.3e. Interpreter benchmark vs. Phase 2 tree-walker: ≥ 3× faster on `(loop for i from 0 to 1000000 sum i)`
  - [ ] 9.1.4. Constant pool PER COMPILED FUNCTION (not shared across functions or across files — enables function-level unloading). Constants deduplicated WITHIN a function (`'(1 2 3)` appearing twice in one function references one pool entry); NOT deduplicated across functions. Acceptance: `(disassemble #'fn)` output includes a `Constants:` section listing pool entries; `tests/lisp/const-pool.lisp` defines two functions both using `'(1 2 3)`, verifies via the `disassemble` output that each function carries its own pool entry (not a shared reference) — comparing object identity of the listed constants
  - [ ] 9.1.5. Closure representation in bytecode. Closed-over bindings are MUTABLE (`(setq x ...)` inside a closure modifies the captured cell, visible to other closures over the same binding). Captured bindings outlive their lexical scope (heap-allocated when captured). Acceptance: `(let ((x 0)) (defun get-x () x) (defun inc-x () (incf x)))` then `(inc-x) (inc-x) (get-x)` returns `2`; same test re-run after `compile-file` still returns `2`; nested closures sharing a binding all see updates
  - [ ] 9.1.6. Inline caches for global function lookup with three states: monomorphic (single target), polymorphic (up to 4 targets), megamorphic (fall back to global hash table). Cache invalidated on `(setf (symbol-function ...))` and on `fmakunbound`. Acceptance: (a) monomorphic counter — 1M-call hot loop with one target shows ≥99% mono-hit rate; (b) polymorphic counter — `tests/lisp/inline-cache.lisp` exercises a 3-target call site, the polymorphic-dispatch counter increments exactly N times for an N-iteration loop (proves each call took the polymorphic path, not megamorphic fallback); (c) megamorphic transition — a 5-target call site causes the cache to transition into megamorphic state on the 5th distinct target (verified by state-transition counter); (d) `(redefine-fn-then-call)` invalidates correctly. NOT bail-able to "monomorphic only" — the polymorphic AND megamorphic counters are explicit gates
  - [ ] 9.1.7. Dispatch loop. First implement plain `switch`. Then: benchmark switch vs. inline-threaded vs. tail-call-threaded on `cl-bench` interpreter loops. Acceptance: chosen technique documented in `docs/bytecode.md` with measured numbers; if switch wins under `ReleaseFast`, this bullet's "computed-goto" framing is removed (don't pretend Zig has GCC-style labels-as-values when it doesn't)
- [ ] 9.2. Native codegen
  - [ ] 9.2.1. Backend decision: `docs/codegen-backend.md` written BEFORE any code. Doc compares LLVM-via-`zig cc` / Cranelift / hand-rolled on five axes (implementation effort, output quality on cl-bench arithmetic, dependency cost, debug-info support, build-time impact). Recommendation made with explicit tradeoffs. User signs off (initial-here checkbox in the doc). NOT bail-able: "let the user decide" without first producing the comparison is the historic stall here
  - [ ] 9.2.2. IR design — SSA over Lisp values, documented in `docs/codegen-ir.md`. Doc MUST cover: every IR op listed with operand/result types; value representation (boxed vs unboxed, when types are tracked); control-flow representation (basic blocks, phi nodes); the IR-to-bytecode lowering pass with one section per IR op showing target bytecode; one example function compiled end-to-end from Lisp source through IR through bytecode through native code. NOT bail-able to "high-level overview"
  - [ ] 9.2.3. Type inference. Acceptance: 6 cases in `tests/lisp/type-inference.lisp` showing unboxed code in `disassemble` for: (a) `(the fixnum (+ x 1))`, (b) `(declare (type single-float x))` then float math, (c) `(let ((y (+ x 1))) ...)` inferring `y`'s type from `x`, (d) `if`-typing — a variable's type narrows in the then/else branches based on a `typep` test, (e) inference through one function call (callee return type informs caller), (f) negative test — a value with no type info uses boxed dispatch (regression guard so I can't accidentally claim "always unboxed")
  - [ ] 9.2.4. Unboxing of fixnums and floats in hot loops. Acceptance: 4 benchmarks in `tests/lisp/unboxing-bench.lisp` each ≥ 10× faster than Phase 8 tree-walker: (a) fixnum sum loop `(loop for i fixnum from 0 to 1000000 sum i)`, (b) float dot-product over a 1M-element array, (c) integer factorial via `do`, (d) Mandelbrot pixel-test inner loop. NOT bail-able to "pattern-matched the one example" — the four benchmarks span different control structures
  - [ ] 9.2.5. Inlining of small functions. `(declare (inline foo))` inlines at every call site in scope; `(declaim (inline foo))` inlines globally. Acceptance: 5 cases in `tests/lisp/inline.lisp`: (a) basic — no `call` instruction in `disassemble`, (b) transitive — inline function calls another inline function, both inline, (c) cross-compilation-unit — inline `declaim` in fileA, call in fileB compiled separately, both inlined, (d) recursive inline limited to 3 levels then bottoms out to a real call (no infinite expansion), (e) `(declare (notinline foo))` overrides global `(declaim (inline foo))`
  - [ ] 9.2.6. Tail-call optimization. Split into 4 milestones:
    - [ ] 9.2.6a. Direct self-call TCO. `(defun loop-forever () (loop-forever))` runs 60 seconds without stack growth (RSS / stack pointer monitored, no growth beyond startup baseline)
    - [ ] 9.2.6b. Mutual recursion TCO. `even-p`/`odd-p` on `(expt 10 7)` (10M-deep alternating call chain) completes without stack overflow
    - [ ] 9.2.6c. TCO through control forms — each of `if`/`progn`/`let`/`cond`/`when`/`unless`/`block` (when the call is in tail position) has a self-recursive test running 60 seconds with no stack growth
    - [ ] 9.2.6d. Frame-counting instrumentation: `*tco-frame-counter*` counts active Zig frames during execution; `tests/lisp/tco-frame-count.lisp` runs a tail-recursive 1M-iteration call, asserts counter remains constant (proves no stack growth, not just "didn't crash")
- [ ] 9.3. `compile`, `compile-file`, FASLs
  - [ ] 9.3.1. `(compile name function-form)` produces a compiled function — `(compiled-function-p result)` returns `t` (distinguishable from interpreted). Compiled function executes ≥2× faster than interpreted on a 1M-iteration tight loop (bytecode VM minimum; native if 9.2 done). NOT bail-able to "calls `eval` and returns the result"
  - [ ] 9.3.2. `compile-file` for batch compilation to FASL
  - [ ] 9.3.3. FASL format documented in `docs/fasl-format.md` BEFORE implementation: magic bytes, version word, host endianness handling (FASL files declare endianness; loader byte-swaps if mismatched), mmap-friendly layout (no fixups required for code/data alignment), forward-compatibility plan. Acceptance: a FASL produced on `x86_64-linux` loads correctly on `aarch64-darwin` and vice versa (CI runs cross-arch FASL test). Loading a future-version FASL on an older zisp signals `fasl-version-error` cleanly. Windows targets out of scope
  - [ ] 9.3.4. `load` handles both source and FASL
  - [ ] 9.3.5. Recompilation on source-newer-than-FASL
- [ ] 9.4. Optimization declarations
  - [ ] 9.4.1. `(declare (optimize (speed N) (safety N) (debug N) (space N)))` with specific behaviors per level documented in `docs/optimize-levels.md`. At minimum: `(safety 0)` elides argument-count and type checks; `(safety 3)` runs all type assertions; `(speed 3)` enables aggressive inlining; `(debug 3)` preserves source positions and local-variable names through compilation. Acceptance: 12 cases in `tests/lisp/optimize-levels.lisp` spanning all four quality dimensions (≥3 cases per dimension), each asserting generated code differs measurably — `(safety 0)` strictly smaller than `(safety 3)` (byte-count via `disassemble`); `(speed 3)` ≥2× faster than `(speed 0)` on the bench loop (timing); `(debug 3)` preserves names visible in `disassemble`; `(space 3)` smaller code than `(space 0)`. NOT bail-able to "parsed and ignored" or to "speed-only optimization"
  - [ ] 9.4.2. `(declare (type ...))` actually informs codegen (verified via `disassemble`: a function with `(declare (type fixnum x))` and `(+ x 1)` generates an unboxed integer add, not a generic dispatch)
  - [ ] 9.4.3. `(declare (inline foo))`, `(declare (notinline foo))` — inline declaration causes the named function to inline at every call site in the declaration's scope (verified via `disassemble`)
  - [ ] 9.4.4. `disassemble` output: one line per bytecode op (or native instruction post-9.2) with offset, opcode, operands, and source line where derivable from `(debug N)`. Acceptance: `(disassemble #'my-fn)` for a 10-line function produces output diffed against a golden file in `tests/disassemble-golden/`
- [ ] 9.5. Image dump and load. Split into 5 milestones:
  - [ ] 9.5.1. Format design: `docs/image-format.md` written BEFORE implementation. Covers magic, version, endianness, mmap layout, code-pointer fixup table, forward-compat plan
  - [ ] 9.5.2. Heap walker reuses the GC marker to enumerate every reachable object. `tests/lisp/image-walk.lisp` allocates a known graph of 100 objects, walker visits exactly those (no over-count, no skips)
  - [ ] 9.5.3. Per-type serializers — one for each heap object type (cons, symbol, string, vector, hash-table, function, package, etc.). Round-trip test per type: serialize then deserialize, asserted `equal`. 8+ types covered
  - [ ] 9.5.4. Pointer fixup on load: image stores object IDs; loader allocates fresh objects, builds an ID→pointer table, fixes up all references in a second pass. `tests/lisp/image-roundtrip.lisp` saves a graph with shared substructure and cycles, loads, asserts `eq` identity preserved where original had `eq` identity
  - [ ] 9.5.5. Cold-start gate: `(save-image "demo.zimg")` followed by `zisp --image demo.zimg --eval '(my-fn)'` runs in ≤ 50ms cold-start on CI Linux runner. Image is byte-reproducible from the same source. NOT bail-able to "source-only loading" — the cold-start number is the gate

Exit criteria: `cl-bench` numbers within an order of magnitude of SBCL on arithmetic and list benchmarks; cold start under 50ms for a saved image.

---

Phase 10: The "Zisp" Differentiators

Things no other CL implementation can easily do, because they don't have Zig underneath.

- [ ] 10.1. `comptime` Lisp
  - [ ] 10.1.0. **Prerequisite**: `docs/comptime-lisp.md` written defining: (a) the surface API (specific function/macro signatures), (b) one concrete worked example end-to-end (Lisp source → macroexpansion → Zig comptime → emitted code), (c) explicit out-of-scope list, (d) the bridge mechanism between Lisp macroexpansion and Zig comptime evaluation — specific protocol, not "they communicate somehow." No implementation work begins until this doc exists and is reviewed
  - [ ] 10.1.1. Macros that can call into Zig `comptime` for cross-language code generation
  - [ ] 10.1.2. Generate Zig `extern struct` definitions from Lisp `defstruct`. Acceptance: a Lisp `(defstruct point x y)` produces a `.zig` file containing the equivalent `extern struct`, compilable by `zig build-obj`
  - [ ] 10.1.3. Type-check Lisp at the macro layer using Zig's type system as the source of truth
- [ ] 10.2. Embedded / no-std
  - [ ] 10.2.1. `-Dfreestanding=true` build links against a custom minimal-std (only `std.mem`, `std.math`, `std.meta` permitted). Acceptance: `zig build -Dfreestanding=true` succeeds AND `grep -rE "std\.(io|fs|os|process|time|http|net)" src/runtime/ src/eval/ src/reader/` returns no matches. CI runs the freestanding build on every commit so backsliding is immediate
  - [ ] 10.2.2. `freestanding` build target
  - [ ] 10.2.3. Minimal allocator interface (so user supplies their own on a microcontroller)
  - [ ] 10.2.4. Strip out the file/stream/pathname code paths in `freestanding` builds
  - [ ] 10.2.5. Specific board chosen and committed: Raspberry Pi Pico (RP2040, Cortex-M0+). Acceptance: zisp cross-compiles for `thumbv6m-freestanding`, image fits in 64KB, blinks the on-board LED via a `gpio` builtin. Demo committed to `examples/blink-pico/` with build instructions
  - [ ] 10.2.6. ESP32 follow-up — same shape as 10.2.5
- [ ] 10.3. WASM
  - [ ] 10.3.1. `wasm32-freestanding` build
  - [ ] 10.3.2. `wasm32-wasi` build with full file/stream support
  - [ ] 10.3.3. Browser demo: REPL in a `<textarea>`
  - [ ] 10.3.4. JS interop. **Prerequisite**: `docs/wasm-interop.md` written. Minimum demo: a 20-line Lisp program calls `console.log("hello")` and receives back a result from `Date.now()`. Acceptance: that demo runs in Chrome and Firefox; commit to `examples/wasm-repl/`
- [ ] 10.4. C interoperability
  - [ ] 10.4.1. FFI declarations (`defcfun`-style). Split:
    - [ ] 10.4.1a. C-type representation in Lisp: `:int`, `:long`, `:pointer`, `:char`, `:float`, `:double`, plus type aliases (`size_t`, `off_t`)
    - [ ] 10.4.1b. `defcfun` macro syntax: `(defcfun "strlen" :int (s :pointer))` parses and registers
    - [ ] 10.4.1c. Argument marshalling (Lisp value → C ABI representation per type)
    - [ ] 10.4.1d. Return-value unmarshalling (C return → Lisp value per type)
    - [ ] 10.4.1e. Library lookup: `defcfun` resolves the symbol via `dlopen`/`dlsym` (or platform equivalent)
    - [ ] 10.4.1f. Integration test: call `strlen` on a Lisp string, get back correct length on Linux and macOS
  - [ ] 10.4.2. Direct C-ABI struct generation from Lisp `defstruct`
  - [ ] 10.4.3. Callbacks (Lisp function → C function pointer). Implementation choice (libffi vs hand-rolled per-arch trampolines) documented in `docs/ffi-callbacks.md` BEFORE implementation. Acceptance: a Lisp function passed as comparator to `qsort(3)` correctly sorts a 100-element array on `x86_64-linux` and `aarch64-darwin` (CI runs both). Variadic callbacks are explicitly out of scope — but documenting that they're out of scope is a sub-bullet, not silence
  - [ ] 10.4.4. `with-foreign-object`, `foreign-alloc`, `foreign-free`
- [ ] 10.5. Allocator extensibility
  - [ ] 10.5.1. Expose Zig's allocator interface at the Lisp level
  - [ ] 10.5.2. `with-allocator` macro to scope allocations to an arena
  - [ ] 10.5.3. Per-thread allocators

---

Compliance Tracking

The ansi-test suite is roughly 720 `.lsp` files across 22 category directories. Per-phase targets, grounded in which categories are expected to pass:

| Milestone      | Categories landed (cumulative)                                                                                              | Files in scope | Target file pass rate |
| -------------- | --------------------------------------------------------------------------------------------------------------------------- | -------------: | --------------------: |
| End of Phase 1 | `reader/` parses (no eval)                                                                                                  |             17 |                   ~3% |
| End of Phase 2 | + `cons/`, `eval-and-compile/`, `data-and-control-flow/` (subset)                                                           |           ~190 |                  ~15% |
| End of Phase 3 | + macros, `setf`, `printer/`, full `symbols/`                                                                               |           ~250 |                  ~30% |
| End of Phase 4 | + strings, arrays, sequences, hash-tables, numbers, characters, packages, pathnames, streams, structures, types-and-classes |           ~600 |                  ~75% |
| End of Phase 5 | (no new categories — but suite now runs without OOM)                                                                        |           ~600 |                  ~80% |
| End of Phase 6 | + `conditions/`                                                                                                             |           ~625 |                  ~85% |
| End of Phase 7 | + `objects/`                                                                                                                |           ~680 |                  ~92% |
| End of Phase 8 | + `iteration/`                                                                                                              |           ~700 |                  ~95% |
| End of Phase 9 | (compilation — no new categories, optimization-related fixes)                                                               |           ~720 |                  ~97% |
| Stretch        | edge cases, deep MOP, format directives                                                                                     |           ~720 |                  100% |

File-pass-rate is a coarse proxy — each file contains many `(deftest)` calls, and partial failures inside a file count as failures. Real test-count percentages will track somewhat lower than file percentages. 90–95% test-count compliance is what most implementation authors consider success.

---

Threading and Other Deferrals

Threading is out of scope until Phase 9 at minimum. When it arrives: bordeaux-threads-compatible API, per-thread nurseries, GC stop-the-world coordination. Foreign-thread callbacks and lock-free hash tables follow.

Benchmarks (`cl-bench`) wire in once Phase 5 lands and track regressions per commit. Memory-safety audit of unsafe casts inside the GC happens at the Phase 5 / Phase 9 boundaries (the two places it matters most).

---

Non-Goals

- Not a Lisp dialect. Breaking the ANSI standard for ergonomic reasons is out of scope. Extensions go in a separate package.
- Not a Scheme. Lisp-1, hygienic macros, and continuations are not on this roadmap.
- Not self-hosted (yet). The implementation stays in Zig. A self-hosted compiler is a possible future, not a goal.
- Not a research vehicle. Novel GC algorithms or type systems aren't the point — proven techniques applied carefully are.
- Not Windows. Linux and macOS only. Code may happen to work on Windows, but it's not tested, supported, or accepted as a constraint on design decisions.
