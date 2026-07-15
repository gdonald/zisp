;; Nested destructuring patterns at arbitrary depth, with &optional, &rest,
;; &key, and &whole recurring inside nested patterns.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; a pattern nested inside another pattern
(progn
  (defmacro dsb-deep-1 ((a (b c))) (list 'quote (list a b c)))
  (equal (dsb-deep-1 (x (y z))) '(x y z)))

;; patterns nested three levels deep
(progn
  (defmacro dsb-deep-2 (((a b) (c (d e)))) (list 'quote (list a b c d e)))
  (equal (dsb-deep-2 ((1 2) (3 (4 5)))) '(1 2 3 4 5)))

;; &optional with a default inside a nested pattern
(progn
  (defmacro dsb-deep-3 ((a &optional (b 'bb))) (list 'quote (list a b)))
  (equal (dsb-deep-3 (x)) '(x bb)))

;; &rest inside a nested pattern collects that sublist's tail
(progn
  (defmacro dsb-deep-4 ((a &rest r) c) (list 'quote (list a r c)))
  (equal (dsb-deep-4 (1 2 3) 4) '(1 (2 3) 4)))

;; &key and &whole inside a nested pattern
(progn
  (defmacro dsb-deep-5 ((&whole w a &key k)) (list 'quote (list w a k)))
  (equal (dsb-deep-5 (x :k 7)) '((x :k 7) x 7)))
