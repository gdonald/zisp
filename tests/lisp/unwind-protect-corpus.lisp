;; `unwind-protect` on every way out of its protected form. Each case
;; records the cleanups it runs, in order, and checks that record and the
;; value the case ends with. Every form evaluates to T in SBCL too.

(progn
  (defvar *log* nil)
  (defun note (entry) (push entry *log*) entry)
  (defun log-of (thunk)
    "What THUNK returns, then the entries it noted in the order noted."
    (setq *log* nil)
    (let ((result (multiple-value-list (funcall thunk))))
      (list result (reverse *log*))))
  t)

;; --- normal exit and a signaled error ---

;; The protected form's value comes back after the cleanup runs.
(equal (log-of (lambda () (unwind-protect (note :body) (note :cleanup))))
       '((:body) (:body :cleanup)))

;; Every value of the protected form comes back, not the cleanup's.
(equal (log-of (lambda () (unwind-protect (values 1 2 3) (note :cleanup) (values 4 5))))
       '((1 2 3) (:cleanup)))

;; An error the protected form signals runs the cleanup on the way to
;; the handler-case, ahead of the clause body.
(equal (log-of (lambda ()
                 (handler-case (unwind-protect (progn (note :body) (error "Lost the lease."))
                                 (note :cleanup))
                   (error () (note :handler) :recovered))))
       '((:recovered) (:body :cleanup :handler)))

;; A failure a native raised runs the cleanup on the way to ignore-errors.
(equal (log-of (lambda ()
                 (ignore-errors (unwind-protect (car (note 5)) (note :cleanup)))
                 :done))
       '((:done) (5 :cleanup)))

;; --- throw, return-from and go ---

(progn
  (defun level-3 () (unwind-protect (throw :escape :thrown) (note :cleanup-3)))
  (defun level-2 () (unwind-protect (level-3) (note :cleanup-2)))
  (defun level-1 () (unwind-protect (level-2) (note :cleanup-1)))
  t)

;; A throw past three frames runs each frame's cleanup, innermost first.
(equal (log-of (lambda () (catch :escape (level-1))))
       '((:thrown) (:cleanup-3 :cleanup-2 :cleanup-1)))

;; A return-from past nested unwind-protects runs them inside out.
(equal (log-of (lambda ()
                 (block outer
                   (unwind-protect
                        (unwind-protect (return-from outer :returned) (note :inner))
                     (note :outer)))))
       '((:returned) (:inner :outer)))

;; A go to an outer tagbody runs the cleanups between.
(equal (log-of (lambda ()
                 (let ((passes 0))
                   (tagbody
                    again
                      (incf passes)
                      (unwind-protect (when (< passes 3) (go again)) (note passes)))
                   passes)))
       '((3) (1 2 3)))

;; A throw out of a recursion runs one cleanup per level, deepest first.
(progn
  (defun dig (depth)
    (unwind-protect (if (= depth 0) (throw :bottom depth) (dig (1- depth)))
      (note depth)))
  (equal (log-of (lambda () (catch :bottom (dig 3))))
         '((0) (0 1 2 3))))

;; A return-from out of a closure called through funcall runs the cleanup
;; around the call.
(equal (log-of (lambda ()
                 (block found
                   (let ((leave (lambda (x) (return-from found x))))
                     (unwind-protect (funcall leave :left) (note :cleanup))))))
       '((:left) (:cleanup)))

;; A go out of two unwind-protects in one tagbody runs both.
(equal (log-of (lambda ()
                 (tagbody
                    (unwind-protect (unwind-protect (go out) (note :inner)) (note :outer))
                  out)
                 :out))
       '((:out) (:inner :outer)))

;; --- the abort restart through nested handlers ---

;; The handler declines, so the error goes on to the debugger hook, which
;; invokes abort. That unwinds through the protected form to the
;; restart's clause.
(equal (log-of (lambda ()
                 (let ((*debugger-hook* (lambda (c hook)
                                          (declare (ignore c hook))
                                          (invoke-restart 'abort))))
                   (restart-case
                       (handler-bind ((error (lambda (c) (declare (ignore c)) (note :declined))))
                         (unwind-protect (progn (error "Queue is full.") (note :unreached))
                           (note :cleanup)))
                     (abort () (note :aborted) :restarted)))))
       '((:restarted) (:declined :cleanup :aborted)))

;; A handler that invokes abort runs the cleanups between it and the
;; restart, inside out.
(equal (log-of (lambda ()
                 (restart-case
                     (unwind-protect
                          (handler-bind ((error (lambda (c) (declare (ignore c)) (abort))))
                            (unwind-protect (error "Socket closed.") (note :inner)))
                       (note :outer))
                   (abort () :restarted))))
       '((:restarted) (:inner :outer)))

;; Two abort restarts: the innermost is the one invoked, so only the
;; cleanup inside it runs before its clause, and the outer clause never
;; runs.
(equal (log-of (lambda ()
                 (restart-case
                     (unwind-protect
                          (restart-case
                              (unwind-protect (invoke-restart 'abort) (note :inner))
                            (abort () (note :inner-abort) :inner-restart))
                       (note :outer))
                   (abort () (note :outer-abort) :outer-restart))))
       '((:inner-restart) (:inner :inner-abort :outer)))

;; --- an error or a throw from a cleanup ---

;; An error in a cleanup during a normal exit reaches the outer handler,
;; and the cleanup outside it still runs.
(equal (log-of (lambda ()
                 (handler-case
                     (unwind-protect
                          (unwind-protect (note :body) (error "Cleanup failed."))
                       (note :outer-cleanup))
                   (error () (note :handler) :handled))))
       '((:handled) (:body :outer-cleanup :handler)))

;; An error in a cleanup during a throw replaces the throw, and the
;; cleanups outside it still run.
(equal (log-of (lambda ()
                 (handler-case
                     (catch :never
                       (unwind-protect
                            (unwind-protect (throw :never :thrown) (error "Second failure."))
                         (note :outer-cleanup)))
                   (error () (note :handler) :handled))))
       '((:handled) (:outer-cleanup :handler)))

;; A throw from a cleanup replaces the unwinding an error's handler-case
;; started, and the outer cleanup runs on the way to the catch.
(equal (log-of (lambda ()
                 (catch :rescue
                   (handler-case
                       (unwind-protect
                            (unwind-protect (error "Original failure.") (throw :rescue :rescued))
                         (note :outer-cleanup))
                     (error () (note :handler) :handled)))))
       '((:rescued) (:outer-cleanup)))

;; Cleanups fire in reverse order of entry, and one that throws does not
;; keep the ones outside it from running.
(equal (log-of (lambda ()
                 (catch :done
                   (unwind-protect
                        (unwind-protect
                             (unwind-protect (throw :done :first) (note 3))
                          (note 2)
                          (throw :done :second))
                     (note 1)))))
       '((:second) (3 2 1)))

;; --- cleanup side effects seen across exits ---

;; The value is taken before the cleanup changes the variable it came from.
(equal (log-of (lambda ()
                 (let ((x 1))
                   (list (unwind-protect x (setq x 2)) x))))
       '(((1 2)) ()))

;; A cleanup that leaves with return-from replaces a throw in progress.
(equal (log-of (lambda ()
                 (list (catch :ignored
                         (block override
                           (unwind-protect (throw :ignored :thrown)
                             (note :cleanup)
                             (return-from override :overridden))))
                       :after)))
       '(((:overridden :after)) (:cleanup)))

;; A cleanup holding its own unwind-protect runs it before the outer one's
;; remaining forms, and a later exit still runs every cleanup once.
(equal (log-of (lambda ()
                 (catch :out
                   (unwind-protect (throw :out :thrown)
                     (unwind-protect (note :cleanup-a) (note :cleanup-b))
                     (note :cleanup-c)))))
       '((:thrown) (:cleanup-a :cleanup-b :cleanup-c)))
