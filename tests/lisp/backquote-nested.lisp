;; Backquote nesting at depth 2. Only depth-zero unquotes evaluate in each
;; round; deeper ones are rebuilt for the next round, driven here by an
;; explicit eval. Subforms surviving into the second round are closed, since
;; eval uses the null lexical environment.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; no unquotes: two rounds reproduce the literal
(equal (eval ``(a)) '(a))

;; a single unquote at depth two fires in the second round
(equal (eval ``(,(+ 2 3))) '(5))

;; double unquote: the inner fires in round one, the outer in round two
(let ((x 5)) (equal (eval ``(,,x)) '(5)))

;; unquote of a round-one value protected by quote
(let ((x 'foo)) (equal (eval ``(,',x)) '(foo)))

;; a deep unquote inside a depth-two unquote's subform
(let ((x 4)) (equal (eval ``(a ,(list ,x))) '(a (4))))

;; splicing deferred to the second round
(equal (eval ``(,@'(a b))) '(a b))

;; inner splice provides the outer unquote's subforms
(let ((x '(1 2))) (equal (eval ``(,,@x)) '(1 2)))

;; double unquote nested inside a sublist
(let ((x 7)) (equal (eval ``((,,x) b)) '((7) b)))

;; double unquote in dotted tail position
(let ((x 9)) (equal (eval ``(a . ,,x)) '(a . 9)))

;; a nested backquote as a template element round-trips through eval
(let ((x 5)) (equal (eval (car `(`(a ,,x)))) '(a 5)))
