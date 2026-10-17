;; Symbol macros: a symbol `symbol-macrolet` binds evaluates as the form
;; it stands for, and assigning it assigns that form's place.

(equal (let ((cell (list 1 2)))
         (symbol-macrolet ((head (car cell)))
           (list head (cadr cell))))
       '(1 2))

(equal (let ((cell (list 1 2)))
         (symbol-macrolet ((head (car cell)))
           (setq head 10))
         cell)
       '(10 2))

(equal (let ((cell (list 1 2)))
         (symbol-macrolet ((head (car cell)))
           (incf head 5))
         cell)
       '(6 2))

(equal (let ((cell (list 1 2)))
         (symbol-macrolet ((head (car cell)))
           (setf head :set))
         cell)
       '(:set 2))

(= (let ((count 0))
     (symbol-macrolet ((next (incf count)))
       next
       next
       next))
   3)

(eq (symbol-macrolet ((shadowed :macro))
      (let ((shadowed :variable))
        shadowed))
    :variable)

(equal (symbol-macrolet ((pair (values 1 2)))
         (multiple-value-list pair))
       '(1 2))

(equal (symbol-macrolet ((head (car cell)))
         (multiple-value-list (macroexpand-1 'head)))
       '((car cell) t))

(equal (macrolet ((expand-in-place (symbol &environment env)
                    `',(macroexpand symbol env)))
         (symbol-macrolet ((head (car cell)))
           (expand-in-place head)))
       '(car cell))

(eq (handler-case (eval '(symbol-macrolet ((*print-base* 1)) *print-base*))
      (program-error () :program-error))
    :program-error)
