;; Nested destructuring patterns, one level deep, in required, &optional,
;; &rest, and &key positions.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; a required parameter can be a pattern
(progn
  (defmacro dsb-nest-1 ((a b)) (list 'quote (list a b)))
  (equal (dsb-nest-1 (x y)) '(x y)))

;; a pattern combines with ordinary required parameters
(progn
  (defmacro dsb-nest-2 ((a b) c) (list 'quote (list a b c)))
  (equal (dsb-nest-2 (x y) z) '(x y z)))

;; an &optional pattern destructures its default form's value when absent
(progn
  (defmacro dsb-nest-3 (&optional ((a b) '(p q))) (list 'quote (list a b)))
  (equal (dsb-nest-3) '(p q)))

;; &rest can destructure the collected tail
(progn
  (defmacro dsb-nest-4 (a &rest (b c)) (list 'quote (list a b c)))
  (equal (dsb-nest-4 1 2 3) '(1 2 3)))

;; a &key parameter can destructure its value via ((:kw pattern)) syntax
(progn
  (defmacro dsb-nest-5 (&key ((:pt (x y)) '(0 0))) (list 'quote (list x y)))
  (equal (dsb-nest-5 :pt (3 4)) '(3 4)))
