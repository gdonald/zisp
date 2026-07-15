;; Source positions across macroexpansion.
;;
;; Alternating defmacro / call-form pairs. The driver reads this file with a
;; position table, evaluates each defmacro, macroexpands each call form, and
;; walks the expansion's position table asserting:
;;   (a) conses passed through verbatim keep their pre-expansion position;
;;   (b) conses synthesized by a macro carry that macro's definition
;;       form's position.
;; Every macro synthesizes new structure; identity macros don't qualify.

;; reorders its argument forms into a synthesized call
(defmacro mp-1 (a b)
  (list 'list b a))
(mp-1 (car x) (cdr y))

;; wraps the body in a synthesized progn under a synthesized if
(defmacro mp-2 (c &body b)
  (list 'if c (cons 'progn b) 'nil))
(mp-2 (test p) (do-one p) (do-two p))

;; builds a let binding around user forms
(defmacro mp-3 (x y)
  (list 'let (list (list 'tmp x)) (list 'if 'tmp 'tmp y)))
(mp-3 (find p) (default q))

;; prepends a block header onto the verbatim body spine
(defmacro mp-4 (name &body b)
  (cons 'block (cons name b)))
(mp-4 blk (f 1) (g 2))

;; duplicates one user form inside a synthesized progn
(defmacro mp-5 (form)
  (list 'progn form form))
(mp-5 (h 3))

;; threads a user form through two synthesized call shells
(defmacro mp-6 (x f g)
  (list g (list f x)))
(mp-6 (base v) inner outer)

;; expands a nested macro call built at expansion time; the synthesized
;; conses in the result come from mp-2's expander
(defmacro mp-7 (c &body b)
  (macroexpand-1 (list* 'mp-2 c b)))
(mp-7 (test2 p) (act p))

;; synthesizes a call to another macro without expanding it
(defmacro mp-8 (&body b)
  (cons 'mp-4 (cons 'blk2 b)))
(mp-8 (f 4))

;; builds a let with a synthesized binding list around the verbatim body
(defmacro mp-9 (var val &body b)
  (cons 'let (cons (list (list var val)) b)))
(mp-9 x (compute 5) (use x))

;; chains user forms through two synthesized ifs
(defmacro mp-10 (a b c)
  (list 'if a b (list 'if b c 'nil)))
(mp-10 (p1) (p2) (p3))
