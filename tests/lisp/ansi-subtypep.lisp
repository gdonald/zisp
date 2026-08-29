;; The ansi-test `subtypep` files. `tests/lisp/ansi-rt.lisp` has to be
;; loaded first, which is what `tests/run-rt-tests.sh subtypep` does.

(in-package :cl-test)

(run-ansi-files
 "subtypep"
 '("types-and-classes/subtypep.lsp"
   "types-and-classes/subtypep-array.lsp"
   "types-and-classes/subtypep-complex.lsp"
   "types-and-classes/subtypep-cons.lsp"
   "types-and-classes/subtypep-eql.lsp"
   "types-and-classes/subtypep-float.lsp"
   "types-and-classes/subtypep-function.lsp"
   "types-and-classes/subtypep-integer.lsp"
   "types-and-classes/subtypep-member.lsp"
   "types-and-classes/subtypep-rational.lsp"
   "types-and-classes/subtypep-real.lsp"))
