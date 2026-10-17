;; Restarts: how they are established, found, and invoked, and the
;; standard restarts the condition system and the case macros set up.

(progn
  (defvar *restart-trace* nil)
  (defun restart-note (tag) (setq *restart-trace* (cons tag *restart-trace*)) nil)
  t)

;; restart-bind does not unwind: the restart function runs and its value
;; comes back to the invoker.
(= (restart-bind ((triple (lambda (x) (* x 3))))
     (+ 1 (invoke-restart 'triple 4)))
   13)

;; A restart established by restart-bind is visible to find-restart only
;; inside the body.
(and (restart-bind ((visible-inside (lambda () nil)))
       (typep (find-restart 'visible-inside) 'restart))
     (null (find-restart 'visible-inside)))

;; An inner restart-bind shadows an outer restart of the same name.
(eq (restart-bind ((shadowed (lambda () :outer)))
      (restart-bind ((shadowed (lambda () :inner)))
        (invoke-restart 'shadowed)))
    :inner)

;; restart-case unwinds to the clause and returns its value.
(eq (restart-case (progn (invoke-restart 'retry) :not-reached)
      (retry () :clause))
    :clause)

;; Clause lambda lists take the arguments given to invoke-restart.
(equal (restart-case (invoke-restart 'collect 1 2 :c 3)
         (collect (a b &key c d) (list a b c d)))
       '(1 2 3 nil))

;; With no restart invoked, restart-case returns every value of its form.
(equal (multiple-value-list (restart-case (values 1 2 3) (unused () nil)))
       '(1 2 3))

;; Unwinding through restart-case runs the cleanup of an unwind-protect
;; between the invoker and the clause.
(progn
  (setq *restart-trace* nil)
  (restart-case (unwind-protect (invoke-restart 'leave)
                  (restart-note :cleanup))
    (leave () (restart-note :clause)))
  (equal (reverse *restart-trace*) '(:cleanup :clause)))

;; A :report string is what the restart prints as with ~A.
(equal (restart-case (format nil "~A" (find-restart 'described))
         (described () :report "Try the operation again." nil))
       "Try the operation again.")

;; A :report function is called with the stream.
(equal (restart-case (format nil "~A" (find-restart 'described))
         (described ()
           :report (lambda (stream) (format stream "Report ~D" 42))
           nil))
       "Report 42")

;; A :test that declines hides the clause, so the next one is found.
(eq (restart-case (invoke-restart 'pick)
      (pick () :test (lambda (condition) (declare (ignore condition)) nil) :hidden)
      (pick () :found))
    :found)

;; invoke-restart takes a restart name.
(= (restart-case (invoke-restart 'by-name 5) (by-name (x) (* x 2)))
   10)

;; invoke-restart takes a restart object.
(= (restart-case (invoke-restart (find-restart 'by-object) 5)
     (by-object (x) (* x 3)))
   15)

;; invoke-restart-interactively gets the arguments from :interactive.
(= (restart-case (invoke-restart-interactively 'ask)
     (ask (a b) :interactive (lambda () (list 3 4)) (+ a b)))
   7)

;; Without :interactive the restart is invoked with no arguments.
(eq (restart-case (invoke-restart-interactively 'ask)
      (ask (&optional (given :default)) given))
    :default)

;; compute-restarts lists the visible restarts innermost first.
(equal (restart-case
           (restart-case (mapcar #'restart-name (compute-restarts))
             (inner-one () nil)
             (inner-two () nil))
         (outer () nil))
       '(inner-one inner-two outer))

;; find-restart returns nil for a name with no visible restart.
(null (find-restart 'no-such-restart))

;; invoke-restart on a name with no visible restart is a control-error.
(eq (handler-case (invoke-restart 'no-such-restart)
      (control-error () :control-error))
    :control-error)

;; abort invokes the innermost abort restart.
(eq (restart-case (progn (abort) :not-reached)
      (abort () :aborted))
    :aborted)

;; abort with no abort restart is a control-error.
(eq (handler-case (abort) (control-error () :control-error))
    :control-error)

;; cerror establishes continue, and continue makes cerror return nil.
(equal (handler-bind ((error #'continue))
         (list (cerror "Keep going." "Failed with ~D." 3) :after))
       '(nil :after))

;; The continue restart cerror establishes reports its format control.
(equal (block found
         (handler-bind ((error (lambda (condition)
                                 (return-from found
                                   (format nil "~A" (find-restart 'continue condition))))))
           (cerror "Use ~D instead." "Bad value ~D." 7)))
       "Use 7 instead.")

;; continue with no continue restart returns nil.
(null (continue))

;; warn establishes muffle-warning, which suppresses the printed warning.
(equal (with-output-to-string (*error-output*)
         (handler-bind ((warning #'muffle-warning))
           (warn "Not printed.")))
       "")

;; An unmuffled warning prints.
(equal (with-output-to-string (*error-output*)
         (warn "Printed."))
       (format nil "WARNING: Printed.~%"))

;; muffle-warning with no restart is a control-error.
(eq (handler-case (muffle-warning) (control-error () :control-error))
    :control-error)

;; check-type establishes store-value, which stores into the place.
(equal (let ((place 5))
         (handler-bind ((type-error (lambda (condition) (store-value "five" condition))))
           (check-type place string))
         place)
       "five")

;; use-value supplies a value for an unbound variable without storing it.
(progn
  (makunbound 'restart-corpus-unbound)
  (and (= (handler-bind ((unbound-variable
                           (lambda (condition) (use-value 41 condition))))
            (+ restart-corpus-unbound 1))
          42)
       (not (boundp 'restart-corpus-unbound))))

;; store-value for an unbound variable sets it.
(progn
  (makunbound 'restart-corpus-unbound)
  (and (= (handler-bind ((unbound-variable
                           (lambda (condition) (store-value 9 condition))))
            restart-corpus-unbound)
          9)
       (= restart-corpus-unbound 9)))

;; store-value and use-value return nil where no such restart is visible.
(and (null (store-value 1)) (null (use-value 1)))

;; ccase establishes store-value and retries with the new key.
(eq (let ((key 9))
      (handler-bind ((type-error (lambda (condition) (store-value 2 condition))))
        (ccase key (1 :one) (2 :two))))
    :two)

;; ctypecase establishes store-value the same way.
(eq (let ((thing 9))
      (handler-bind ((type-error (lambda (condition) (store-value 'a condition))))
        (ctypecase thing (symbol :symbol))))
    :symbol)

;; with-simple-restart returns nil and t when its restart is invoked.
(equal (multiple-value-list
        (with-simple-restart (skip "Skip ~A." "this")
          (invoke-restart 'skip)))
       '(nil t))

;; with-simple-restart reports its format control.
(equal (with-simple-restart (skip "Skip ~A." "this")
         (format nil "~A" (find-restart 'skip)))
       "Skip this.")
