;; The ansi-test `typep` files. `tests/lisp/ansi-rt.lisp` has to be
;; loaded first, which is what `tests/run-rt-tests.sh typep` does.

(in-package :cl-test)

(run-ansi-files
 "typep"
 '("types-and-classes/typep.lsp"))
