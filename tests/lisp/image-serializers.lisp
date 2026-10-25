;; Every form here must evaluate to T.
;;
;; Each kind of object an image holds, written and read back by
;; `%image-round-trip`. Symbols and packages come back as themselves;
;; everything else comes back a fresh object like the original. A CLOS
;; instance is left to the whole-session tests: on its own it would bring
;; a copy of its class with it.

(progn
  (defstruct image-point x y)
  t)

;; conses and symbols
(let ((copy (%image-round-trip (list 'a :b '(c . d)))))
  (and (equal copy '(a :b (c . d))) (eq (first copy) 'a)))

;; numbers
(equal (%image-round-trip (list 1 -7 (expt 2 100) (- (expt 3 80)) 3/4 1.5 2.25d0 #c(1 2) #c(1.5 2.5)))
       (list 1 -7 (expt 2 100) (- (expt 3 80)) 3/4 1.5 2.25d0 #c(1 2) #c(1.5 2.5)))

;; characters and strings
(let* ((adjustable (make-array 3 :element-type 'character :adjustable t :fill-pointer 2 :initial-contents "xyz"))
       (copy (%image-round-trip (list #\a #\λ "text λ" adjustable))))
  (and (equal (subseq copy 0 3) (list #\a #\λ "text λ"))
       (equal (fourth copy) "xy")
       (adjustable-array-p (fourth copy))
       (eql (fill-pointer (fourth copy)) 2)))

;; arrays
(let ((copy (%image-round-trip (list #(1 (2) "three") #*10110
                                     (make-array '(2 3) :initial-contents '((1 2 3) (4 5 6)))
                                     (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(7 8 9))))))
  (and (equalp (first copy) #(1 (2) "three"))
       (equal (second copy) #*10110)
       (eql (aref (third copy) 1 2) 6)
       (equalp (fourth copy) #(7 8 9))
       (equal (array-element-type (fourth copy)) '(unsigned-byte 8))))

;; hash tables
(let ((table (make-hash-table :test 'equal)))
  (setf (gethash "one" table) 1 (gethash '(2) table) 2)
  (let ((copy (%image-round-trip table)))
    (and (not (eq copy table))
         (eq (hash-table-test copy) 'equal)
         (eql (hash-table-count copy) 2)
         (eql (gethash "one" copy) 1)
         (eql (gethash (list 2) copy) 2))))

;; functions: native, interpreted, compiled with what they close over
(let* ((counter (let ((n 10)) (lambda () (incf n))))
       (compiled (funcall (compile nil '(lambda (k) (lambda (x) (+ x k)))) 5))
       (copy (%image-round-trip (list #'car counter compiled))))
  (and (eq (first copy) #'car)
       (eql (funcall (second copy)) 11)
       (eql (funcall (third copy) 1) 6)
       (eql (funcall counter) 11)))

;; packages, pathnames and structures
(let ((copy (%image-round-trip (list (find-package :cl-user) #p"/tmp/file.lisp"
                                     (make-image-point :x 1 :y '(2))))))
  (and (eq (first copy) (find-package :cl-user))
       (equal (second copy) #p"/tmp/file.lisp")
       (image-point-p (third copy))
       (equal (image-point-y (third copy)) '(2))))

;; random states
(let* ((state (make-random-state t))
       (copy (%image-round-trip state))
       (twin (make-random-state state)))
  (eql (random 1000000 copy) (random 1000000 twin)))
