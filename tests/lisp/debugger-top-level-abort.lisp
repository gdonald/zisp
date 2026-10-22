;; Selecting the top-level abort restart from a debugger returns to the
;; REPL, which goes on with the next form.
(defun checked-divide (a b) (if (zerop b) (error "Division of ~d by zero." a) (/ a b)))
(checked-divide 9 0)
0
(checked-divide 9 3)
