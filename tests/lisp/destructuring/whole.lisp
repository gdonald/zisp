;; &whole captures the full unparsed macro call form.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; &whole binds the entire call, including the macro name
(progn
  (defmacro dsb-whole-1 (&whole w a) (list 'quote (list w a)))
  (equal (dsb-whole-1 x) '((dsb-whole-1 x) x)))

;; &whole coexists with &rest; both see their own view of the call
(progn
  (defmacro dsb-whole-2 (&whole w &rest r) (list 'quote (list w r)))
  (equal (dsb-whole-2 1 2) '((dsb-whole-2 1 2) (1 2))))

;; &whole coexists with required and defaulted &optional parameters
(progn
  (defmacro dsb-whole-3 (&whole w a &optional b) (list 'quote (list w a b)))
  (equal (dsb-whole-3 x) '((dsb-whole-3 x) x nil)))
