;; Every form here must evaluate to T.
;; Until conditions are objects an error carries only its name, so a handler
;; clause takes every error rather than dispatching on the type.

(eql (handler-case 5 (error () :handled)) 5)
(eq (handler-case (error "boom") (error () :handled)) :handled)
(eq (handler-case (car 1) (error () :handled)) :handled)
(handler-case (error "boom") (error (condition) (not (null condition))))
(equal (multiple-value-list (handler-case (values 1 2) (error () :handled))) '(1 2))
(equal (handler-case (values 1 2) (:no-error (a b) (list b a))) '(2 1))
(eql (handler-case 7 (error () :handled) (:no-error (x) (* x 2))) 14)
(eq (handler-case (progn (error "boom") :unreachable) (error () :handled)) :handled)
(eql (handler-bind () 5) 5)
(eql (block done (handler-case (return-from done :escaped) (error () :handled))) :escaped)
(eql (catch :tag (handler-case (throw :tag :thrown) (error () :handled))) :thrown)
