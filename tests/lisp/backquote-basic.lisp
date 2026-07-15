;; Backquote at depth 1: plain templates, unquote, dotted tails.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; a template with no unquotes is the literal list
(equal `(a b c) '(a b c))

;; unquote inserts an evaluated value
(let ((x 2)) (equal `(a ,x c) '(a 2 c)))

;; a template that is nothing but one unquote element
(let ((x 2)) (equal `(,x) '(2)))

;; backquote of a bare unquote is just the value
(let ((x 2)) (equal `,x 2))

;; unquote in dotted tail position
(let ((x '(b c))) (equal `(a . ,x) '(a b c)))

;; literal dotted tail survives
(equal `(a b . c) '(a b . c))

;; unquotes inside nested sublists
(let ((x 1) (y 2)) (equal `((,x) (b ,y)) '((1) (b 2))))

;; unquote of a computed expression
(equal `(1 ,(+ 1 1) 3) '(1 2 3))

;; the empty template is nil
(equal `() 'nil)

;; dotted unquotes at two levels
(let ((x 'end) (y '(tail))) (equal `((a . ,x) . ,y) '((a . end) tail)))
