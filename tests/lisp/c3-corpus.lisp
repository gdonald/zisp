;; Class precedence lists. zisp computes them with the topological sort
;; CLHS 4.3.5 specifies. In each case below that order and the C3
;; linearization agree, and a hierarchy with no consistent order is an
;; error at defclass time.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

(progn
  (defun cpl-names (name)
    (mapcar #'class-name (class-precedence-list (find-class name))))
  t)

;; 1. Diamond inheritance: the shared superclass comes once, after both sides.
(progn
  (defclass diamond-top () ())
  (defclass diamond-left (diamond-top) ())
  (defclass diamond-right (diamond-top) ())
  (defclass diamond-bottom (diamond-left diamond-right) ())
  (equal (cpl-names 'diamond-bottom)
         '(diamond-bottom diamond-left diamond-right diamond-top standard-object t)))

;; 2. Multiple inheritance keeps the order the superclasses were listed in.
(progn
  (defclass mix-a () ())
  (defclass mix-b () ())
  (defclass mix-c () ())
  (defclass mixed-abc (mix-a mix-b mix-c) ())
  (defclass mixed-cba (mix-c mix-b mix-a) ())
  (and (equal (cpl-names 'mixed-abc) '(mixed-abc mix-a mix-b mix-c standard-object t))
       (equal (cpl-names 'mixed-cba) '(mixed-cba mix-c mix-b mix-a standard-object t))))

;; 3. The inconsistent hierarchy from the C3 paper is rejected.
(progn
  (defclass c3-x () ())
  (defclass c3-y () ())
  (defclass c3-a (c3-x c3-y) ())
  (defclass c3-b (c3-y c3-x) ())
  (eq (handler-case (progn (defclass c3-z (c3-a c3-b) ()) :accepted)
        (error () :rejected))
      :rejected))

;; 4. A class reached first through one branch but needed later by
;;    another waits for the later one: depth-first order would put
;;    mono-base right after mono-left.
(progn
  (defclass mono-base () ())
  (defclass mono-left (mono-base) ())
  (defclass mono-middle () ())
  (defclass mono-right (mono-middle mono-base) ())
  (defclass mono-bottom (mono-left mono-right) ())
  (equal (cpl-names 'mono-bottom)
         '(mono-bottom mono-left mono-right mono-middle mono-base standard-object t)))

;; 5. Five levels of inheritance.
(progn
  (defclass level-a () ())
  (defclass level-b (level-a) ())
  (defclass level-c (level-b) ())
  (defclass level-d (level-c) ())
  (defclass level-e (level-d) ())
  (defclass level-f (level-e level-a) ())
  (equal (cpl-names 'level-f)
         '(level-f level-e level-d level-c level-b level-a standard-object t)))

;;; class-precedence-list reflection

(equal (cpl-names 'standard-class)
       '(standard-class class specializer metaobject standard-object t))
(equal (cpl-names 'null) '(null symbol list sequence t))
(equal (mapcar #'class-name (class-precedence-list (class-of "abc")))
       '(string vector array sequence t))
(eq (handler-case (progn (defclass not-finalized (no-such-superclass) ())
                         (class-precedence-list (find-class 'not-finalized)))
      (error () :not-finalized))
    :not-finalized)
