;; The ansi-test restart files. `tests/lisp/ansi-rt.lisp` has to be
;; loaded first, which is what `tests/run-rt-tests.sh restarts` does.

(in-package :cl-test)

(run-ansi-files
 "restarts"
 '("conditions/restart-bind.lsp"
   "conditions/restart-case.lsp"
   "conditions/compute-restarts.lsp"
   "conditions/with-condition-restarts.lsp"
   "conditions/with-simple-restart.lsp"
   "conditions/abort.lsp"
   "conditions/continue.lsp"
   "conditions/muffle-warning.lsp"
   "conditions/store-value.lsp"
   "conditions/use-value.lsp"))
