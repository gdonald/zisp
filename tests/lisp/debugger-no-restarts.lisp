;; With no restarts, the debugger only evaluates forms, refuses a restart
;; number, and is left by the end of the input.
(let ((cl::*restart-clusters* nil)) (error "Nothing to restart."))
(+ 1 2)
0
