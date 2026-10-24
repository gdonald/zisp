;; The ansi-test `loop` files. `tests/lisp/ansi-rt.lisp` has to be
;; loaded first, which is what `tests/run-rt-tests.sh loop` does.

(in-package :cl-test)

(run-ansi-files
 "loop"
 '(
   "iteration/loop.lsp"
   "iteration/loop1.lsp"
   "iteration/loop2.lsp"
   "iteration/loop3.lsp"
   "iteration/loop4.lsp"
   "iteration/loop5.lsp"
   "iteration/loop6.lsp"
   "iteration/loop7.lsp"
   "iteration/loop8.lsp"
   "iteration/loop9.lsp"
   "iteration/loop10.lsp"
   "iteration/loop11.lsp"
   "iteration/loop12.lsp"
   "iteration/loop13.lsp"
   "iteration/loop14.lsp"
   "iteration/loop15.lsp"
   "iteration/loop16.lsp"
   "iteration/loop17.lsp"))
