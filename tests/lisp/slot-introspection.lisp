;; Slot definition introspection: the direct slot definitions a class
;; was defined with and the effective ones it combines them into, read
;; through the slot-definition accessors.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

(progn
  (defclass introspected ()
    ((plain)
     (full :initarg :full :initarg :whole :initform (+ 1 2) :type integer
           :allocation :class :reader full-reader :writer full-writer
           :documentation "every option")
     (accessed :accessor accessed)))
  (defun direct-slot (name)
    (find name (class-direct-slots (find-class 'introspected)) :key #'slot-definition-name))
  (defun effective-slot (name)
    (find name (class-slots (find-class 'introspected)) :key #'slot-definition-name))
  t)
(and (eq (slot-definition-name (direct-slot 'full)) 'full)
     (eq (slot-definition-type (direct-slot 'full)) 'integer)
     (eq (slot-definition-allocation (direct-slot 'full)) :class))
(and (equal (slot-definition-initargs (direct-slot 'full)) '(:full :whole))
     (equal (slot-definition-initform (direct-slot 'full)) '(+ 1 2))
     (eql (funcall (slot-definition-initfunction (direct-slot 'full))) 3))
(and (equal (slot-definition-readers (direct-slot 'full)) '(full-reader))
     (equal (slot-definition-writers (direct-slot 'full)) '(full-writer))
     (equal (slot-definition-readers (direct-slot 'accessed)) '(accessed))
     (equal (slot-definition-writers (direct-slot 'accessed)) '((setf accessed))))
(and (null (slot-definition-initargs (direct-slot 'plain)))
     (null (slot-definition-initfunction (direct-slot 'plain)))
     (eq (slot-definition-type (direct-slot 'plain)) t)
     (eq (slot-definition-allocation (direct-slot 'plain)) :instance))
(and (typep (effective-slot 'full) 'standard-effective-slot-definition)
     (typep (direct-slot 'full) 'standard-direct-slot-definition)
     (eq (slot-definition-allocation (effective-slot 'full)) :class)
     (equal (slot-definition-initargs (effective-slot 'full)) '(:full :whole)))
(equal (documentation (direct-slot 'full) t) "every option")

