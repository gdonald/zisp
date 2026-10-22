;; `break` enters the debugger with a continue restart that returns nil
;; from the call, and handlers do not see its condition.
(let ((x 0)) (break "test") x)
:r continue
(handler-bind ((condition (lambda (c) (declare (ignore c)) (format t "handler ran~%"))))
  (break "Pausing at ~a." :checkpoint)
  :after-break)
0
