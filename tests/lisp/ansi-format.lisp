;; The ansi-test format suite. `tests/lisp/ansi-rt.lisp` has to be loaded
;; first, which is what `tests/run-rt-tests.sh format` does.

(in-package :cl-test)

(run-ansi-files
 "format"
 (mapcar (lambda (name) (concatenate 'string "printer/format/" name ".lsp"))
         '("format-c" "formatter-c" "format-percent" "format-ampersand"
           "format-page" "format-tilde" "format-r" "format-d" "format-b"
           "format-o" "format-x" "format-f" "format-e" "format-a" "format-s"
           "format-underscore" "format-logical-block" "format-i" "format-slash"
           "format-t" "format-justify" "format-goto" "format-conditional"
           "format-brace" "format-question" "format-paren" "format-p"
           "format-circumflex" "format-newline")))
