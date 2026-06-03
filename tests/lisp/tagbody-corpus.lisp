;; tests/lisp/tagbody-corpus.lisp
;;
;; Acceptance corpus for tagbody / go.
;;
;; Each non-comment line: <expected> <form>
;;   <expected> — NIL, or a decimal integer; the value the form evaluates to
;;   <form>     — a single form on one line that exercises tagbody / go
;;
;; The driver registers three scaffolding primitives so loops can compute
;; a value: + (variadic add), 1- (decrement), zerop. Everything else is
;; core evaluator (let, setq, if, tagbody, go).
;;
;; Every expected value below is what SBCL 2.x produces for the same form.
;; Comparison is exact (fixnum equality, or identity with NIL).
;;
;; Coverage:
;;   - forward jump skipping statements
;;   - sequential fall-through (no go)
;;   - backward jump forming a loop
;;   - go out of a nested tagbody to an outer tag
;;   - integer tags
;;   - empty tagbody returns NIL
;;   - forward jump past an intervening tag
;;   - go out of an if into a terminating tag (loop with early exit)

;; forward jump skips the intervening statement
2 (let ((x 0)) (tagbody (go skip) (setq x 99) skip (setq x 2)) x)

;; statements run in order when no go is taken
5 (let ((x 0)) (tagbody (setq x 1) (setq x 5)) x)

;; backward jump builds a countdown loop: 3 + 2 + 1
6 (let ((i 3) (acc 0)) (tagbody top (setq acc (+ acc i)) (setq i (1- i)) (if (zerop i) nil (go top))) acc)

;; go from an inner tagbody lands on a tag in the enclosing tagbody
5 (let ((r 0)) (tagbody (tagbody (go outer)) (setq r 1) outer (setq r 5)) r)

;; integer tags are matched eql, like symbol tags
7 (let ((x 0)) (tagbody (go 1) (setq x 99) 1 (setq x 7)) x)

;; an empty tagbody yields NIL
NIL (tagbody)

;; forward jump past an intervening tag and its statement
3 (let ((x 0)) (tagbody (setq x 1) (go b) a (setq x 2) b (setq x 3)) x)

;; go inside an if exits the loop at a terminating tag: 5 + 4 + 3 + 2 + 1
15 (let ((n 5) (sum 0)) (tagbody loop (if (zerop n) (go done) nil) (setq sum (+ sum n)) (setq n (1- n)) (go loop) done) sum)
