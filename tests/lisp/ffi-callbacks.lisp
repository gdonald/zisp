;; Every form here must evaluate to T.
;;
;; Lisp functions called from C through `defcallback`.

(progn (use-package "ZISP-FFI") t)

(progn
  (defcfun "qsort" :void (base :pointer) (count :size-t) (size :size-t) (compare :pointer))
  (defcallback compare-ints :int ((a :pointer) (b :pointer))
    (let ((x (mem-ref a :int))
          (y (mem-ref b :int)))
      (cond ((< x y) -1) ((> x y) 1) (t 0))))
  t)

;; qsort(3) sorts a hundred ints with a Lisp comparator.
(with-foreign-object (numbers :int 100)
  (dotimes (i 100) (setf (mem-aref numbers :int i) (mod (* i 37) 101)))
  (qsort numbers 100 4 (callback compare-ints))
  (let ((sorted (loop for i below 100 collect (mem-aref numbers :int i))))
    (and (equal sorted (sort (loop for i below 100 collect (mod (* i 37) 101)) #'<))
         (apply #'< sorted))))

;; A callback returning a double, called through its pointer.
(progn
  (defcallback halve :double ((x :double)) (/ x 2))
  (eql (foreign-funcall-pointer (callback halve) :double :double 3d0) 1.5d0))

;; Single-floats in and out.
(progn
  (defcallback scale :float ((x :float) (factor :int)) (* x factor))
  (eql (foreign-funcall-pointer (callback scale) :float :float 1.25 :int 4) 5.0))

;; Integer and float parameters interleaved reach the right parameters.
(progn
  (defcallback mixed :long ((a :int) (b :double) (c :long) (d :float) (e :char))
    (list a b c d e)
    (+ a (floor b) c (floor d) e))
  (eql (foreign-funcall-pointer (callback mixed) :long :int 1 :double 20d0 :long -300 :float 4000.0 :char 5)
       3726))

;; A string parameter arrives as a Lisp string.
(progn
  (defcallback string-length :int ((text :string)) (length text))
  (eql (foreign-funcall-pointer (callback string-length) :int :string "seven!!") 7))

;; Redefining a callback keeps its entry point, unless its result class
;; changes.
(let ((before (callback compare-ints)))
  (defcallback compare-ints :int ((a :pointer) (b :pointer))
    (- (mem-ref a :int) (mem-ref b :int)))
  (pointer-eq before (callback compare-ints)))
(progn
  (defcallback changing :int () 1)
  (let ((before (callback changing)))
    (defcallback changing :double () 2d0)
    (and (not (pointer-eq before (callback changing)))
         (eql (foreign-funcall-pointer (callback changing) :double) 2d0))))

;; An error in a callback is signaled once the foreign call returns.
(progn
  (defcallback failing-compare :int ((a :pointer) (b :pointer))
    (declare (ignore a b))
    (error "the comparator failed"))
  (with-foreign-object (numbers :int 3)
    (dotimes (i 3) (setf (mem-aref numbers :int i) (- 3 i)))
    (eq (handler-case (qsort numbers 3 4 (callback failing-compare))
          (simple-error () :signaled))
        :signaled)))

;; A callback that handles its own error returns normally.
(progn
  (defcallback guarded :int ((x :int))
    (handler-case (if (zerop x) (error "zero") x)
      (error () -1)))
  (equal (list (foreign-funcall-pointer (callback guarded) :int :int 0)
               (foreign-funcall-pointer (callback guarded) :int :int 9))
         '(-1 9)))

;; A name nothing defined as a callback has no pointer.
(eq (handler-case (get-callback 'not-a-callback) (error () :signaled)) :signaled)
(eq (handler-case (defcallback text-result :string () "x") (error () :signaled)) :signaled)
