;; `define-condition`: the hierarchy it builds, the slots it combines,
;; the accessors it generates, and what `make-condition` fills them with.

;;; the standard hierarchy

(equal (multiple-value-list (subtypep 'error 'condition)) '(t t))
(equal (multiple-value-list (subtypep 'error 'serious-condition)) '(t t))
(equal (multiple-value-list (subtypep 'warning 'error)) '(nil t))
(equal (multiple-value-list (subtypep 'simple-error 'error)) '(t t))
(equal (multiple-value-list (subtypep 'simple-error 'simple-condition)) '(t t))
(equal (multiple-value-list (subtypep 'reader-error 'parse-error)) '(t t))
(equal (multiple-value-list (subtypep 'reader-error 'stream-error)) '(t t))
(equal (multiple-value-list (subtypep 'division-by-zero 'arithmetic-error)) '(t t))
(equal (multiple-value-list (subtypep 'unbound-variable 'cell-error)) '(t t))

;;; instances

(progn
  (defvar *simple* (make-condition 'simple-error
                                   :format-control "count is ~a"
                                   :format-arguments '(3)))
  t)

(conditionp *simple*)
(null (conditionp 3))
(typep *simple* 'simple-error)
(typep *simple* 'error)
(typep *simple* 'condition)
(null (typep *simple* 'warning))
(null (typep 3 'error))
(eq (condition-type-name *simple*) 'simple-error)
(equal (simple-condition-format-control *simple*) "count is ~a")
(equal (simple-condition-format-arguments *simple*) '(3))

;;; initforms and defaults

(progn
  (define-condition slot-defaults (error)
    ((given :initarg :given :reader slot-defaults-given)
     (computed :initarg :computed :initform (+ 20 2)
               :reader slot-defaults-computed)))
  t)

(eql (slot-defaults-computed (make-condition 'slot-defaults :given 1)) 22)
(eql (slot-defaults-computed (make-condition 'slot-defaults :computed 5)) 5)
(eql (slot-defaults-given (make-condition 'slot-defaults :given 9)) 9)

;;; inheritance

(progn
  (define-condition parent-condition (error)
    ((shared :initarg :shared :initform 'from-parent :reader shared-slot)))
  (define-condition child-condition (parent-condition)
    ((extra :initarg :extra :initform 'child-only :reader extra-slot)))
  t)

(eq (shared-slot (make-condition 'child-condition)) 'from-parent)
(eq (extra-slot (make-condition 'child-condition)) 'child-only)
(eq (shared-slot (make-condition 'child-condition :shared 'given)) 'given)
(typep (make-condition 'child-condition) 'parent-condition)
(null (typep (make-condition 'parent-condition) 'child-condition))

;; A slot redefined in a child keeps the position the parent gave it, so
;; an inherited reader still finds it.
(progn
  (define-condition shadowing-condition (parent-condition)
    ((shared :initarg :shared :initform 'from-child :reader shared-slot)))
  t)

(eq (shared-slot (make-condition 'shadowing-condition)) 'from-child)

;;; multiple inheritance

(progn
  (define-condition left-condition (error)
    ((left :initform 'l :reader left-slot)))
  (define-condition right-condition (error)
    ((right :initform 'r :reader right-slot)))
  (define-condition both-condition (left-condition right-condition) ())
  t)

(eq (left-slot (make-condition 'both-condition)) 'l)
(eq (right-slot (make-condition 'both-condition)) 'r)
(typep (make-condition 'both-condition) 'left-condition)
(typep (make-condition 'both-condition) 'right-condition)
(typep (make-condition 'both-condition) 'error)

;;; writers

(progn
  (define-condition writable-condition (error)
    ((tally :initform 0 :accessor writable-tally)))
  (defvar *writable* (make-condition 'writable-condition))
  t)

(eql (writable-tally *writable*) 0)
(progn (setf (writable-tally *writable*) 7) (eql (writable-tally *writable*) 7))

;;; reports

(equal (format nil "~A" *simple*) "count is 3")

(progn
  (define-condition reported-condition (error) ()
    (:report "a fixed report"))
  (define-condition inheriting-report (reported-condition) ())
  t)

(equal (format nil "~A" (make-condition 'reported-condition)) "a fixed report")

(equal (format nil "~A" (make-condition 'inheriting-report)) "a fixed report")

;;; slots with no value

(progn
  (define-condition maybe-bound (error)
    ((slot :initarg :slot :reader maybe-bound-slot)))
  t)

(null (%condition-boundp
       (make-condition 'maybe-bound)
       (%condition-slot-index (find-condition-class 'maybe-bound) 'slot)))

(%condition-boundp
 (make-condition 'maybe-bound :slot nil)
 (%condition-slot-index (find-condition-class 'maybe-bound) 'slot))

;;; a name that is not a condition type

(null (find-condition-class 'not-a-condition-type nil))
