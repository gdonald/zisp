;; Compiled on its own by `tests/lisp/inline.lisp`: a function proclaimed
;; inline, which `uses.lisp`, compiled separately, expands.
(declaim (inline inline-file-triple))
(defun inline-file-triple (x) (+ x (+ x x)))
