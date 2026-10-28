;; Every form here must evaluate to T.
;;
;; The compiler infers types from `the`, declarations, the initial values
;; of variables nothing assigns, `typep` tests and the result types it
;; derived for other functions, and compiles arithmetic on values of a
;; known type to instructions that do not dispatch on the type.

(progn
  (defun inferred-listing (function)
    (let ((listing (with-output-to-string (*standard-output*) (disassemble function))))
      (subseq listing 0 (search "Constants:" listing))))
  (defun inferred-mentions (function op)
    (not (null (search (format nil "  ~a~%" op) (inferred-listing function)))))
  t)

;; A `the` types its value for whatever uses it: the outer sum adds two
;; fixnums, and the inner one, of an argument nothing is known of, stays
;; generic.
(progn
  (defun inferred-the (x y) (+ (the fixnum (+ x 1)) (the fixnum y)))
  (and (inferred-mentions 'inferred-the "ADD_FIXNUMS")
       (inferred-mentions 'inferred-the "ADD")
       (eql (inferred-the 4 10) 15)))

;; Single-float arithmetic on a declared single-float, with an integer
;; constant taken as its float.
(progn
  (defun inferred-float (x)
    (declare (type single-float x))
    (+ (* x x) (* 2 x) 1))
  (and (inferred-mentions 'inferred-float "MUL_SINGLE_FLOATS")
       (inferred-mentions 'inferred-float "ADD_SINGLE_FLOATS")
       (not (inferred-mentions 'inferred-float "MUL"))
       (not (inferred-mentions 'inferred-float "ADD"))
       (eql (inferred-float 1.5) 6.25)))

;; A variable nothing assigns has the type of its initial value: y is an
;; integer from 1 to 1001, so its square is a fixnum product.
(progn
  (defun inferred-let (x)
    (declare (type (integer 0 1000) x))
    (let ((y (+ x 1)))
      (* y y)))
  (defun inferred-let-assigned (x)
    (declare (type (integer 0 1000) x))
    (let ((y (+ x 1)))
      (setq y (car (list y)))
      (* y y)))
  (and (inferred-mentions 'inferred-let "MUL_FIXNUMS")
       (inferred-mentions 'inferred-let-assigned "MUL")
       (not (inferred-mentions 'inferred-let-assigned "MUL_FIXNUMS"))
       (eql (inferred-let 9) 100)
       (eql (inferred-let-assigned 9) 100)))

;; A `typep` test narrows the variable it tests in the branch it guards.
(progn
  (defun inferred-narrow (x)
    (if (typep x 'fixnum)
        (+ x 1)
        (if (typep x 'single-float)
            (* x 2.0)
            (list x))))
  (and (inferred-mentions 'inferred-narrow "ADD_FIXNUMS")
       (inferred-mentions 'inferred-narrow "MUL_SINGLE_FLOATS")
       (eql (inferred-narrow 41) 42)
       (eql (inferred-narrow 1.25) 2.5)
       (equal (inferred-narrow "text") '("text"))))

;; With ext:*derive-function-types* on, a call to a compiled global
;; function has the result type derived for it. The result is checked,
;; so a callee redefined to return something else signals.
(progn (setq ext:*derive-function-types* t) t)
(progn
  (defun inferred-callee (x)
    (declare (type (integer 0 1000) x))
    (* x 2))
  (compile 'inferred-callee)
  (defun inferred-caller (y) (+ (inferred-callee y) 1))
  (and (inferred-mentions 'inferred-caller "ADD_FIXNUMS")
       (eql (inferred-caller 5) 11)))
(progn
  (compile 'inferred-caller)
  (defun inferred-callee (x) (declare (ignore x)) 1.5)
  (eq (handler-case (inferred-caller 5) (type-error () :signaled)) :signaled))
(progn (setq ext:*derive-function-types* nil) t)
(progn
  (defun inferred-callee-off (x)
    (declare (type (integer 0 1000) x))
    (* x 2))
  (compile 'inferred-callee-off)
  (defun inferred-caller-off (y) (+ (inferred-callee-off y) 1))
  (and (inferred-mentions 'inferred-caller-off "ADD")
       (not (inferred-mentions 'inferred-caller-off "ADD_FIXNUMS"))))

;; Values nothing is known of go through the instructions that dispatch
;; on their types, and give what the standard functions give.
(progn
  (defun inferred-boxed (x y) (+ (* x y) 1))
  (and (inferred-mentions 'inferred-boxed "MUL")
       (inferred-mentions 'inferred-boxed "ADD")
       (not (inferred-mentions 'inferred-boxed "MUL_FIXNUMS"))
       (not (inferred-mentions 'inferred-boxed "ADD_FIXNUMS"))
       (not (inferred-mentions 'inferred-boxed "MUL_SINGLE_FLOATS"))
       (eql (inferred-boxed 3 4) 13)
       (eql (inferred-boxed 1.5 2.0) 4.0)
       (eql (inferred-boxed 1/2 1/3) 7/6)
       (eql (inferred-boxed most-positive-fixnum 2) (1+ (* 2 most-positive-fixnum)))))
