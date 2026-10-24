;;; Conditions.
;;;
;;; A condition type is a class whose metaclass is `condition-class`, and
;;; `define-condition` is `defclass` with that metaclass and a
;;; `print-object` method for its report. What is here is the standard
;;; hierarchy, making and signaling conditions, and restarts.

(in-package "COMMON-LISP")

(defun find-condition-class (name &optional (errorp t))
  "The class NAME names when it is a condition type."
  (let ((class (find-class name nil)))
    (cond ((and class (%condition-class-object-p class)) class)
          (errorp (error "~S does not name a condition type." name))
          (t nil))))

(defun %condition-class-object-p (class)
  (and (%class-p class)
       (%subclassp class (find-class 'condition))))

(defun %condition-p (object)
  (and (%instance-p object)
       (%condition-class-object-p (%instance-class object))))

(defun conditionp (object)
  (%condition-p object))

(defun condition-type-name (condition)
  (class-name (class-of condition)))

;;; --- define-condition ---

(defun %condition-report-method (name options)
  "The :report option as a `print-object` method that runs the report
when the condition is printed without escapes. A string reports itself,
anything else names a function of the condition and a stream."
  (let ((report (assoc :report options)))
    (when report
      `((defmethod print-object ((%condition ,name) %stream)
          (if *print-escape*
              (call-next-method)
              ,(if (stringp (cadr report))
                   `(write-string ,(cadr report) %stream)
                   `(funcall (function ,(cadr report)) %condition %stream))))))))

(defun %condition-class-options (options)
  (let ((result nil))
    (dolist (option options (nreverse result))
      (unless (and (consp option) (%memq (car option) '(:report :default-initargs :documentation)))
        (%program-error "~S is not a define-condition option." option))
      (unless (eq (car option) :report)
        (push option result)))))

(defmacro define-condition (name parent-types slot-specs &rest options)
  `(progn
     (defclass ,name ,(or parent-types '(condition)) ,slot-specs
       (:metaclass condition-class)
       ,@(%condition-class-options options))
     ,@(%condition-report-method name options)
     ',name))

;;; --- the root, then the standard hierarchy ---

(defclass condition (t) () (:metaclass condition-class))

(defmethod print-object ((condition condition) stream)
  (write-string "#<" stream)
  (prin1 (class-name (class-of condition)) stream)
  (write-string ">" stream)
  condition)

(define-condition serious-condition (condition) ())
(define-condition error (serious-condition) ())
(define-condition warning (condition) ())

(define-condition simple-condition (condition)
  ((format-control :initarg :format-control :initform nil
                   :reader simple-condition-format-control)
   (format-arguments :initarg :format-arguments :initform nil
                     :reader simple-condition-format-arguments))
  (:report (lambda (condition stream)
             (let ((control (simple-condition-format-control condition)))
               (if control
                   (apply #'format stream control
                          (simple-condition-format-arguments condition))
                   (format stream "~S" (condition-type-name condition)))))))

(define-condition simple-error (simple-condition error) ())
(define-condition simple-warning (simple-condition warning) ())
(define-condition style-warning (warning) ())

(define-condition storage-condition (serious-condition) ())

(define-condition type-error (error)
  ((datum :initarg :datum :reader type-error-datum)
   (expected-type :initarg :expected-type :reader type-error-expected-type))
  (:report (lambda (condition stream)
             ;; A native that rejected an argument without saying which
             ;; leaves both slots nil.
             (if (or (type-error-datum condition) (type-error-expected-type condition))
                 (format stream "~S is not of type ~S."
                         (type-error-datum condition)
                         (type-error-expected-type condition))
                 (format stream "An argument is not of the type the function needs.")))))

(define-condition simple-type-error (simple-condition type-error) ())

(define-condition program-error (error) ())
(define-condition control-error (error) ())

(define-condition arithmetic-error (error)
  ((operation :initarg :operation :initform nil
              :reader arithmetic-error-operation)
   (operands :initarg :operands :initform nil
             :reader arithmetic-error-operands)))

(define-condition division-by-zero (arithmetic-error) ())
(define-condition floating-point-overflow (arithmetic-error) ())
(define-condition floating-point-underflow (arithmetic-error) ())
(define-condition floating-point-inexact (arithmetic-error) ())
(define-condition floating-point-invalid-operation (arithmetic-error) ())

(define-condition cell-error (error)
  ((name :initarg :name :reader cell-error-name))
  (:report (lambda (condition stream)
             (format stream "~S is not bound." (cell-error-name condition)))))

(define-condition unbound-variable (cell-error) ()
  (:report (lambda (condition stream)
             (format stream "The variable ~S is unbound."
                     (cell-error-name condition)))))

(define-condition undefined-function (cell-error) ()
  (:report (lambda (condition stream)
             (format stream "The function ~S is undefined."
                     (cell-error-name condition)))))

(define-condition unbound-slot (cell-error)
  ((instance :initarg :instance :reader unbound-slot-instance)))

(define-condition package-error (error)
  ((package :initarg :package :reader package-error-package)))

(define-condition stream-error (error)
  ((stream :initarg :stream :reader stream-error-stream)))

(define-condition end-of-file (stream-error) ())

(define-condition file-error (error)
  ((pathname :initarg :pathname :reader file-error-pathname)))

(define-condition parse-error (error) ())
(define-condition reader-error (parse-error stream-error) ())

(define-condition print-not-readable (error)
  ((object :initarg :object :reader print-not-readable-object)))

;;; --- making one ---

(defun make-condition (type &rest initargs)
  (let ((class (cond ((%class-p type) type)
                     ((symbolp type) (find-class type nil))
                     (t (%condition-class-of-type type)))))
    (unless (and class (%condition-class-object-p class))
      (error "~S does not name a condition type." type))
    (apply #'make-instance class initargs)))

(defun %condition-class-of-type (type)
  "A condition class whose instances are of the compound type TYPE, or
where none is, the first condition class TYPE names."
  (or (dolist (class (reverse (%class-descendants (find-class 'condition))) nil)
        (when (subtypep class type) (return class)))
      (labels ((first-named (spec)
                 (cond ((and (symbolp spec) (find-condition-class spec nil)))
                       ((consp spec) (some #'first-named (cdr spec)))
                       (t nil))))
        (first-named type))))

(define-condition %simple-program-error (simple-condition program-error) ())

;;; --- restarts ---

;; Each `restart-bind` pushes one cluster of restarts, innermost first,
;; the way `handler-bind` pushes handlers.
(defvar *restart-clusters* nil)

;; Each `with-condition-restarts` pushes one (condition . restarts) entry.
;; A restart named in some entry is applicable only to the conditions its
;; entries name.
(defvar *condition-restarts* nil)

(defstruct (restart (:conc-name %restart-)
                    (:constructor %make-restart)
                    (:copier nil)
                    (:predicate nil))
  name function report-function interactive-function test-function)

(defun restart-name (restart)
  (%restart-name restart))

(defun %print-restart-report (restart stream)
  (let ((report (%restart-report-function restart)))
    (if report
        (funcall report stream)
        (princ (%restart-name restart) stream))))

(defun %restart-associated-p (restart)
  (dolist (entry *condition-restarts* nil)
    (when (member restart (cdr entry)) (return t))))

(defun %restart-associated-with-p (restart condition)
  (dolist (entry *condition-restarts* nil)
    (when (and (eq (car entry) condition) (member restart (cdr entry)))
      (return t))))

(defun %restart-applicable-p (restart condition)
  (and (or (null condition)
           (not (%restart-associated-p restart))
           (%restart-associated-with-p restart condition))
       (let ((test (%restart-test-function restart)))
         (or (null test) (funcall test condition)))))

(defun compute-restarts (&optional condition)
  (let ((found nil))
    (dolist (cluster *restart-clusters*)
      (dolist (restart cluster)
        (when (%restart-applicable-p restart condition)
          (push restart found))))
    (nreverse found)))

(defun find-restart (identifier &optional condition)
  (dolist (restart (compute-restarts condition) nil)
    (when (if (restart-p identifier)
              (eq restart identifier)
              (eq (%restart-name restart) identifier))
      (return restart))))

(defun restart-p (object)
  (and (%structure-p object) (eq (%structure-name object) 'restart)))

(defun %designated-restart (identifier condition)
  (or (find-restart identifier condition)
      (error 'control-error)))

(defun invoke-restart (restart &rest arguments)
  (apply (%restart-function (%designated-restart restart nil)) arguments))

(defun invoke-restart-interactively (restart)
  (let* ((found (%designated-restart restart nil))
         (interactive (%restart-interactive-function found)))
    (apply (%restart-function found)
           (if interactive (funcall interactive) nil))))

(defun %restart-bind-maker (binding)
  (destructuring-bind (name function &key interactive-function report-function
                                          test-function)
      binding
    `(%make-restart :name ',name
                    :function ,function
                    :interactive-function ,interactive-function
                    :report-function ,report-function
                    :test-function ,test-function)))

(defmacro restart-bind (bindings &body body)
  `(let ((*restart-clusters*
           (cons (list ,@(mapcar #'%restart-bind-maker bindings))
                 *restart-clusters*)))
     ,@body))

(defmacro with-condition-restarts (condition-form restarts-form &body body)
  `(let ((*condition-restarts*
           (cons (cons ,condition-form ,restarts-form) *condition-restarts*)))
     ,@body))

(defun %parse-restart-clause (clause)
  "A `restart-case` clause as (name lambda-list report interactive test
body), the options taken off the front of what follows the lambda list."
  (let ((rest (cddr clause))
        (report nil)
        (interactive nil)
        (test nil))
    (loop
      (unless (and (consp rest) (consp (cdr rest))
                   (member (car rest) '(:report :interactive :test)))
        (return))
      (case (car rest)
        (:report (setq report (cadr rest)))
        (:interactive (setq interactive (cadr rest)))
        (:test (setq test (cadr rest))))
      (setq rest (cddr rest)))
    (list (car clause) (cadr clause) report interactive test rest)))

(defun %restart-case-binding (parsed tag arguments)
  (destructuring-bind (name lambda-list report interactive test body) parsed
    (declare (ignore lambda-list body))
    (let ((given (gensym "ARGUMENTS"))
          (stream (gensym "STREAM")))
      `(,name (lambda (&rest ,given) (setq ,arguments ,given) (go ,tag))
              ,@(when report
                  (list :report-function
                        (if (stringp report)
                            `(lambda (,stream) (write-string ,report ,stream))
                            `(function ,report))))
              ,@(when interactive (list :interactive-function `(function ,interactive)))
              ,@(when test (list :test-function `(function ,test)))))))

(defun %restart-case-form (form environment)
  "CLHS 9.1.4.2.3: where the form is a call to `signal`, `error`, `cerror`
or `warn`, the restarts are associated with the condition it signals."
  (let ((expansion (macroexpand form environment))
        (condition (gensym "CONDITION")))
    (if (and (consp expansion)
             (member (car expansion) '(signal error cerror warn)))
        (let ((cerrorp (eq (car expansion) 'cerror)))
          `(let ((,condition
                   (%condition-designator
                    ,(if cerrorp (caddr expansion) (cadr expansion))
                    (list ,@(if cerrorp (cdddr expansion) (cddr expansion)))
                    ',(case (car expansion)
                        (signal 'simple-condition)
                        (warn 'simple-warning)
                        (t 'simple-error)))))
             (with-condition-restarts ,condition (car *restart-clusters*)
               ,(if cerrorp
                    `(cerror ,(cadr expansion) ,condition)
                    `(,(car expansion) ,condition)))))
        form)))

(defmacro restart-case (form &rest clauses &environment environment)
  (let* ((done (gensym "DONE"))
         (arguments (gensym "ARGUMENTS"))
         (parsed (mapcar #'%parse-restart-clause clauses))
         (tags (mapcar (lambda (clause) (declare (ignore clause)) (gensym "RESTART"))
                       clauses)))
    `(block ,done
       (let ((,arguments nil))
         (tagbody
            (return-from ,done
              (restart-bind
                  ,(mapcar (lambda (clause tag) (%restart-case-binding clause tag arguments))
                           parsed tags)
                ,(%restart-case-form form environment)))
            ,@(mapcan (lambda (clause tag)
                        (list tag
                              `(return-from ,done
                                 (apply (lambda ,(cadr clause) ,@(sixth clause))
                                        ,arguments))))
                      parsed tags))))))

(defmacro with-simple-restart ((name format-control &rest format-arguments) &body body)
  (let ((stream (gensym "STREAM")))
    `(restart-case (progn ,@body)
       (,name ()
         :report (lambda (,stream) (format ,stream ,format-control ,@format-arguments))
         (values nil t)))))

(defun abort (&optional condition)
  (invoke-restart (%designated-restart 'abort condition)))

(defun muffle-warning (&optional condition)
  (invoke-restart (%designated-restart 'muffle-warning condition)))

(defun continue (&optional condition)
  (let ((restart (find-restart 'continue condition)))
    (when restart (invoke-restart restart))))

(defun store-value (value &optional condition)
  (let ((restart (find-restart 'store-value condition)))
    (when restart (invoke-restart restart value))))

(defun use-value (value &optional condition)
  (let ((restart (find-restart 'use-value condition)))
    (when restart (invoke-restart restart value))))

;; What the REPL evaluates each form through, so `abort` has a restart
;; to reach. The first value says whether FORM completed.
(defun %eval-with-abort (form)
  (restart-case (values t (eval form))
    (abort ()
      :report "Return to the top level."
      (values nil nil))))

;;; --- signaling ---

;; Each `handler-bind` pushes one cluster of (type . function) pairs.
;; Binding rather than pushing is what unwinds them: a non-local exit out
;; of the body restores the outer clusters with no cleanup of its own.
(defvar *handler-clusters* nil)

(defvar *break-on-signals* nil)

;; What a Zig error name means as a condition type. A native raises a
;; failure of a kind rather than a condition, so this is what a handler
;; dispatches on when the failure came from one.
(defvar *native-condition-types*
  '((:|UnboundVariable| . unbound-variable)
    (:|UnboundFunction| . undefined-function)
    (:|NotCallable| . undefined-function)
    (:|BadArgList| . program-error)
    (:|NoSpecialFormHandler| . program-error)
    (:|WrongArgCount| . program-error)
    (:|TypeError| . type-error)
    (:|ControlError| . control-error)
    (:|ProgramError| . program-error)
    (:|DivisionByZero| . division-by-zero)
    (:|ArithmeticError| . arithmetic-error)
    (:|FileError| . file-error)
    (:|NoOutputStream| . stream-error)
    (:|NoSuchPackage| . package-error)
    (:|PackageError| . package-error)
    (:|OutOfMemory| . storage-condition)
    (:|StackExhausted| . storage-condition)))

(defun %native-condition-initargs (type caught)
  "The slots a condition standing for a native failure can be given. What
the failure was about is known for the cell errors, and for a type error
whose raise site recorded its datum and the type it wanted."
  (cond ((subtypep type 'cell-error) (list :name (%last-error-symbol)))
        ((subtypep type 'type-error)
         (let ((mismatch (%last-type-mismatch)))
           (list :datum (car mismatch) :expected-type (cadr mismatch))))
        ((subtypep type 'simple-condition)
         (list :format-control "~A" :format-arguments (list caught)))
        (t nil)))

(defun %coerce-caught (caught)
  "What a catcher hands a handler: the condition an `error` carried, or
one built to stand for a failure a native raised."
  (if (%condition-p caught)
      caught
      (let ((type (or (cdr (assoc caught *native-condition-types*)) 'simple-error)))
        (apply #'make-condition type (%native-condition-initargs type caught)))))

(defun %condition-designator (datum arguments default-type)
  "CLHS 9.1.2.1: a condition stands for itself, a symbol names a type to
make one of, and a string or function is a format control."
  (if (%condition-p datum)
      (if arguments
          (error 'type-error :datum arguments :expected-type 'null)
          datum)
      (if (and (symbolp datum) (not (null datum)))
          (apply #'make-condition datum arguments)
          (make-condition default-type
                          :format-control datum
                          :format-arguments arguments))))

(defun %break-on-signals-p (condition)
  (and *break-on-signals*
       (typep condition *break-on-signals*)))

(defun %run-handlers (condition)
  "Offer CONDITION to each cluster from the innermost outwards. A handler
runs with only the clusters outside its own visible, so a condition it
signals cannot reach it again."
  (do ((remaining *handler-clusters* (cdr remaining)))
      ((null remaining) nil)
    (let ((*handler-clusters* (cdr remaining)))
      (dolist (entry (car remaining))
        (when (typep condition (car entry))
          (funcall (cdr entry) condition))))))

(defun signal (datum &rest arguments)
  (let ((condition (%condition-designator datum arguments 'simple-condition)))
    (when (%break-on-signals-p condition)
      (%raise-condition condition 'ProgramError))
    (%run-handlers condition)
    nil))

(defun error (datum &rest arguments)
  (let ((condition (%condition-designator datum arguments 'simple-error)))
    (when (%break-on-signals-p condition)
      (%raise-condition condition 'ProgramError))
    (%run-handlers condition)
    (invoke-debugger condition)))

(defun %condition-raise-kind (condition)
  "The Zig failure an unhandled condition unwinds as, which is what the
driver reports when nothing catches it."
  (cond ((typep condition 'type-error) 'TypeError)
        ((typep condition 'division-by-zero) 'DivisionByZero)
        ((typep condition 'control-error) 'ControlError)
        ((typep condition 'unbound-variable) 'UnboundVariable)
        ((typep condition 'undefined-function) 'UnboundFunction)
        (t 'ProgramError)))

(defun %unbound-variable (name)
  "What evaluating NAME comes to when it has no value: an `unbound-variable`
error with restarts to use a value in its place or to store one."
  (restart-case (error 'unbound-variable :name name)
    (use-value (value)
      :report (lambda (stream) (format stream "Use a value in place of ~S." name))
      :interactive %prompt-for-value
      value)
    (store-value (value)
      :report (lambda (stream) (format stream "Set the value of ~S." name))
      :interactive %prompt-for-value
      (setf (symbol-value name) value))))

(defun warn (datum &rest arguments)
  (let ((condition (%condition-designator datum arguments 'simple-warning)))
    (unless (typep condition 'warning)
      (error 'type-error :datum condition :expected-type 'warning))
    (restart-case
        (with-condition-restarts condition (car *restart-clusters*)
          (%run-handlers condition)
          (format *error-output* "~&WARNING: ~A~%" condition))
      (muffle-warning ()
        :report "Skip warning."
        nil))
    nil))

(defun cerror (continue-control datum &rest arguments)
  (let ((condition (%condition-designator datum arguments 'simple-error)))
    (restart-case
        (with-condition-restarts condition (car *restart-clusters*)
          (error condition))
      (continue ()
        :report (lambda (stream) (apply #'format stream continue-control arguments))
        nil))
    nil))

(defvar *debugger-hook* nil)

;; True while the REPL reads from a person, which is when there is
;; someone for the default debugger to ask.
(defvar *%interactive-debugger* nil)

(defun invoke-debugger (condition)
  "Hand CONDITION to `*debugger-hook*`, bound to nil while it runs so a
failure inside the hook does not reach it again, and then to the default
debugger when the REPL is reading from a person. Where the debugger
returns, the condition unwinds to whatever catches it."
  (let ((hook *debugger-hook*))
    (when hook
      (let ((*debugger-hook* nil))
        (funcall hook condition hook))))
  (when *%interactive-debugger*
    (%default-debugger condition))
  (%raise-condition condition (%condition-raise-kind condition)))

;;; --- handling ---

(defmacro handler-bind (bindings &body body)
  `(let ((*handler-clusters*
           (cons (list ,@(mapcar (lambda (binding)
                                   `(cons ',(car binding) ,(cadr binding)))
                                 bindings))
                 *handler-clusters*)))
     ,@body))

(defun %handler-case-clause-p (clause)
  (not (eq (car clause) :no-error)))

(defmacro handler-case (form &rest clauses)
  "Each clause unwinds first and runs its body afterwards, outside the
handler's own extent, which is what separates this from `handler-bind`.
A failure a native raised does not go through the handler clusters, so it
is caught on the way out and offered to the clauses there."
  (let* ((no-error (assoc :no-error clauses))
         (handlers (remove-if-not #'%handler-case-clause-p clauses))
         (done (gensym "DONE"))
         (held (gensym "CONDITION"))
         (outcome (gensym "OUTCOME"))
         (tags (mapcar (lambda (clause) (declare (ignore clause)) (gensym "CLAUSE"))
                       handlers)))
    `(block ,done
       (let ((,held nil))
         (declare (ignorable ,held))
         (tagbody
            (let ((,outcome (multiple-value-list
                             (%catch-error
                              (handler-bind
                                  ,(%handler-case-bindings handlers tags held)
                                ,form)))))
              (if (car ,outcome)
                  (progn
                    (setq ,held (%coerce-caught (car ,outcome)))
                    ,@(%handler-case-dispatch handlers tags held)
                    (%resignal ,held))
                  (return-from ,done
                    ,(if no-error
                         `(apply (lambda ,(cadr no-error) ,@(cddr no-error))
                                 (cdr ,outcome))
                         `(values-list (cdr ,outcome))))))
            ,@(%handler-case-bodies handlers tags held done))))))

(defun %handler-case-bindings (handlers tags held)
  (mapcar (lambda (clause tag)
            `(,(car clause)
              (lambda (%condition) (setq ,held %condition) (go ,tag))))
          handlers tags))

(defun %handler-case-dispatch (handlers tags held)
  (mapcar (lambda (clause tag) `(when (typep ,held ',(car clause)) (go ,tag)))
          handlers tags))

(defun %handler-case-bodies (handlers tags held done)
  (let ((forms nil))
    (mapc (lambda (clause tag)
            (push tag forms)
            (push `(return-from ,done
                     ,(if (cadr clause)
                          `(let ((,(car (cadr clause)) ,held)) ,@(cddr clause))
                          `(progn ,@(cddr clause))))
                  forms))
          handlers tags)
    (reverse forms)))

(defun %resignal (condition)
  (%raise-condition condition (%condition-raise-kind condition)))

(defmacro ignore-errors (&body body)
  `(handler-case (progn ,@body)
     (error (%condition) (values nil %condition))))

(export '(define-condition make-condition conditionp
          signal error cerror warn invoke-debugger *debugger-hook*
          handler-bind handler-case ignore-errors
          restart restart-name compute-restarts find-restart
          invoke-restart invoke-restart-interactively
          restart-bind restart-case with-condition-restarts with-simple-restart
          abort muffle-warning continue store-value use-value
          *break-on-signals*
          find-condition-class condition-type-name
          condition serious-condition error warning
          simple-condition simple-error simple-warning style-warning
          storage-condition
          type-error simple-type-error program-error control-error
          arithmetic-error division-by-zero
          floating-point-overflow floating-point-underflow
          floating-point-inexact floating-point-invalid-operation
          cell-error unbound-variable undefined-function unbound-slot
          package-error stream-error end-of-file file-error
          parse-error reader-error print-not-readable
          simple-condition-format-control simple-condition-format-arguments
          type-error-datum type-error-expected-type
          arithmetic-error-operation arithmetic-error-operands
          cell-error-name unbound-slot-instance
          package-error-package stream-error-stream file-error-pathname
          print-not-readable-object))

(in-package "COMMON-LISP-USER")
