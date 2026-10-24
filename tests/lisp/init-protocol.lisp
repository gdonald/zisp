;; The order make-instance runs initialize-instance and shared-initialize
;; methods in, across a class hierarchy. Each case records the calls
;; into *trace* and compares the sequence with the one CLHS 7.1 and the
;; standard method combination give.

(progn
  (defvar *trace* nil)
  (defun traced (form) (setq *trace* nil) (funcall form) (reverse *trace*))
  (defclass init-a () ((s :initarg :s :initform 'default)))
  (defclass init-b (init-a) ())
  (defclass init-c (init-b) ())
  t)

;; 1. A :before on initialize-instance runs ahead of the slot filling.
(progn
  (defmethod initialize-instance :before ((x init-a) &key)
    (push (list :ii-before-a (slot-boundp x 's)) *trace*))
  (equal (traced (lambda () (make-instance 'init-a)))
         '((:ii-before-a nil))))

;; 2. An :after on initialize-instance sees the slots filled.
(progn
  (defmethod initialize-instance :after ((x init-a) &key)
    (push (list :ii-after-a (slot-value x 's)) *trace*))
  (equal (traced (lambda () (make-instance 'init-a)))
         '((:ii-before-a nil) (:ii-after-a default))))

;; 3. A subclass's :before runs ahead of its superclass's.
(progn
  (defmethod initialize-instance :before ((x init-b) &key)
    (push :ii-before-b *trace*))
  (equal (traced (lambda () (make-instance 'init-b)))
         '(:ii-before-b (:ii-before-a nil) (:ii-after-a default))))

;; 4. A subclass's :after runs after its superclass's.
(progn
  (defmethod initialize-instance :after ((x init-b) &key)
    (push :ii-after-b *trace*))
  (equal (traced (lambda () (make-instance 'init-b)))
         '(:ii-before-b (:ii-before-a nil) (:ii-after-a default) :ii-after-b)))

;; 5. shared-initialize's methods run inside initialize-instance's primary.
(progn
  (defmethod shared-initialize :before ((x init-a) slot-names &key)
    (push (list :si-before-a slot-names) *trace*))
  (defmethod shared-initialize :after ((x init-a) slot-names &key)
    (push (list :si-after-a slot-names) *trace*))
  (equal (traced (lambda () (make-instance 'init-a)))
         '((:ii-before-a nil) (:si-before-a t) (:si-after-a t) (:ii-after-a default))))

;; 6. Three levels: befores most specific first, afters least specific first.
(progn
  (defmethod initialize-instance :before ((x init-c) &key) (push :ii-before-c *trace*))
  (defmethod initialize-instance :after ((x init-c) &key) (push :ii-after-c *trace*))
  (equal (traced (lambda () (make-instance 'init-c)))
         '(:ii-before-c :ii-before-b (:ii-before-a nil) (:si-before-a t) (:si-after-a t)
           (:ii-after-a default) :ii-after-b :ii-after-c)))

;; 7. shared-initialize :before and :after interleave by class as well.
(progn
  (defmethod shared-initialize :before ((x init-c) slot-names &key) (push :si-before-c *trace*))
  (defmethod shared-initialize :after ((x init-c) slot-names &key) (push :si-after-c *trace*))
  (equal (traced (lambda () (make-instance 'init-c)))
         '(:ii-before-c :ii-before-b (:ii-before-a nil) :si-before-c (:si-before-a t)
           (:si-after-a t) :si-after-c (:ii-after-a default) :ii-after-b :ii-after-c)))

;; 8. An initarg reaches the slot before any :after sees it.
(equal (traced (lambda () (make-instance 'init-a :s 'given)))
       '((:ii-before-a nil) (:si-before-a t) (:si-after-a t) (:ii-after-a given)))

;; 9. A keyword an :after method accepts is a valid initarg.
(progn
  (defclass init-d () ())
  (defmethod initialize-instance :after ((x init-d) &key extra)
    (push (list :extra extra) *trace*))
  (equal (traced (lambda () (make-instance 'init-d :extra 4)))
         '((:extra 4))))

;; 10. An :around on initialize-instance wraps the whole sequence.
(progn
  (defclass init-e () ())
  (defmethod initialize-instance :around ((x init-e) &key)
    (push :around-in *trace*)
    (call-next-method)
    (push :around-out *trace*))
  (defmethod initialize-instance :before ((x init-e) &key) (push :before *trace*))
  (defmethod initialize-instance :after ((x init-e) &key) (push :after *trace*))
  (equal (traced (lambda () (make-instance 'init-e)))
         '(:around-in :before :after :around-out)))

;; 11. reinitialize-instance calls shared-initialize with no slot names.
(let ((x (make-instance 'init-a)))
  (equal (traced (lambda () (reinitialize-instance x :s 'again)))
         '((:si-before-a nil) (:si-after-a nil))))

;; 12. allocate-instance runs ahead of initialize-instance.
(progn
  (defclass init-f () ())
  (defmethod allocate-instance :before ((class (eql (find-class 'init-f))) &key)
    (push :allocate *trace*))
  (defmethod initialize-instance :before ((x init-f) &key) (push :initialize *trace*))
  (equal (traced (lambda () (make-instance 'init-f)))
         '(:allocate :initialize)))
