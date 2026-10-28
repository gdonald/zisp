;; Every form here must evaluate to T.
;;
;; C structures laid out by `defcstruct`, and read and written by C.

(progn (use-package "ZISP-FFI") t)

;; Each field sits at the next offset its alignment allows, and the size
;; is a multiple of the largest alignment.
(progn
  (defcstruct padded (a :char) (b :int) (c :char) (d :double) (e :short))
  (and (equal (mapcar (lambda (name) (foreign-slot-offset 'padded name)) (foreign-slot-names 'padded))
              '(0 4 8 16 24))
       (eql (foreign-type-size '(:struct padded)) 32)
       (eql (foreign-type-alignment '(:struct padded)) 8)))

;; An array field takes its count of elements.
(progn
  (defcstruct with-array (tag :char) (cells :int :count 3) (end :char))
  (and (equal (mapcar (lambda (name) (foreign-slot-offset 'with-array name)) '(tag cells end))
              '(0 4 16))
       (eql (foreign-type-size '(:struct with-array)) 20)))

;; A structure field is aligned as the structure is.
(progn
  (defcstruct outer (flag :char) (inner (:struct padded)) (tail :char))
  (and (eql (foreign-slot-offset 'outer 'inner) 8)
       (eql (foreign-slot-offset 'outer 'tail) 40)
       (eql (foreign-type-size '(:struct outer)) 48)))

;; Fields are read and written in foreign memory, and an array or
;; structure field is a pointer to it.
(with-foreign-object (record '(:struct outer))
  (setf (foreign-slot-value record 'outer 'flag) 7)
  (let ((inner (foreign-slot-value record 'outer 'inner)))
    (setf (foreign-slot-value inner 'padded 'd) 2.5d0)
    (and (eql (foreign-slot-value record 'outer 'flag) 7)
         (eql (mem-ref record :double 24) 2.5d0)
         (pointer-eq inner (foreign-slot-pointer record 'outer 'inner)))))
(with-foreign-object (record '(:struct with-array))
  (let ((cells (foreign-slot-value record 'with-array 'cells)))
    (dotimes (i 3) (setf (mem-aref cells :int i) (* 10 i)))
    (equal (loop for i below 3 collect (mem-ref record :int (+ 4 (* 4 i)))) '(0 10 20))))

;; C fills a struct tm, and C reads one Lisp changed.
(progn
  (defcstruct tm
    (sec :int) (min :int) (hour :int) (mday :int) (mon :int) (year :int)
    (wday :int) (yday :int) (isdst :int) (gmtoff :long) (zone :pointer))
  (defcfun "gmtime_r" :pointer (time :pointer) (result :pointer))
  (defcfun "strftime" :size-t (out :pointer) (max :size-t) (format :string) (tm :pointer))
  (eql (foreign-type-size '(:struct tm)) 56))
(with-foreign-objects ((now :long) (parts '(:struct tm)) (text :char 64))
  (setf (mem-ref now :long) 1000000000)
  (gmtime-r now parts)
  (and (equal (mapcar (lambda (field) (foreign-slot-value parts 'tm field)) '(year mon mday hour min sec))
              '(101 8 9 1 46 40))
       (progn
         (setf (foreign-slot-value parts 'tm 'year) 99)
         (strftime text 64 "%Y-%m-%d %H:%M:%S" parts)
         (equal (foreign-string-to-lisp text) "1999-09-09 01:46:40"))))

;; Several structures in one allocation.
(let ((records (foreign-alloc '(:struct padded) :count 3)))
  (dotimes (i 3)
    (setf (foreign-slot-value (inc-pointer records (* i 32)) 'padded 'b) (* i i)))
  (prog1 (equal (loop for i below 3 collect (mem-ref records :int (+ 4 (* i 32)))) '(0 1 4))
    (foreign-free records)))

;; A structure or field that was not defined signals.
(eq (handler-case (foreign-type-size '(:struct undefined-struct)) (type-error () :signaled)) :signaled)
(eq (handler-case (foreign-slot-offset 'padded 'missing) (error () :signaled)) :signaled)

;; A Lisp structure with typed slots gets the C layout its types give,
;; and copies to and from C memory.
(progn
  (defstruct sample
    (id 0 :type (unsigned-byte 8))
    (count 0 :type (signed-byte 32))
    (weight 0d0 :type double-float)
    (ratio 0.0 :type single-float)
    (total 0 :type fixnum))
  (defcstruct-from-defstruct sample)
  (and (equal (mapcar (lambda (name) (foreign-slot-offset 'sample name)) (foreign-slot-names 'sample))
              '(0 4 8 16 24))
       (eql (foreign-type-size '(:struct sample)) 32)))
(with-foreign-object (record '(:struct sample))
  (write-foreign-struct (make-sample :id 200 :count -5 :weight 1.5d0 :ratio 0.25 :total 123456789)
                        record)
  (let ((copy (read-foreign-struct record 'sample)))
    (and (sample-p copy)
         (equal (list (sample-id copy) (sample-count copy) (sample-weight copy)
                      (sample-ratio copy) (sample-total copy))
                '(200 -5 1.5d0 0.25 123456789))
         (eql (mem-ref record :int 4) -5))))
(eq (handler-case (progn (defstruct untyped-sample label) (defcstruct-from-defstruct untyped-sample))
      (error () :signaled))
    :signaled)
