;; Local macros: what `macrolet` defines, where it is visible, and how it
;; interacts with the function namespace around it.

(= (macrolet ((twice (form) `(* 2 ,form))) (twice 21)) 42)

(equal (macrolet ((swap-pair (a b) `(list ,b ,a))) (swap-pair 1 2)) '(2 1))

(progn
  (defun local-macro-target (x) (list :function x))
  (equal (macrolet ((local-macro-target (x) `(list :macro ',x)))
           (local-macro-target (+ 1 2)))
         '(:macro (+ 1 2))))

(equal (progn
         (macrolet ((local-macro-target (x) `(list :macro ',x)))
           (local-macro-target 1))
         (local-macro-target 1))
       '(:function 1))

(= (macrolet ((outer-add (x) `(+ ,x 1)))
     (macrolet ((inner-add (x) `(outer-add (outer-add ,x))))
       (inner-add 10)))
   12)

(equal (macrolet ((with-body (name &body body) `(list ',name (progn ,@body))))
         (with-body tag 1 2 3))
       '(tag 3))

(equal (macrolet ((inner () ''inner-result)
                  (outer (&environment env) `',(macroexpand '(inner) env)))
         (outer))
       ''inner-result)

(equal (macrolet ((local-expander (x) `(car ,x)))
         (macroexpand-1 '(local-expander y)))
       '(car y))

(equal (let ((total 0))
         (macrolet ((bump (n) `(setq total (+ total ,n))))
           (dotimes (i 5) (bump i)))
         total)
       10)

(equal (macrolet ((shadowed (x) `(list :macro ,x)))
         (flet ((shadowed (x) (list :function x)))
           (shadowed 1)))
       '(:function 1))

(eq (macrolet () :empty) :empty)

(equal (multiple-value-list (macrolet ((pair () '(values 1 2))) (pair)))
       '(1 2))
