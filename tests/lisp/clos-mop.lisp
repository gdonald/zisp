;; The metaobject protocol: finding classes, the metaobject classes,
;; applicable methods and their order, effective methods, and slot
;; definition introspection.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

;;; class-of, find-class, (setf find-class)

(eq (class-of 1) (find-class 'fixnum))
(eq (class-of (find-class 'standard-class)) (find-class 'standard-class))
(eq (class-of #'print-object) (find-class 'standard-generic-function))
(progn
  (defclass mop-thing () ())
  (eq (class-of (make-instance 'mop-thing)) (find-class 'mop-thing)))
(null (find-class 'mop-never-defined nil))
(eq (handler-case (find-class 'mop-never-defined) (error () :signaled)) :signaled)
(progn
  (setf (find-class 'mop-alias) (find-class 'mop-thing))
  (eq (find-class 'mop-alias) (find-class 'mop-thing)))
(progn
  (setf (find-class 'mop-alias) nil)
  (null (find-class 'mop-alias nil)))

;;; the standard metaobject classes

(typep (find-class 'mop-thing) 'standard-class)
(typep (make-instance 'mop-thing) 'standard-object)
(typep #'print-object 'standard-generic-function)
(typep #'print-object 'generic-function)
(typep #'print-object 'function)
(typep (car (generic-function-methods #'print-object)) 'standard-method)
(typep (find-class 'integer) 'built-in-class)
(subtypep 'standard-generic-function 'function)
(subtypep 'standard-class 'class)
(not (subtypep 'condition 'standard-object))

;;; compute-applicable-methods: filtering

(progn
  (defclass cam-a () ())
  (defclass cam-b (cam-a) ())
  (defclass cam-c (cam-b) ())
  (defgeneric cam (x y))
  (defmethod cam ((x cam-a) (y t)) :a-t)
  (defmethod cam ((x cam-b) (y t)) :b-t)
  (defmethod cam ((x cam-c) (y integer)) :c-integer)
  (defmethod cam ((x integer) (y t)) :integer-t)
  t)
(progn
  (defun cam-names (&rest args)
    (mapcar (lambda (m) (funcall (method-function m) args nil))
            (compute-applicable-methods #'cam args)))
  t)
(equal (cam-names (make-instance 'cam-a) 1) '(:a-t))
(equal (cam-names (make-instance 'cam-b) 'x) '(:b-t :a-t))
(equal (cam-names (make-instance 'cam-c) 'x) '(:b-t :a-t))
(null (compute-applicable-methods #'cam (list "string" 1)))

;;; compute-applicable-methods: order

(equal (cam-names (make-instance 'cam-c) 1) '(:c-integer :b-t :a-t))
(progn
  (defgeneric by-second (x y) (:argument-precedence-order y x))
  (defmethod by-second ((x cam-c) (y t)) :first)
  (defmethod by-second ((x t) (y integer)) :second)
  (equal (mapcar (lambda (m) (funcall (method-function m) (list (make-instance 'cam-c) 1) nil))
                 (compute-applicable-methods #'by-second (list (make-instance 'cam-c) 1)))
         '(:second :first)))
(progn
  (defgeneric left-first (x y))
  (defmethod left-first ((x cam-c) (y t)) :first)
  (defmethod left-first ((x t) (y integer)) :second)
  (equal (mapcar (lambda (m) (funcall (method-function m) (list (make-instance 'cam-c) 1) nil))
                 (compute-applicable-methods #'left-first (list (make-instance 'cam-c) 1)))
         '(:first :second)))
(multiple-value-bind (methods definite)
    (compute-applicable-methods-using-classes #'cam (list (find-class 'cam-c) (find-class 'fixnum)))
  (and definite (eql (length methods) 3)))

;;; eql specializers

(progn
  (defgeneric eqlish (x))
  (defmethod eqlish ((x integer)) :integer)
  (defmethod eqlish ((x (eql 3))) :three)
  (defmethod eqlish ((x t)) :t)
  (equal (mapcar (lambda (m) (funcall (method-function m) (list 3) nil))
                 (compute-applicable-methods #'eqlish (list 3)))
         '(:three :integer :t)))
(equal (mapcar (lambda (m) (funcall (method-function m) (list 4) nil))
               (compute-applicable-methods #'eqlish (list 4)))
       '(:integer :t))
(multiple-value-bind (methods definite)
    (compute-applicable-methods-using-classes #'eqlish (list (find-class 'fixnum)))
  (declare (ignore methods))
  (null definite))

;;; a method class of the user's own

(progn
  (defclass counted-method (standard-method) ((uses :initform 0 :accessor uses)))
  (defgeneric with-own-methods (x) (:method-class counted-method))
  (defmethod with-own-methods ((x integer)) :integer)
  (and (eq (generic-function-method-class #'with-own-methods) (find-class 'counted-method))
       (typep (car (generic-function-methods #'with-own-methods)) 'counted-method)
       (eq (with-own-methods 1) :integer)))

