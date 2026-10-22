;; A failure in a form typed at the debugger opens a debugger one level
;; in. Its abort restart comes back to the outer debugger, which still
;; evaluates in the outer error's environment.
(let ((limit 10)) (error "Limit ~d reached." limit))
(car limit)
0
(+ limit 1)
0
