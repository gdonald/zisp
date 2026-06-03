;; tests/lisp/multiple-values-corpus.lisp
;;
;; Acceptance corpus for the multiple-values operators.
;;
;; Each non-comment line: <expected> <form>
;;   <expected> — the complete value list the form returns, as a comma-
;;                separated list of decimal integers and/or NIL, with no
;;                spaces; the token <none> means zero values
;;   <form>     — a single form on one line
;;
;; The driver compares the form's entire value list (not just the primary
;; value) against <expected>. Every expected list is what SBCL 2.x returns.
;;
;; Coverage:
;;   - 0-value producer
;;   - 1-value producer
;;   - many-value producer
;;   - values-list splats a list into values
;;   - multiple-value-prog1 keeps the first form's values, discards the rest
;;   - multiple-value-call concatenates several producers' values
;;   - multiple-value-call mixes a single-valued regular form with a producer
;;   - multiple-value-bind fills a missing value with NIL

;; zero values
<none> (values)

;; one value
5 (values 5)

;; many values
1,2,3 (values 1 2 3)

;; values-list spreads a list
10,20,30 (values-list (quote (10 20 30)))

;; multiple-value-prog1 returns the first form's values
7,8 (multiple-value-prog1 (values 7 8) (values 99))

;; multiple-value-call concatenates the values of every producer
1,2,3,4 (multiple-value-call (lambda (a b c d) (values a b c d)) (values 1 2) (values 3 4))

;; a single-valued regular form contributes exactly one value
5,1,2 (multiple-value-call (lambda (a b c) (values a b c)) 5 (values 1 2))

;; multiple-value-bind binds missing variables to NIL
10,NIL (multiple-value-bind (a b) (values 10) (values a b))
