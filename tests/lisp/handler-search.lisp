;; How a signal finds its handler: which one runs, in what order, what a
;; handler that declines leaves behind, and what a handler that signals
;; something else can reach.

(progn
  (define-condition search-parent (error) ())
  (define-condition search-child (search-parent) ())
  (define-condition search-other (error) ())
  (define-condition search-notice (condition) ())
  (defvar *trace* nil)
  (defun note (tag) (setq *trace* (cons tag *trace*)) nil)
  ;; The absorbing handler is outermost, so every cluster the body sets
  ;; up is offered the condition before this one unwinds.
  (defun tracing (thunk)
    (setq *trace* nil)
    (handler-case (funcall thunk) (error (c) (declare (ignore c)) nil))
    (reverse *trace*))
  t)

;; A nested `handler-bind` offers the condition to the innermost cluster
;; first, and a handler that returns lets the search carry on outward.
(equal (tracing
        (lambda ()
          (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :outer))))
            (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :inner))))
              (error 'search-child)))))
       '(:inner :outer))

;; Only the clusters whose type matches are offered the condition.
(equal (tracing
        (lambda ()
          (handler-bind ((search-other (lambda (c) (declare (ignore c)) (note :other))))
            (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :parent))))
              (error 'search-child)))))
       '(:parent))

;; One cluster may bind several types, and each matching entry runs in
;; the order the cluster lists them.
(equal (tracing
        (lambda ()
          (handler-bind ((search-child (lambda (c) (declare (ignore c)) (note :child)))
                         (search-parent (lambda (c) (declare (ignore c)) (note :parent))))
            (error 'search-child))))
       '(:child :parent))

;; A handler that leaves through a non-local exit stops the search.
(equal (tracing
        (lambda ()
          (block done
            (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :outer))))
              (handler-bind ((search-parent (lambda (c)
                                              (declare (ignore c))
                                              (note :inner)
                                              (return-from done nil))))
                (error 'search-child))))))
       '(:inner))

;; A `handler-case` inside a `handler-bind` is the more recent handler,
;; so it takes the condition and unwinds before the outer one is offered
;; it at all.
(equal (tracing
        (lambda ()
          (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :bind))))
            (handler-case (error 'search-child)
              (search-parent (c) (declare (ignore c)) (note :case))))))
       '(:case))

;; A `handler-bind` inside a `handler-case` sees the condition first.
(equal (tracing
        (lambda ()
          (handler-case
              (handler-bind ((search-parent (lambda (c) (declare (ignore c)) (note :bind))))
                (error 'search-child))
            (search-parent (c) (declare (ignore c)) (note :case)))))
       '(:bind :case))

;; A handler that signals something else searches from where it was
;; bound, so the cluster it belongs to cannot answer its own signal.
(equal (tracing
        (lambda ()
          (handler-bind ((search-other (lambda (c) (declare (ignore c)) (note :outer-other))))
            (handler-bind ((search-parent (lambda (c)
                                            (declare (ignore c))
                                            (note :parent)
                                            (signal 'search-other)))
                           (search-other (lambda (c) (declare (ignore c)) (note :same-cluster))))
              (error 'search-child)))))
       '(:parent :outer-other))

;; The innermost `handler-case` whose clause matches is the one that runs.
(eq (handler-case
        (handler-case (error 'search-child)
          (search-other (c) (declare (ignore c)) :wrong))
      (search-parent (c) (declare (ignore c)) :outer))
    :outer)

;; A clause matches on the condition's type, not on the order the clauses
;; were written.
(eq (handler-case (error 'search-child)
      (search-other (c) (declare (ignore c)) :other)
      (search-child (c) (declare (ignore c)) :child))
    :child)

;; A failure a native raised reaches the clauses as the condition type it
;; stands for.
(eq (handler-case (car 1) (type-error (c) (declare (ignore c)) :type-error))
    :type-error)

;; `signal` returns nil where nothing handles it, and the body carries
;; on from where it signaled.
(equal (tracing (lambda () (signal 'search-notice) (note :after))) '(:after))
