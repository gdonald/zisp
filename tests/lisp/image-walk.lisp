;; Every form here must evaluate to T.
;;
;; `ext:%walk-heap` visits each object reachable from its root exactly
;; once, with a cycle and shared structure among them. Symbols are
;; counted apart, and what is reachable only through a symbol is not
;; walked.

(progn
(defun image-walk-graph ()
  "A root reaching exactly 100 objects, each made fresh here."
  (let* ((shared (list 1 2))                                         ; 2 conses
         (strings (loop repeat 10 collect (make-string 3 :initial-element #\a))) ; 10 strings, 10 conses
         (vector (make-array 5 :initial-element shared))             ; 1 vector, sharing SHARED
         (table (let ((h (make-hash-table)))                         ; 1 table
                  (dotimes (i 3) (setf (gethash i h) (cons i i)))    ; 3 conses
                  h))
         (bignums (list (expt 2 100) (expt 3 90) (expt 5 70)))       ; 3 bignums, 3 conses
         (doubles (list (float 1 1d0) (float 2 1d0)))                ; 2 floats, 2 conses
         (cycle (let ((c (list 1 2 3))) (setf (cdr (last c)) c) c))  ; 3 conses
         (padding (make-list 52 :initial-element 0)))                ; 52 conses
    ;; The root itself is 8 conses.
    (list shared strings vector table bignums doubles cycle padding)))
t)

(multiple-value-bind (objects symbols) (ext:%walk-heap (image-walk-graph))
  (and (eql objects 100) (eql symbols 1)))

(multiple-value-bind (objects symbols) (ext:%walk-heap (let ((x (list 1))) (list x x x)))
  (and (eql objects 4) (eql symbols 1)))

(multiple-value-bind (objects symbols) (ext:%walk-heap 42)
  (and (eql objects 0) (eql symbols 0)))
