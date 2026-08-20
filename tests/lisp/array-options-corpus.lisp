;; make-array option corpus.
;;
;; Covers the (displaced / adjustable / fill-pointer) options against both
;; a general element type and the specialized ones, plus the combinations
;; the standard rejects. Each top-level form is self-checking and
;; evaluates to T.

(progn
  (defun contents (a)
    (concatenate 'list a))
  (defun signals-error (thunk)
    (if (nth-value 1 (ignore-errors (funcall thunk))) t nil))
  t)

;; A plain general array has none of the three properties.
(let ((a (make-array 3 :initial-element 0)))
  (and (arrayp a)
       (vectorp a)
       (simple-vector-p a)
       (equal (contents a) '(0 0 0))
       (null (adjustable-array-p a))
       (null (array-has-fill-pointer-p a))
       (null (array-displacement a))))

;; Adjustable, general: adjust-array keeps the same array object.
(let ((a (make-array 2 :adjustable t :initial-contents '(1 2))))
  (and (adjustable-array-p a)
       (eq (adjust-array a 4) a)
       (= (array-total-size a) 4)
       (equal (contents a) '(1 2 nil nil))))

;; A fill pointer hides the tail from length while aref still reaches it.
(let ((a (make-array 3 :fill-pointer 1 :initial-contents '(1 2 3))))
  (and (array-has-fill-pointer-p a)
       (= (fill-pointer a) 1)
       (= (length a) 1)
       (= (array-total-size a) 3)
       (= (aref a 2) 3)))

;; Adjustable plus fill pointer: vector-push-extend grows past capacity.
(let ((a (make-array 1 :adjustable t :fill-pointer 0)))
  (vector-push-extend 'x a)
  (vector-push-extend 'y a)
  (and (= (fill-pointer a) 2)
       (equal (contents a) '(x y))
       (> (array-total-size a) 1)))

;; vector-push refuses to grow, and vector-pop gives the last element back.
(let ((a (make-array 2 :fill-pointer 0)))
  (and (eql (vector-push 'x a) 0)
       (eql (vector-push 'y a) 1)
       (null (vector-push 'z a))
       (eq (vector-pop a) 'y)
       (= (fill-pointer a) 1)))

;; Displaced with an offset: writes land in the target.
(let* ((target (make-array 4 :initial-contents '(1 2 3 4)))
       (window (make-array 2 :displaced-to target :displaced-index-offset 1)))
  (setf (aref window 0) 9)
  (and (equal (contents window) '(9 3))
       (equal (contents target) '(1 9 3 4))
       (eq (array-displacement window) target)
       (= (nth-value 1 (array-displacement window)) 1)))

;; Displaced to an adjustable array.
(let* ((target (make-array 4 :adjustable t :initial-contents '(1 2 3 4)))
       (window (make-array 2 :displaced-to target :displaced-index-offset 2)))
  (and (equal (contents window) '(3 4))
       (adjustable-array-p target)
       (null (adjustable-array-p window))))

;; A fill pointer on a displaced array.
(let* ((target (make-array 4 :initial-contents '(1 2 3 4)))
       (window (make-array 3 :displaced-to target :fill-pointer 1)))
  (and (= (length window) 1)
       (= (fill-pointer window) 1)
       (= (aref window 2) 3)))

;; Adjusting a displaced array detaches it and keeps what still fits.
(let* ((target (make-array 4 :initial-contents '(1 2 3 4)))
       (window (make-array 2 :adjustable t :displaced-to target)))
  (adjust-array window 3)
  (and (null (array-displacement window))
       (= (array-total-size window) 3)))

;; Adjusting a non-adjustable array returns a fresh one and leaves the
;; original alone.
(let* ((a (make-array 2 :initial-contents '(1 2)))
       (b (adjust-array a 3)))
  (and (not (eq a b))
       (= (array-total-size a) 2)
       (equal (contents b) '(1 2 nil))))

;; Specialized: a bit array reports its element type and rejects non-bits.
(let ((a (make-array 3 :element-type 'bit :initial-element 1)))
  (and (bit-vector-p a)
       (null (simple-vector-p a))
       (eq (array-element-type a) 'bit)
       (equal (contents a) '(1 1 1))
       (signals-error (lambda () (setf (aref a 0) 2)))
       (signals-error (lambda () (setf (aref a 0) 'x)))))

;; Specialized bit, adjustable, with a fill pointer.
(let ((a (make-array 1 :element-type 'bit :adjustable t :fill-pointer 0)))
  (vector-push-extend 1 a)
  (vector-push-extend 0 a)
  (and (equal (contents a) '(1 0))
       (= (fill-pointer a) 2)))

;; Specialized bit, displaced with an offset.
(let* ((target (make-array 4 :element-type 'bit :initial-contents '(1 0 1 0)))
       (window (make-array 2 :element-type 'bit :displaced-to target
                             :displaced-index-offset 2)))
  (equal (contents window) '(1 0)))

;; Specialized (unsigned-byte 8): range-checked on write.
(let ((a (make-array 2 :element-type '(unsigned-byte 8) :initial-element 255)))
  (and (equal (array-element-type a) '(unsigned-byte 8))
       (equal (contents a) '(255 255))
       (signals-error (lambda () (setf (aref a 0) 256)))
       (signals-error (lambda () (setf (aref a 0) -1)))))

;; Specialized character: a one-dimensional character array is a string,
;; and it takes a fill pointer like any other vector.
(let ((s (make-array 4 :element-type 'character :fill-pointer 0)))
  (vector-push #\a s)
  (vector-push #\b s)
  (and (stringp s)
       (string= s "ab")
       (= (fill-pointer s) 2)
       (eq (array-element-type s) 'character)))

;; An adjustable string grows and keeps its identity.
(let ((s (make-array 2 :element-type 'character :adjustable t
                       :initial-element #\x)))
  (and (eq (adjust-array s 4) s)
       (= (array-total-size s) 4)
       (string= s "xx  ")))

;; Multi-dimensional: row-major layout, and row-major-aref agrees with aref.
(let ((a (make-array '(2 3) :initial-contents '((1 2 3) (4 5 6)))))
  (and (= (array-rank a) 2)
       (equal (array-dimensions a) '(2 3))
       (= (array-total-size a) 6)
       (= (aref a 1 0) 4)
       (= (row-major-aref a 3) 4)
       (progn (setf (row-major-aref a 0) 9) (= (aref a 0 0) 9))))

;; Combinations the standard rejects.
(and (signals-error (lambda () (make-array '(2 2) :fill-pointer 1)))
     (signals-error (lambda () (make-array 2 :displaced-to (make-array 2)
                                             :initial-element 0)))
     (signals-error (lambda () (make-array 2 :initial-element 0
                                             :initial-contents '(1 2))))
     (signals-error (lambda () (make-array 3 :displaced-to (make-array 2))))
     (signals-error (lambda () (make-array 2 :displaced-to (make-array 4)
                                             :displaced-index-offset 3)))
     (signals-error (lambda () (make-array 2 :fill-pointer 3)))
     (signals-error (lambda () (fill-pointer (make-array 2))))
     (signals-error (lambda () (make-array 2 :frobnicate t))))
