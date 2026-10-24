;; Every form here must evaluate to T.
;;
;; A binding a compiled closure captures stays mutable and outlives the
;; form that made it: every closure over it sees an assignment any one
;; of them makes.

(progn
  (funcall (compile nil '(lambda ()
                           (let ((x 0))
                             (defun compiled-closures-get-x () x)
                             (defun compiled-closures-inc-x () (incf x))))))
  (compiled-closures-inc-x)
  (compiled-closures-inc-x)
  (eql (compiled-closures-get-x) 2))

(listp (%function-constants #'compiled-closures-get-x))

(let ((pair (funcall (compile nil '(lambda ()
                                     (let ((n 10))
                                       (cons (lambda () n)
                                             (lambda (m) (setq n m)))))))))
  (funcall (cdr pair) 25)
  (eql (funcall (car pair)) 25))

(equal (funcall (compile nil '(lambda ()
                                (let ((shared 0))
                                  (let ((outer (lambda ()
                                                 (let ((inner (lambda () (incf shared 100))))
                                                   (funcall inner)
                                                   (incf shared)))))
                                    (funcall outer)
                                    (list shared (funcall outer) shared))))))
       '(101 202 202))

(equal (funcall (compile nil '(lambda ()
                                (let ((counters
                                        (loop for i from 1 to 3
                                              collect (let ((count (* i 10)))
                                                        (lambda () (incf count))))))
                                  (mapc #'funcall counters)
                                  (mapcar #'funcall counters)))))
       '(12 22 32))

(eql (funcall (compile nil '(lambda ()
                              (let ((x 1))
                                (flet ((bump () (setq x (* x 3))))
                                  (bump)
                                  (bump))
                                x))))
     9)
