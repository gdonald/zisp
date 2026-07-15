;; Macro lambda-list destructuring: expansion corpus.
;;
;; Each top-level form defines a macro whose expansion quotes the values the
;; lambda list bound, macroexpands a call with macroexpand-1, and compares
;; the expansion with equal. Every form evaluates to T, in zisp and SBCL 2.x.

;; required parameters
(progn
  (defmacro mdc-1 (a b c) (list 'quote (list a b c)))
  (equal (macroexpand-1 '(mdc-1 x y z)) ''(x y z)))

;; &optional default sees an earlier parameter
(progn
  (defmacro mdc-2 (a &optional (b a)) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-2 x)) ''(x x)))

;; &optional supplied-p is t when the argument is present
(progn
  (defmacro mdc-3 (a &optional (b 'd b-p)) (list 'quote (list a b b-p)))
  (equal (macroexpand-1 '(mdc-3 x y)) ''(x y t)))

;; &optional supplied-p is nil when the argument is absent
(progn
  (defmacro mdc-4 (a &optional (b 'd b-p)) (list 'quote (list a b b-p)))
  (equal (macroexpand-1 '(mdc-4 x)) ''(x d nil)))

;; &rest with no remaining forms binds nil
(progn
  (defmacro mdc-5 (a &rest r) (list 'quote (list a r)))
  (equal (macroexpand-1 '(mdc-5 x)) ''(x nil)))

;; &rest collects the remaining forms
(progn
  (defmacro mdc-6 (a &rest r) (list 'quote (list a r)))
  (equal (macroexpand-1 '(mdc-6 x y z)) ''(x (y z))))

;; &body behaves like &rest
(progn
  (defmacro mdc-7 (a &body b) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-7 x y z)) ''(x (y z))))

;; &key binds independently of argument order
(progn
  (defmacro mdc-8 (&key a b) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-8 :b y :a x)) ''(x y)))

;; &key default sees a required parameter
(progn
  (defmacro mdc-9 (r &key (k r)) (list 'quote (list r k)))
  (equal (macroexpand-1 '(mdc-9 x)) ''(x x)))

;; &key supplied-p
(progn
  (defmacro mdc-10 (&key (k 'd k-p)) (list 'quote (list k k-p)))
  (equal (macroexpand-1 '(mdc-10 :k x)) ''(x t)))

;; explicit keyword name for a &key variable
(progn
  (defmacro mdc-11 (&key ((:k v) 'd)) (list 'quote (list v)))
  (equal (macroexpand-1 '(mdc-11 :k x)) ''(x)))

;; a non-keyword symbol as the &key name
(progn
  (defmacro mdc-12 (&key ((k v))) (list 'quote (list v)))
  (equal (macroexpand-1 '(mdc-12 k x)) ''(x)))

;; &allow-other-keys in the lambda list
(progn
  (defmacro mdc-13 (&key a &allow-other-keys) (list 'quote (list a)))
  (equal (macroexpand-1 '(mdc-13 :a x :z 9)) ''(x)))

;; :allow-other-keys t from the call site
(progn
  (defmacro mdc-14 (&key a) (list 'quote (list a)))
  (equal (macroexpand-1 '(mdc-14 :a x :z 9 :allow-other-keys t)) ''(x)))

;; duplicate keywords: first occurrence wins
(progn
  (defmacro mdc-15 (&key a) (list 'quote (list a)))
  (equal (macroexpand-1 '(mdc-15 :a x :a y)) ''(x)))

;; &aux binds an expansion-time value
(progn
  (defmacro mdc-16 (a &aux (b 5)) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-16 x)) ''(x 5)))

;; &aux init sees the parameters
(progn
  (defmacro mdc-17 (a &aux (b a)) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-17 x)) ''(x x)))

;; &whole binds the entire call form
(progn
  (defmacro mdc-18 (&whole w a) (list 'quote (list w a)))
  (equal (macroexpand-1 '(mdc-18 x)) ''((mdc-18 x) x)))

;; &whole combines with &key
(progn
  (defmacro mdc-19 (&whole w &key k) (list 'quote (list w k)))
  (equal (macroexpand-1 '(mdc-19 :k x)) ''((mdc-19 :k x) x)))

;; dotted lambda list binds the tail
(progn
  (defmacro mdc-20 (a . r) (list 'quote (list a r)))
  (equal (macroexpand-1 '(mdc-20 x y z)) ''(x (y z))))

;; dotted nested pattern matches a dotted argument form
(progn
  (defmacro mdc-21 ((p . q)) (list 'quote (list p q)))
  (equal (macroexpand-1 '(mdc-21 (1 . 2))) ''(1 2)))

;; nested pattern one level deep
(progn
  (defmacro mdc-22 ((a b)) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-22 (x y))) ''(x y)))

;; nested pattern two levels deep
(progn
  (defmacro mdc-23 ((a (b c))) (list 'quote (list a b c)))
  (equal (macroexpand-1 '(mdc-23 (x (y z)))) ''(x y z)))

;; nested pattern three levels deep
(progn
  (defmacro mdc-24 ((a (b (c d)))) (list 'quote (list a b c d)))
  (equal (macroexpand-1 '(mdc-24 (x (y (z w))))) ''(x y z w)))

;; &optional pattern destructures its default when absent
(progn
  (defmacro mdc-25 (&optional ((a b) '(p q))) (list 'quote (list a b)))
  (equal (macroexpand-1 '(mdc-25)) ''(p q)))

;; &rest pattern destructures the collected tail
(progn
  (defmacro mdc-26 (a &rest (b c)) (list 'quote (list a b c)))
  (equal (macroexpand-1 '(mdc-26 1 2 3)) ''(1 2 3)))

;; &key pattern destructures the keyword's value
(progn
  (defmacro mdc-27 (&key ((:pt (x y)) '(0 0))) (list 'quote (list x y)))
  (equal (macroexpand-1 '(mdc-27 :pt (3 4))) ''(3 4)))

;; &key inside a nested pattern
(progn
  (defmacro mdc-28 ((a &key k)) (list 'quote (list a k)))
  (equal (macroexpand-1 '(mdc-28 (x :k 7))) ''(x 7)))

;; &whole inside a nested pattern binds that sublist
(progn
  (defmacro mdc-29 ((&whole w a)) (list 'quote (list w a)))
  (equal (macroexpand-1 '(mdc-29 (x))) ''((x) x)))

;; required, pattern, &optional, &rest, &key, &aux, and &whole together
(progn
  (defmacro mdc-30 (&whole w a (b . c) &optional (d 'dd d-p) &rest r &key k &aux (x2 'xx))
    (list 'quote (list w a b c d d-p r k x2)))
  (equal (macroexpand-1 '(mdc-30 p (q r2) e :k 9))
         ''((mdc-30 p (q r2) e :k 9) p q (r2) e t (:k 9) 9 xx)))
