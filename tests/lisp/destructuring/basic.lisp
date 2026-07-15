;; Single-level macro lambda-list destructuring: required parameters,
;; &optional, &rest, &key.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; required parameters bind the unevaluated argument forms
(progn
  (defmacro dsb-1 (a b) (list 'quote (list a b)))
  (equal (dsb-1 x y) '(x y)))

;; &optional takes its default form when the argument is absent
(progn
  (defmacro dsb-2 (a &optional (b 'zz)) (list 'quote (list a b)))
  (equal (dsb-2 x) '(x zz)))

;; &optional supplied-p is T when the argument is present
(progn
  (defmacro dsb-3 (a &optional (b 'zz b-p)) (list 'quote (list a b b-p)))
  (equal (dsb-3 x y) '(x y t)))

;; &rest collects the remaining argument forms
(progn
  (defmacro dsb-4 (a &rest r) (list 'quote (cons a r)))
  (equal (dsb-4 x y z) '(x y z)))

;; &key binds by keyword; a missing key takes its default
(progn
  (defmacro dsb-5 (&key a (b 'bee)) (list 'quote (list a b)))
  (equal (dsb-5 :a x) '(x bee)))

;; required, &optional, and &rest combine in one lambda list
(progn
  (defmacro dsb-6 (a &optional b &rest r) (list 'quote (list a b r)))
  (equal (dsb-6 1 2 3 4) '(1 2 (3 4))))
