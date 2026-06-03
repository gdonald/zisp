;; tests/lisp/catch-throw-corpus.lisp
;;
;; Acceptance corpus for catch / throw.
;;
;; Each non-comment line: <expected> <form>
;;   <expected> — NIL, or a decimal integer; the value the form evaluates to
;;   <form>     — a single form on one line exercising catch / throw
;;
;; Tags here are keywords and fixnums, which self-evaluate, so no scaffolding
;; primitives are needed. Catch tags are matched with eq, per CLHS.
;;
;; Every expected value below is what SBCL 2.x produces for the same form.
;;
;; Coverage:
;;   - catch with no throw returns its last body value
;;   - throw transfers a value out of the catch
;;   - throw past 5+ catch frames to an outer tag
;;   - an inner catch handles its own tag without reaching an outer catch
;;   - fixnum tags are matched (eq on immediates)
;;   - throw skips a non-matching inner catch and reaches the outer tag

;; catch with no throw: progn value of the body
3 (catch :a 1 2 3)

;; throw unwinds to the matching catch with the thrown value
42 (catch :a (throw :a 42) 99)

;; throw past four intervening catches to the outermost tag (5 frames)
7 (catch :outer (catch :i1 (catch :i2 (catch :i3 (catch :i4 (throw :outer 7))))))

;; the inner catch handles its own tag; the outer tag is never reached
5 (catch :a (catch :b (throw :b 5)))

;; fixnum tags match by eq on immediates
13 (catch 99 (throw 99 13))

;; throw skips the non-matching inner catch and lands on the outer tag
21 (catch :outer (catch :inner (throw :outer 21)) 99)
