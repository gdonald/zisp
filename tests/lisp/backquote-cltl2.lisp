;; The CLtL2 appendix C nested-backquote cases: the four simple depth-2
;; combinations of , and ,@ and the eight two-comma "fools2" forms
;; (,, — ,,@ — ,', — ,',@ — ,@, — ,@,@ — ,@', — ,@',@).
;;
;; The one-element bindings for the ,',@ and ,@',@ cases follow the
;; appendix: multi-element splices there would build a malformed quote.
;;
;; Each form evaluates the depth-2 template once, evals the result, and
;; compares the plain value. Every form produces T under SBCL 2.x as well.

;; `(,,q)
(let ((q '(+ 1 2)))
  (equal (eval ``(,,q)) '(3)))

;; `(,@,q)
(let ((q '(list 1 2)))
  (equal (eval ``(,@,q)) '(1 2)))

;; `(,,@q)
(let ((q '((+ 1 2) (* 2 3))))
  (equal (eval ``(,,@q)) '(3 6)))

;; `(,@,@q)
(let ((q '((list 1 2) (list 3))))
  (equal (eval ``(,@,@q)) '(1 2 3)))

;; `(foo ,,p)
(let ((p '(+ 1 2)))
  (equal (eval ``(foo ,,p)) '(foo 3)))

;; `(foo ,,@q)
(let ((q '((+ 1 2) (* 2 2))))
  (equal (eval ``(foo ,,@q)) '(foo 3 4)))

;; `(foo ,',r)
(let ((r 'bar))
  (equal (eval ``(foo ,',r)) '(foo bar)))

;; `(foo ,',@s)
(let ((s '(bar)))
  (equal (eval ``(foo ,',@s)) '(foo bar)))

;; `(foo ,@,p)
(let ((p '(list 1 2)))
  (equal (eval ``(foo ,@,p)) '(foo 1 2)))

;; `(foo ,@,@q)
(let ((q '((list 1 2) (list 3))))
  (equal (eval ``(foo ,@,@q)) '(foo 1 2 3)))

;; `(foo ,@',r)
(let ((r '(1 2)))
  (equal (eval ``(foo ,@',r)) '(foo 1 2)))

;; `(foo ,@',@s)
(let ((s '((1 2))))
  (equal (eval ``(foo ,@',@s)) '(foo 1 2)))
