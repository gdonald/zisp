;; eval-when state table: 3 situations x 7 positions, one marker per cell.
;; The harness compiles this file, then loads the result, capturing output
;; from both phases. tests/lisp/eval-when-corpus.expected holds the exact
;; output SBCL 2.x produces for compile-file followed by load of the fasl.
;;
;; Positions:
;;   p1  top level
;;   p2  inside a top-level progn
;;   p3  inside a progn nested in a top-level progn
;;   p4  inside a top-level (eval-when (:compile-toplevel :execute) ...)
;;   p5  inside a top-level (eval-when (:load-toplevel :execute) ...)
;;   p6  inside a top-level (eval-when (:compile-toplevel :load-toplevel :execute) ...)
;;   p7  inside a let (not top level)

;; p1: top level
(eval-when (:compile-toplevel) (format t "p1-ct~%"))
(eval-when (:load-toplevel) (format t "p1-lt~%"))
(eval-when (:execute) (format t "p1-e~%"))

;; p2: top-level progn stays top level
(progn
  (eval-when (:compile-toplevel) (format t "p2-ct~%"))
  (eval-when (:load-toplevel) (format t "p2-lt~%"))
  (eval-when (:execute) (format t "p2-e~%")))

;; p3: nested progn stays top level
(progn
  (progn
    (eval-when (:compile-toplevel) (format t "p3-ct~%"))
    (eval-when (:load-toplevel) (format t "p3-lt~%"))
    (eval-when (:execute) (format t "p3-e~%"))))

;; p4: the enclosing eval-when evaluates its body at compile time, so the
;; inner forms see runtime eval-when semantics
(eval-when (:compile-toplevel :execute)
  (eval-when (:compile-toplevel) (format t "p4-ct~%"))
  (eval-when (:load-toplevel) (format t "p4-lt~%"))
  (eval-when (:execute) (format t "p4-e~%")))

;; p5: body processed as top level in not-compile-time mode
(eval-when (:load-toplevel :execute)
  (eval-when (:compile-toplevel) (format t "p5-ct~%"))
  (eval-when (:load-toplevel) (format t "p5-lt~%"))
  (eval-when (:execute) (format t "p5-e~%")))

;; p6: body processed as top level in compile-time-too mode
(eval-when (:compile-toplevel :load-toplevel :execute)
  (eval-when (:compile-toplevel) (format t "p6-ct~%"))
  (eval-when (:load-toplevel) (format t "p6-lt~%"))
  (eval-when (:execute) (format t "p6-e~%")))

;; p7: not top level; only :execute applies, at run time
(let ()
  (eval-when (:compile-toplevel) (format t "p7-ct~%"))
  (eval-when (:load-toplevel) (format t "p7-lt~%"))
  (eval-when (:execute) (format t "p7-e~%")))
