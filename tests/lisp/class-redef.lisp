;; Redefining a class: existing instances are left alone until a slot of
;; one is next reached, and are then brought up to date through
;; update-instance-for-redefined-class (CLHS 4.3.6).
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defvar *updates* nil)
  (defmethod update-instance-for-redefined-class :before
      ((instance standard-object) added discarded plist &rest initargs)
    (declare (ignore initargs))
    (push (list (class-name (class-of instance)) added discarded plist) *updates*))
  t)

;;; lazy detection

(progn
  (defclass lazy () ((a :initarg :a :initform 1)))
  (defvar *lazy* (make-instance 'lazy :a 10))
  (setq *updates* nil)
  (defclass lazy () ((a :initarg :a :initform 1) (b :initform 2)))
  (null *updates*))

(progn
  (sleep 0.1)
  (null *updates*))

(progn
  (slot-value *lazy* 'a)
  (equal *updates* '((lazy (b) nil nil))))

(progn
  (setq *updates* nil)
  (slot-value *lazy* 'b)
  (null *updates*))

;;; slot migrations

(progn
  (defclass migrating () ((kept :initarg :kept) (dropped :initarg :dropped)))
  (defvar *migrating* (make-instance 'migrating :kept 1 :dropped 2))
  (defclass migrating () ((kept :initarg :kept) (added :initform :fresh)))
  (setq *updates* nil)
  (eq (slot-value *migrating* 'added) :fresh))

(eql (slot-value *migrating* 'kept) 1)

(and (equal *updates* '((migrating (added) (dropped) (dropped 2))))
     (not (slot-exists-p *migrating* 'dropped)))

;;; user methods that use the discarded values

(progn
  (defclass renamed () ((old-name :initarg :old-name)))
  (defvar *renamed* (make-instance 'renamed :old-name "value"))
  (defclass renamed () ((new-name)))
  (defmethod update-instance-for-redefined-class :after
      ((instance renamed) added discarded plist &rest initargs)
    (declare (ignore added discarded initargs))
    (setf (slot-value instance 'new-name) (getf plist 'old-name)))
  (equal (slot-value *renamed* 'new-name) "value"))

(progn
  (defclass split-point () ((x :initarg :x) (y :initarg :y)))
  (defvar *split* (make-instance 'split-point :x 3 :y 4))
  (defclass split-point () ((xy)))
  (defmethod update-instance-for-redefined-class :after
      ((instance split-point) added discarded plist &rest initargs)
    (declare (ignore added discarded initargs))
    (setf (slot-value instance 'xy) (list (getf plist 'x) (getf plist 'y))))
  (equal (slot-value *split* 'xy) '(3 4)))

;;; edge cases

(progn
  (defclass retyped () ((n :initarg :n :type integer :initform 0)))
  (defvar *retyped* (make-instance 'retyped :n 5))
  (defclass retyped () ((m :type string :initform "fallback")))
  (equal (slot-value *retyped* 'm) "fallback"))

(progn
  (defclass mixin-one () ((one :initform 1)))
  (defclass mixin-two () ((two :initform 2)))
  (defclass mixed (mixin-one) ())
  (defvar *mixed* (make-instance 'mixed))
  (defclass mixed (mixin-two) ())
  (and (eql (slot-value *mixed* 'two) 2)
       (not (slot-exists-p *mixed* 'one))
       (typep *mixed* 'mixin-two)
       (not (typep *mixed* 'mixin-one))))

(progn
  (defclass many-times () ((a :initform 1)))
  (defvar *many* (make-instance 'many-times))
  (defclass many-times () ((a :initform 1) (b :initform 2)))
  (defclass many-times () ((a :initform 1) (b :initform 2) (c :initform 3)))
  (setq *updates* nil)
  (and (equal (list (slot-value *many* 'a) (slot-value *many* 'b) (slot-value *many* 'c)) '(1 2 3))
       (eql (length *updates*) 1)))

(progn
  (defclass before-change () ((a :initarg :a)))
  (defclass after-change () ((a :initarg :a) (z :initform :z)))
  (defvar *both* (make-instance 'before-change :a 1))
  (defclass before-change () ((a :initarg :a) (b :initform :b)))
  (change-class *both* 'after-change)
  (and (eql (slot-value *both* 'a) 1)
       (eq (slot-value *both* 'z) :z)
       (typep *both* 'after-change)))

;;; make-instances-obsolete

(progn
  (defclass obsoleted () ((a :initform 1)))
  (defvar *obsoleted* (make-instance 'obsoleted))
  (slot-value *obsoleted* 'a)
  (make-instances-obsolete 'obsoleted)
  (setq *updates* nil)
  (slot-value *obsoleted* 'a)
  (equal *updates* '((obsoleted nil nil nil))))

;;; shared slots across a redefinition

(progn
  (defclass sharing () ((count :allocation :class :initform 0)))
  (setf (slot-value (make-instance 'sharing) 'count) 5)
  (defclass sharing () ((count :allocation :class :initform 0) (extra :initform t)))
  (eql (slot-value (make-instance 'sharing) 'count) 5))
