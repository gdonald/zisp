;; defclass, slot options, make-instance and slot access.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

;;; defclass

(progn
  (defclass point ()
    ((x :initarg :x :initform 0 :accessor point-x)
     (y :initarg :y :reader point-y :writer set-point-y)))
  t)

(typep (find-class 'point) 'standard-class)
(eq (class-name (find-class 'point)) 'point)
(eq (defclass returned-class () ()) (find-class 'returned-class))

;;; :initform

(eql (point-x (make-instance 'point)) 0)
(eql (point-x (make-instance 'point :x 5)) 5)

(progn
  (defvar *initform-runs* 0)
  (defclass counted () ((n :initform (incf *initform-runs*) :reader counted-n)))
  (make-instance 'counted)
  (make-instance 'counted)
  (eql *initform-runs* 2))

;;; :initarg

(eql (point-y (make-instance 'point :y 7)) 7)
(progn
  (defclass two-initargs () ((v :initarg :a :initarg :b :reader v)))
  (and (eql (v (make-instance 'two-initargs :a 1)) 1)
       (eql (v (make-instance 'two-initargs :b 2)) 2)
       (eql (v (make-instance 'two-initargs :b 3 :a 4)) 3)))

;;; :accessor

(let ((p (make-instance 'point)))
  (setf (point-x p) 9)
  (eql (point-x p) 9))
(typep #'point-x 'generic-function)
(typep #'(setf point-x) 'generic-function)

;;; :reader and :writer

(let ((p (make-instance 'point :y 1)))
  (set-point-y 2 p)
  (eql (point-y p) 2))
(not (fboundp '(setf point-y)))

;;; :allocation :class

(progn
  (defclass shared-counter () ((count :allocation :class :initform 0 :accessor shared-count)))
  (defclass shared-child (shared-counter) ())
  t)
(let ((a (make-instance 'shared-counter))
      (b (make-instance 'shared-counter))
      (c (make-instance 'shared-child)))
  (setf (shared-count a) 10)
  (and (eql (shared-count b) 10) (eql (shared-count c) 10)))

;;; :type

(progn
  (defclass typed () ((n :initarg :n :type integer :accessor typed-n)))
  t)
(eql (typed-n (make-instance 'typed :n 3)) 3)
(eq (handler-case (make-instance 'typed :n "three") (type-error () :rejected)) :rejected)
(eq (handler-case (setf (typed-n (make-instance 'typed :n 1)) 'x) (type-error () :rejected))
    :rejected)
(eq (handler-case (setf (slot-value (make-instance 'typed :n 1) 'n) 2.5)
      (type-error () :rejected))
    :rejected)

;;; :documentation

(progn
  (defclass documented ()
    ((slot :documentation "What the slot holds."))
    (:documentation "A documented class."))
  t)
(equal (documentation 'documented 'type) "A documented class.")
(equal (documentation (find-class 'documented) t) "A documented class.")
(equal (documentation (car (class-direct-slots (find-class 'documented))) t)
       "What the slot holds.")

;;; slot inheritance

(progn
  (defclass base-a () ((s :initarg :from-a :initform :a-default :type number :documentation "a")))
  (defclass base-b () ((s :initarg :from-b :type integer)))
  (defclass merged (base-a base-b) ((s :documentation "merged")))
  t)
(let ((slot (find 's (class-slots (find-class 'merged)) :key #'slot-definition-name)))
  (equal (slot-definition-initargs slot) '(:from-a :from-b)))
(let ((slot (find 's (class-slots (find-class 'merged)) :key #'slot-definition-name)))
  (eq (slot-definition-initform slot) :a-default))
(let ((slot (find 's (class-slots (find-class 'merged)) :key #'slot-definition-name)))
  (subtypep (slot-definition-type slot) '(and number integer)))
(equal (documentation (find 's (class-slots (find-class 'merged)) :key #'slot-definition-name) t)
       "merged")

;;; slot-value, slot-boundp, slot-makunbound

(let ((p (make-instance 'point :y 3)))
  (and (eql (slot-value p 'y) 3)
       (slot-boundp p 'y)
       (progn (slot-makunbound p 'y) (not (slot-boundp p 'y)))
       (eq (handler-case (slot-value p 'y) (unbound-slot () :unbound)) :unbound)))
(let ((p (make-instance 'point)))
  (setf (slot-value p 'y) 4)
  (eql (point-y p) 4))
(slot-exists-p (make-instance 'point) 'x)
(not (slot-exists-p (make-instance 'point) 'z))
(eq (handler-case (slot-value (make-instance 'point) 'z) (error () :missing)) :missing)

;;; with-slots, with-accessors

(let ((p (make-instance 'point :x 1 :y 2)))
  (with-slots (x (why y)) p
    (setf x 10)
    (and (eql x 10) (eql why 2) (eql (point-x p) 10))))
(let ((p (make-instance 'point :x 1 :y 2)))
  (with-accessors ((px point-x) (py point-y)) p
    (setf px 5)
    (and (eql px 5) (eql py 2) (eql (point-x p) 5))))

;;; initargs that no slot or method accepts

(eq (handler-case (make-instance 'point :z 1) (program-error () :rejected)) :rejected)
(typep (make-instance 'point :z 1 :allow-other-keys t) 'point)

;;; :default-initargs

(progn
  (defclass defaulted () ((v :initarg :v :reader defaulted-v)) (:default-initargs :v (+ 1 2)))
  (and (eql (defaulted-v (make-instance 'defaulted)) 3)
       (eql (defaulted-v (make-instance 'defaulted :v 9)) 9)))

;;; defclass errors

(eq (handler-case (eval '(defclass bad-slots () (a a))) (program-error () :rejected)) :rejected)
(eq (handler-case (eval '(defclass bad-initform () ((a :initform 1 :initform 2))))
      (program-error () :rejected))
    :rejected)
(eq (handler-case (eval '(defclass bad-option () () (:metaclass standard-class) (:metaclass standard-class)))
      (program-error () :rejected))
    :rejected)
