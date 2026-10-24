;; The ansi-test `do`, `do*`, `dolist` and `dotimes` files.
;; `tests/lisp/ansi-rt.lisp` has to be loaded first, which is what
;; `tests/run-rt-tests.sh do` does.

(in-package :cl-test)

(run-ansi-files
 "do"
 '("iteration/do.lsp"
   "iteration/dostar.lsp"
   "iteration/dolist.lsp"
   "iteration/dotimes.lsp"))
