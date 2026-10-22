;; The banner for three conditions: a simple error with format arguments,
;; a continuable error, and an unbound variable with its two restarts.
;; Each session leaves through its abort restart.
(error "Disk ~a is full." "sda1")
0
(cerror "Retry the copy." "Copy of ~a failed." "report.txt")
1
(+ missing-total 1)
2
