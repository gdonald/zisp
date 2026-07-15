;; &body in macro lambda lists, with docstrings and declare forms at the
;; head of the macro definition body.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; &body collects the remaining forms like &rest
(progn
  (defmacro dsb-body-1 (a &body forms) (list 'quote (cons a forms)))
  (equal (dsb-body-1 x y z) '(x y z)))

;; a docstring before the expansion form is not the expansion
(progn
  (defmacro dsb-body-2 (&body forms)
    "collects its forms"
    (list 'quote forms))
  (equal (dsb-body-2 1 2) '(1 2)))

;; a declare form before the expansion form is not the expansion
(progn
  (defmacro dsb-body-3 (a &body forms)
    (declare (ignore forms))
    (list 'quote a))
  (equal (dsb-body-3 x y) 'x))

;; docstring and declare together precede the expansion form
(progn
  (defmacro dsb-body-4 (a &body forms)
    "drops its first argument"
    (declare (ignore a))
    (list 'quote forms))
  (equal (dsb-body-4 x y z) '(y z)))
