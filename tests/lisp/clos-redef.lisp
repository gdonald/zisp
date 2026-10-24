;; change-class and update-instance-for-different-class (CLHS 7.2).
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defclass shape () ((name :initarg :name :accessor shape-name)))
  (defclass square (shape) ((side :initarg :side :initform 1 :accessor side)))
  (defclass circle (shape) ((radius :initarg :radius :initform 2 :accessor radius)))
  t)

;; 1. The instance keeps its identity and becomes one of the new class.
(let* ((s (make-instance 'square :name "a"))
       (same s))
  (change-class s 'circle)
  (and (eq s same) (typep s 'circle) (not (typep s 'square))))

;; 2. A slot both classes have keeps its value.
(let ((s (make-instance 'square :name "kept")))
  (change-class s 'circle)
  (equal (shape-name s) "kept"))

;; 3. A slot only the old class had is gone.
(let ((s (make-instance 'square :side 5)))
  (change-class s 'circle)
  (not (slot-exists-p s 'side)))

;; 4. A slot only the new class has gets its initform.
(let ((s (make-instance 'square)))
  (change-class s 'circle)
  (eql (radius s) 2))

;; 5. Initargs given to change-class fill the added slots.
(let ((s (make-instance 'square)))
  (change-class s 'circle :radius 7)
  (eql (radius s) 7))

;; 6. A shared slot of the old class is retained as a local one.
(progn
  (defclass shared-origin () ((tag :allocation :class :initform :shared)))
  (defclass local-target () ((tag :initform :default)))
  (let ((x (make-instance 'shared-origin)))
    (change-class x 'local-target)
    (eq (slot-value x 'tag) :shared)))

;; 7. A slot that was unbound stays unbound.
(let ((s (make-instance 'square)))
  (change-class s 'circle)
  (not (slot-boundp s 'name)))

;; 8. Slot type widening: the value the new class's wider type allows is kept.
(progn
  (defclass narrow () ((n :initarg :n :type fixnum)))
  (defclass wide () ((n :initarg :n :type number)))
  (let ((x (make-instance 'narrow :n 3)))
    (change-class x 'wide)
    (setf (slot-value x 'n) 2.5)
    (eql (slot-value x 'n) 2.5)))

;; 9. update-instance-for-different-class sees the old state through its
;;    first argument.
(progn
  (defclass celsius () ((degrees :initarg :degrees)))
  (defclass fahrenheit () ((degrees)))
  (defmethod update-instance-for-different-class :after
      ((old celsius) (new fahrenheit) &key)
    (setf (slot-value new 'degrees) (+ 32 (* 9/5 (slot-value old 'degrees)))))
  (let ((x (make-instance 'celsius :degrees 100)))
    (change-class x 'fahrenheit)
    (eql (slot-value x 'degrees) 212)))

;; 10. An initarg no slot or method accepts is an error.
(eq (handler-case (change-class (make-instance 'square) 'circle :no-such-initarg 1)
      (program-error () :rejected))
    :rejected)
