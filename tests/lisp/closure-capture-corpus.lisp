;; Every form here must evaluate to T.
;; A closure keeps the bindings of the call that made it, including when
;; that call ends in a tail call whose frame would otherwise be reused.

(flet ((tail-call-capture (predicate list)
         (member-if (lambda (element) (funcall predicate element)) list)))
  (equal (tail-call-capture #'evenp '(1 2 3)) '(2 3)))

(flet ((adder (n) (lambda (x) (+ x n))))
  (eql (funcall (adder 3) 4) 7))

(flet ((tail-to-funcall (n) (funcall (lambda () n))))
  (eql (tail-to-funcall 9) 9))

(flet ((counter ()
         (let ((count 0))
           (lambda () (setq count (1+ count))))))
  (let ((next (counter)))
    (funcall next)
    (eql (funcall next) 2)))

(flet ((two-closures (a b) (list (lambda () a) (lambda () b))))
  (equal (mapcar #'funcall (two-closures 1 2)) '(1 2)))

(flet ((nested (a)
         (funcall (lambda (b) (funcall (lambda (c) (list a b c)) 3)) 2)))
  (equal (nested 1) '(1 2 3)))

(labels ((countdown (n acc)
           (if (zerop n) acc (countdown (1- n) (cons n acc)))))
  (equal (countdown 3 nil) '(1 2 3)))

(labels ((make-echo (tag) (lambda () tag))
         (last-echo (n acc)
           (if (zerop n) acc (last-echo (1- n) (make-echo n)))))
  (eql (funcall (last-echo 3 nil)) 1))
