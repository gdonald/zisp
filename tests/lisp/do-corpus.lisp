;; Every form here must evaluate to T.
;; DO steps its variables in parallel and DO* in sequence, which is what
;; these cases separate.

(equal (do ((i 0 (1+ i)) (acc nil (cons i acc))) ((= i 3) acc)) '(2 1 0))

(equal (let ((a 1) (b 2))
         (do ((a b) (b a)) (t (list a b))))
       '(2 1))

(equal (let ((a 1) (b 2))
         (do* ((a b) (b a)) (t (list a b))))
       '(2 2))

(eq (handler-case (do ((a 1) (b a)) (t b)) (error () :unbound-in-parallel))
    :unbound-in-parallel)

(eql (do* ((a 1) (b a)) (t b)) 1)

(equal (do ((i 0 (1+ i)) (j 10 (1- j)) (pairs nil (cons (list i j) pairs)))
           ((= i 2) (reverse pairs)))
       '((0 10) (1 9)))

(eql (do* ((i 0 (1+ i)) (j i (* i 2))) ((= i 3) j)) 6)

(eql (do ((i 0 (1+ i))) (nil) (when (= i 4) (return i))) 4)

(equal (let ((trail nil))
         (do ((i 0 (1+ i)))
             ((= i 3) (reverse trail))
           (push i trail)))
       '(0 1 2))
