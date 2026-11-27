;;; Bit arrays and array index arithmetic.

(in-package "COMMON-LISP")

(defun %check-bit-array (array)
  (unless (and (arrayp array) (eq (array-element-type array) 'bit))
    (error 'type-error :datum array :expected-type '(array bit))))

(defun %bit-array-result (array opt-arg)
  (cond ((null opt-arg) (make-array (array-dimensions array) :element-type 'bit))
        ((eq opt-arg t) array)
        (t (%check-bit-array opt-arg)
           (unless (equal (array-dimensions opt-arg) (array-dimensions array))
             (error "~S does not have the dimensions of ~S." opt-arg array))
           opt-arg)))

(defun %bit-array-operation (operation array-1 array-2 opt-arg)
  (%check-bit-array array-1)
  (%check-bit-array array-2)
  (unless (equal (array-dimensions array-1) (array-dimensions array-2))
    (error "~S and ~S do not have the same dimensions." array-1 array-2))
  (let ((result (%bit-array-result array-1 opt-arg)))
    (dotimes (index (array-total-size array-1) result)
      (setf (row-major-aref result index)
            (logand 1 (funcall operation (row-major-aref array-1 index)
                               (row-major-aref array-2 index)))))))

(macrolet ((define-bit-operation (name operation)
             `(defun ,name (bit-array-1 bit-array-2 &optional opt-arg)
                (%bit-array-operation #',operation bit-array-1 bit-array-2 opt-arg))))
  (define-bit-operation bit-and logand)
  (define-bit-operation bit-ior logior)
  (define-bit-operation bit-xor logxor)
  (define-bit-operation bit-eqv logeqv)
  (define-bit-operation bit-nand lognand)
  (define-bit-operation bit-nor lognor)
  (define-bit-operation bit-andc1 logandc1)
  (define-bit-operation bit-andc2 logandc2)
  (define-bit-operation bit-orc1 logorc1)
  (define-bit-operation bit-orc2 logorc2))

(defun bit-not (bit-array &optional opt-arg)
  (%check-bit-array bit-array)
  (let ((result (%bit-array-result bit-array opt-arg)))
    (dotimes (index (array-total-size bit-array) result)
      (setf (row-major-aref result index) (- 1 (row-major-aref bit-array index))))))

(defun bit (bit-array &rest subscripts)
  (%check-bit-array bit-array)
  (apply #'aref bit-array subscripts))

(defun (setf bit) (new-bit bit-array &rest subscripts)
  (%check-bit-array bit-array)
  (setf (apply #'aref bit-array subscripts) new-bit))

(defun simple-bit-vector-p (object)
  (typep object 'simple-bit-vector))

(defun sbit (bit-array &rest subscripts)
  (check-type bit-array (simple-array bit))
  (apply #'aref bit-array subscripts))

(defun (setf sbit) (new-bit bit-array &rest subscripts)
  (check-type bit-array (simple-array bit))
  (setf (apply #'aref bit-array subscripts) new-bit))

(defun array-in-bounds-p (array &rest subscripts)
  (check-type array array)
  (unless (= (length subscripts) (array-rank array))
    (error 'program-error))
  (loop for subscript in subscripts
        for axis from 0
        always (progn (check-type subscript integer)
                      (and (<= 0 subscript) (< subscript (array-dimension array axis))))))

(defun array-row-major-index (array &rest subscripts)
  (check-type array array)
  (unless (= (length subscripts) (array-rank array))
    (error 'program-error))
  (let ((index 0))
    (loop for subscript in subscripts
          for axis from 0
          for dimension = (array-dimension array axis)
          do (unless (and (integerp subscript) (<= 0 subscript) (< subscript dimension))
               (error 'type-error :datum subscript :expected-type `(integer 0 (,dimension))))
             (setq index (+ (* index dimension) subscript)))
    index))

(in-package "COMMON-LISP-USER")
