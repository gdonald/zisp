;; with-condition-restarts: three restarts are associated with condition
;; A, an outer one with no condition, and compute-restarts filters by the
;; condition it is asked about.

(progn
  (define-condition association-a (error) ())
  (define-condition association-b (error) ())
  (defvar *condition-a* (make-condition 'association-a))
  (defvar *condition-b* (make-condition 'association-b))
  ;; Calls FN inside one unassociated restart, `outside`, and three
  ;; restarts associated with *condition-a*, `one`, `two` and `three`.
  (defun with-associated-restarts (fn)
    (restart-case
        (restart-case
            (with-condition-restarts *condition-a* (subseq (compute-restarts) 0 3)
              (funcall fn))
          (one () nil)
          (two () nil)
          (three () nil))
      (outside () nil)))
  (defun names (restarts) (mapcar #'restart-name restarts))
  t)

;; For A, compute-restarts returns the associated subset and the
;; unassociated restarts.
(equal (with-associated-restarts
           (lambda () (names (compute-restarts *condition-a*))))
       '(one two three outside))

;; For B, compute-restarts returns only the unassociated restarts.
(equal (with-associated-restarts
           (lambda () (names (compute-restarts *condition-b*))))
       '(outside))

;; Without a condition, compute-restarts returns every restart.
(equal (with-associated-restarts
           (lambda () (names (compute-restarts))))
       '(one two three outside))

;; A handler for a signaled A finds an associated restart through A
;; but not through B.
(equal (with-associated-restarts
           (lambda ()
             (block found
               (handler-bind ((association-a
                                (lambda (condition)
                                  (return-from found
                                    (list (restart-name (find-restart 'one condition))
                                          (find-restart 'one *condition-b*))))))
                 (signal *condition-a*)))))
       '(one nil))

;; A restart established outside with-condition-restarts is visible to
;; every condition.
(equal (with-associated-restarts
           (lambda ()
             (list (restart-name (find-restart 'outside *condition-a*))
                   (restart-name (find-restart 'outside *condition-b*)))))
       '(outside outside))
