;;; Conditions as classes.
;;;
;;; The class objects themselves come from the runtime. What is here is
;;; `define-condition`, the standard hierarchy it defines, and the
;;; readers of a condition's slots.

(in-package "COMMON-LISP")

;; A class object is kept on its name's property list, which is where
;; `find-condition-class` and every type test look for it.
(defun find-condition-class (name &optional (errorp t))
  (let ((class (get name '%condition-class)))
    (if class
        class
        (if errorp
            (error "~S does not name a condition type." name)
            nil))))

(defun condition-type-name (condition)
  (%condition-class-name (%condition-class-of condition)))

(defun condition-class-name-p (name)
  (and (symbolp name) (get name '%condition-class) t))

;;; --- define-condition ---

(defun %condition-slot-option (options key)
  "The value following KEY in a slot's option plist, or nil."
  (if (null options)
      nil
      (if (eq (car options) key)
          (cadr options)
          (%condition-slot-option (cddr options) key))))

(defun %condition-slot-option-p (options key)
  (if (null options)
      nil
      (if (eq (car options) key)
          t
          (%condition-slot-option-p (cddr options) key))))

(defun %condition-slot-values (options keys)
  "Every value in a slot's option plist whose key is in KEYS, in order."
  (if (null options)
      nil
      (if (member (car options) keys)
          (cons (cadr options) (%condition-slot-values (cddr options) keys))
          (%condition-slot-values (cddr options) keys))))

(defun %condition-check-slot-options (options)
  (unless (null options)
    (unless (member (car options)
                    '(:initarg :initform :reader :writer :accessor
                      :type :documentation))
      (error "~S is not a slot option of define-condition." (car options)))
    (%condition-check-slot-options (cddr options))))

(defun %condition-slot-spec (slot thunk)
  "One slot description turned into the (name initargs initform) triple
the runtime stores. THUNK is the initform, already closed over the
environment the definition appeared in."
  (if (atom slot)
      (list slot (list (intern (symbol-name slot) "KEYWORD")) nil)
      (let ((options (cdr slot)))
        (%condition-check-slot-options options)
        (list (car slot)
              (%condition-slot-values options '(:initarg))
              thunk))))

(defun %condition-slot-initform-form (slot)
  "The form the expansion wraps in a thunk for one slot, or nil where the
slot has no initform."
  (if (atom slot)
      nil
      (if (%condition-slot-option-p (cdr slot) :initform)
          `(lambda () ,(%condition-slot-option (cdr slot) :initform))
          nil)))

(defun %condition-slot-readers (slot)
  (unless (atom slot)
    (%condition-slot-values (cdr slot) '(:reader :accessor))))

(defun %condition-slot-writers (slot)
  (unless (atom slot)
    (%condition-slot-values (cdr slot) '(:writer :accessor))))

(defun %condition-slot-name (slot)
  (if (atom slot) slot (car slot)))

(defun %condition-report-form (options)
  "The :report option turned into a function of the condition and a
stream. A string reports itself, anything else is a function designator."
  (let ((report (assoc :report options)))
    (if (null report)
        nil
        (if (stringp (cadr report))
            `(lambda (%condition %stream)
               (declare (ignore %condition))
               (write-string ,(cadr report) %stream))
            `(lambda (%condition %stream)
               (funcall (function ,(cadr report)) %condition %stream))))))

(defun %condition-default-initargs (options)
  (let ((given (assoc :default-initargs options)))
    (if given (cdr given) nil)))

(defun %condition-writer-name (given)
  "The symbol a :writer or :accessor option names. `(setf foo)` names the
same place `foo` reads, so it comes to the symbol."
  (if (consp given) (cadr given) given))

(defun %condition-slot-reader (name slot-name)
  "A reader closing over the slot's name rather than its index, so one
inherited by a subclass finds the slot wherever that subclass moved it."
  (lambda (condition)
    (unless (%condition-typep condition (find-condition-class name))
      (error "~S is not a ~S." condition name))
    (%condition-ref condition (%condition-slot-index condition slot-name))))

(defun %condition-slot-setter (name slot-name)
  (lambda (condition new)
    (unless (%condition-typep condition (find-condition-class name))
      (error "~S is not a ~S." condition name))
    (%set-condition-ref condition
                        (%condition-slot-index condition slot-name)
                        new)))

(defun %define-condition-accessors (name slot)
  "The readers and writers one slot description asks for, defined rather
than expanded into: what a definition costs is then a few closures.
A writer that names a place is reached through `setf` rather than through
a function named `(setf ...)`, which zisp has no namespace for yet."
  (let ((slot-name (%condition-slot-name slot)))
    (dolist (reader (%condition-slot-readers slot))
      (setf (symbol-function reader) (%condition-slot-reader name slot-name)))
    (let ((writers (%condition-slot-writers slot)))
      (unless (null writers)
        (let ((setter (gensym "SET-SLOT")))
          (setf (symbol-function setter) (%condition-slot-setter name slot-name))
          (dolist (writer writers)
            (let ((place (%condition-writer-name writer)))
              (%put place '%setf-expander
                    (%make-short-setf-expander place setter)))))))))

(defun %define-condition (name supers slots thunks report default-initargs)
  "What a `define-condition` comes to once its initforms have been closed
over. Keeping the work here rather than in the expansion is what makes a
definition cost a few calls instead of a macro walk over every slot."
  (%put name '%condition-class
        (%make-condition-class
         name
         (mapcar #'find-condition-class (or supers '(condition)))
         (%condition-slot-specs slots thunks)
         report))
  (%put name '%condition-default-initargs default-initargs)
  (dolist (slot slots) (%define-condition-accessors name slot))
  name)

(defun %condition-slot-specs (slots thunks)
  (if (null slots)
      nil
      (cons (%condition-slot-spec (car slots) (car thunks))
            (%condition-slot-specs (cdr slots) (cdr thunks)))))

(defmacro define-condition (name supers slots &rest options)
  `(%define-condition ',name ',supers ',slots
                      (list ,@(mapcar #'%condition-slot-initform-form slots))
                      ,(%condition-report-form options)
                      (list ,@(%condition-default-initargs options))))

;;; --- the root, then the standard hierarchy ---

;; `condition` has no supers, so it cannot go through the macro's default
;; of inheriting from itself.
(%put 'condition '%condition-class
      (%make-condition-class 'condition nil nil nil))
(%put 'condition '%condition-default-initargs nil)

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
             (format stream "~S is not of type ~S."
                     (type-error-datum condition)
                     (type-error-expected-type condition)))))

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

(defun %condition-fill-slot (condition slot initargs)
  "One slot of a fresh condition: whichever initarg named it comes
first, and the initform where none did."
  (let ((index (%condition-slot-index condition (car slot)))
        (filled nil))
    (dolist (initarg (cadr slot))
      (unless filled
        (let ((tail (member initarg initargs)))
          (when tail
            (%set-condition-ref condition index (cadr tail))
            (setq filled t)))))
    (when (and (not filled) (caddr slot))
      (%set-condition-ref condition index (funcall (caddr slot))))))

(defun make-condition (type &rest initargs)
  (let* ((class (if (%condition-class-p type) type (find-condition-class type)))
         (condition (%allocate-condition class))
         (defaults (if (%condition-class-p type)
                       nil
                       (get type '%condition-default-initargs)))
         (all (append initargs defaults)))
    (dolist (slot (%condition-class-slots class))
      (%condition-fill-slot condition slot all))
    condition))

(defun conditionp (object)
  (%condition-p object))

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
    (:|OutOfMemory| . storage-condition)))

(defun %native-condition-initargs (type caught)
  "The slots a condition standing for a native failure can be given. What
the failure was about is known only for the cell errors, and a type error
records neither its datum nor the type it wanted."
  (cond ((subtypep type 'cell-error) (list :name (%last-error-symbol)))
        ((subtypep type 'type-error) (list :datum nil :expected-type nil))
        (t (list :format-control "~A" :format-arguments (list caught)))))

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
      datum
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
    (%raise-condition condition (%condition-raise-kind condition))))

(defun %condition-raise-kind (condition)
  "The Zig failure an unhandled condition unwinds as, which is what the
driver reports when nothing catches it."
  (if (typep condition 'type-error)
      'TypeError
      (if (typep condition 'division-by-zero)
          'DivisionByZero
          (if (typep condition 'control-error)
              'ControlError
              'ProgramError))))

(defun warn (datum &rest arguments)
  (let ((condition (%condition-designator datum arguments 'simple-warning)))
    (unless (typep condition 'warning)
      (error 'type-error :datum condition :expected-type 'warning))
    (%run-handlers condition)
    (format *error-output* "~&WARNING: ~A~%" condition)
    nil))

(defun cerror (continue-control datum &rest arguments)
  (declare (ignore continue-control))
  (apply #'error datum arguments))

(defun invoke-debugger (condition)
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
          signal error cerror warn invoke-debugger
          handler-bind handler-case ignore-errors
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
