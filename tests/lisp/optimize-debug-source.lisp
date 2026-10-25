;; Loaded by `tests/lisp/optimize-levels.lisp`, which reads back the
;; lines the calls below were written on.
(defun optimize-debug-positions (x)
  (declare (optimize (debug 3)))
  (print x)
  (prin1 x)
  x)
