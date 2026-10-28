;; Every form here must evaluate to T.
;;
;; The foreign function interface, calling functions from the C library
;; zisp is linked with.

(progn (use-package "ZISP-FFI") t)

;; C types: the base types, their sizes, and the aliases for them.
(equal (mapcar #'canonical-foreign-type '(:int :size-t :off-t :ssize-t :uint8 :int64))
       '(:int :unsigned-long :long :long :unsigned-char :long-long))
(equal (mapcar #'foreign-type-size '(:char :short :int :long :pointer :float :double :size-t))
       '(1 2 4 8 8 4 8 8))
(progn
  (defctype :corpus-count :size-t)
  (eq (canonical-foreign-type :corpus-count) :unsigned-long))
(eq (handler-case (canonical-foreign-type :no-such-type) (type-error () :signaled)) :signaled)

;; `defcfun` defines a Lisp function named after the C one, or the name
;; given with it.
(progn
  (defcfun "strlen" :int (s :pointer))
  (and (fboundp 'strlen) (eql (strlen "hello") 5)))
(progn
  (defcfun ("abs" c-abs) :int (n :int))
  (eql (c-abs -7) 7))
(progn
  (defcfun "ldexp" :double (x :double) (exponent :int))
  (fboundp 'ldexp))
(eq (handler-case (defcfun "zisp_corpus_missing_function" :int) (error () :signaled)) :signaled)

;; Arguments: integers within the range of their C type, characters as
;; chars, reals as floats and doubles, and pointers, NIL and strings as
;; pointers.
(eq (handler-case (c-abs (expt 2 40)) (type-error () :signaled)) :signaled)
(eq (handler-case (c-abs "text") (type-error () :signaled)) :signaled)
(progn
  (defcfun "toupper" :int (c :int))
  (defcfun ("toupper" char-upcase-c) :char (c :char))
  (and (eql (toupper 97) 65)
       (eql (char-upcase-c #\a) 65)))
(eql (ldexp 3 2) 12.0d0)
(progn
  (defcfun "ldexpf" :float (x :float) (exponent :int))
  (eql (ldexpf 1.5 3) 12.0))
(progn
  (defcfun "strcmp" :int (a :string) (b :string))
  (and (zerop (strcmp "same" "same"))
       (minusp (strcmp "abc" "abd"))
       (with-foreign-string (s "same") (zerop (strcmp s "same")))))
(eq (handler-case (strlen 'symbol) (type-error () :signaled)) :signaled)

;; Results: each integer type's own bits and sign, floats, doubles,
;; strings, pointers, and nothing for void.
(progn
  (defcfun "atoi" :int (s :string))
  (defcfun "strtoul" :unsigned-long (s :string) (end :pointer) (base :int))
  (defcfun ("strtoul" strtoul-as-int) :int (s :string) (end :pointer) (base :int))
  (and (eql (atoi "-12") -12)
       (eql (strtoul "4294967295" nil 10) 4294967295)
       (eql (strtoul-as-int "4294967295" nil 10) -1)
       (eql (strtoul "18446744073709551615" nil 10) 18446744073709551615)))
(progn
  (defcfun "cos" :double (x :double))
  (defcfun "fabsf" :float (x :float))
  (and (eql (cos 0d0) 1d0)
       (eql (fabsf -2.5) 2.5)))
(progn
  (defcfun "strchr" :string (s :string) (c :int))
  (and (equal (strchr "key=value" (char-code #\=)) "=value")
       (null (strchr "key" (char-code #\=)))))
(progn
  (defcfun "malloc" :pointer (size :size-t))
  (defcfun "free" :void (p :pointer))
  (let ((p (malloc 16)))
    (and (pointerp p)
         (not (null-pointer-p p))
         (null (free p)))))
(equal (foreign-funcall "strlen" :string "abcd" :size-t) 4)
(eql (foreign-funcall-pointer (foreign-symbol-pointer "abs") :int :int -3) 3)

;; Library lookup: symbols in the program and the libraries loaded.
(and (pointerp (foreign-symbol-pointer "strlen"))
     (null (foreign-symbol-pointer "zisp_corpus_missing_function")))
(eq (handler-case (load-foreign-library "/zisp/no/such/library.so") (error () :signaled)) :signaled)
(not (null (or (ignore-errors (load-foreign-library "libm.so.6"))
               (ignore-errors (load-foreign-library "/usr/lib/libSystem.B.dylib")))))

;; `strlen` counts the UTF-8 bytes of a Lisp string.
(and (eql (strlen "") 0)
     (eql (strlen "zisp") 4)
     (eql (strlen "héllo") 6))

;; Foreign memory.
(let ((p (foreign-alloc :int :initial-contents '(3 1 4 1 5))))
  (prog1 (equal (loop for i below 5 collect (mem-aref p :int i)) '(3 1 4 1 5))
    (foreign-free p)))
(let ((p (foreign-alloc :double :count 3 :initial-element 0.5d0)))
  (setf (mem-aref p :double 1) 2)
  (prog1 (equal (loop for i below 3 collect (mem-aref p :double i)) '(0.5d0 2d0 0.5d0))
    (foreign-free p)))
(with-foreign-objects ((cell :pointer) (number :long))
  (setf (mem-ref number :long) -9)
  (setf (mem-ref cell :pointer) number)
  (and (pointer-eq (mem-ref cell :pointer) number)
       (eql (mem-ref (mem-ref cell :pointer) :long) -9)))
(with-foreign-object (bytes :unsigned-char 4)
  (setf (mem-aref bytes :unsigned-char 0) 255
        (mem-aref bytes :unsigned-char 1) 1)
  (and (eql (mem-ref bytes :unsigned-char) 255)
       (eql (mem-ref bytes :char) -1)
       (eql (mem-ref (inc-pointer bytes 1) :unsigned-char) 1)))
(with-foreign-object (x :float)
  (setf (mem-ref x :float) 1.25)
  (eql (mem-ref x :float) 1.25))
(eq (handler-case (with-foreign-object (x :char) (setf (mem-ref x :char) 300))
      (type-error () :signaled))
    :signaled)
(let ((s (foreign-string-alloc "copied")))
  (prog1 (equal (foreign-string-to-lisp s) "copied")
    (foreign-free s)))
(null (foreign-string-to-lisp (null-pointer)))
(not (null (search "FOREIGN-POINTER #x10" (prin1-to-string (make-pointer 16)))))
