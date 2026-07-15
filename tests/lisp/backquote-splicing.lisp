;; Backquote splicing with ,@ at depth 1.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; the roadmap's canonical case
(equal (eval `(quote ,(append '(a) '(b c) '(d)))) '(a b c d))

;; splice between literals
(equal `(a ,@'(b c) d) '(a b c d))

;; splice at the head
(equal `(,@'(a b) c) '(a b c))

;; splice at the end
(equal `(a ,@'(b c)) '(a b c))

;; splice of the empty list vanishes
(equal `(a ,@'() b) '(a b))

;; splice of nil from a variable vanishes
(let ((x nil)) (equal `(a ,@x b) '(a b)))

;; the whole template is one splice
(let ((x '(a b))) (equal `(,@x) '(a b)))

;; two adjacent splices
(equal `(,@'(a b) ,@'(c d)) '(a b c d))

;; three splices with literals between
(equal `(x ,@'(a) y ,@'(b) z ,@'(c)) '(x a y b z c))

;; splice of a computed list
(equal `(a ,@(append '(b) '(c)) d) '(a b c d))

;; splice mixed with unquote
(let ((x 1) (y '(2 3))) (equal `(,x ,@y 4) '(1 2 3 4)))

;; unquote after splice
(let ((x '(1 2)) (y 3)) (equal `(,@x ,y) '(1 2 3)))

;; splice inside a nested sublist
(equal `(a (b ,@'(c d)) e) '(a (b c d) e))

;; splice inside two nesting levels
(equal `((x (y ,@'(1 2)))) '((x (y 1 2))))

;; splice a list of lists
(equal `(a ,@'((b) (c))) '(a (b) (c)))

;; final splice may produce a dotted tail
(let ((x '(b . c))) (equal `(a ,@x) '(a b . c)))

;; splice followed by a dotted unquote tail
(let ((x '(a b)) (y '(c d))) (equal `(,@x . ,y) '(a b c d)))

;; splice of a one-element list
(equal `(a ,@'(b)) '(a b))

;; splice under an unquote of a sublist
(let ((y '(2 3))) (equal `(a ,(car `(,@y))) '(a 2)))

;; splices in both elements of a pair of sublists
(equal `((,@'(1 2)) (,@'(3))) '((1 2) (3)))

;; empty splice at head and tail
(equal `(,@'() a ,@'()) '(a))
