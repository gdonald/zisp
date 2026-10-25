;; Every form here must evaluate to T.
;;
;; A type declaration reaches the compiled code: arithmetic on values
;; declared fixnums uses instructions that do not check them, and the
;; declared types are checked where values are bound and assigned.

(progn
  (defun type-listing (function)
    (with-output-to-string (*standard-output*) (disassemble function)))
  (defun type-mentions (function text)
    (let ((listing (type-listing function)))
      (not (null (search text listing :end2 (search "Constants:" listing))))))
  (defun type-line (op)
    (format nil "  ~a~%" op))
  t)

;; A fixnum declaration turns `+` into the add that does not check.
(progn
  (defun type-declared-add (x) (declare (type fixnum x)) (+ x 1))
  (defun type-undeclared-add (x) (+ x 1))
  (and (type-mentions 'type-declared-add "ADD_FIXNUMS")
       (not (type-mentions 'type-declared-add (type-line "ADD")))
       (type-mentions 'type-undeclared-add (type-line "ADD"))
       (not (type-mentions 'type-undeclared-add "ADD_FIXNUMS"))))

;; The short form of the declaration and `the` do the same.
(progn
  (defun type-short-form (x y) (declare (fixnum x y)) (< x y))
  (defun type-the (x) (1- (the fixnum x)))
  (and (type-mentions 'type-short-form "LESS_FIXNUMS")
       (type-mentions 'type-the "DEC_FIXNUM")))

;; A loop variable given a type declares it.
(progn
  (defun type-loop (n) (loop for i fixnum from 0 below n sum (1+ i)))
  (and (type-mentions 'type-loop "INC_FIXNUM")
       (eql (type-loop 10) 55)))

;; The sum of two fixnums still overflows into a bignum.
(progn
  (defun type-overflow (x) (declare (fixnum x)) (+ x 1))
  (compile 'type-overflow)
  (eql (type-overflow most-positive-fixnum) (1+ most-positive-fixnum)))

;; A declared type is checked where the variable is bound and where it is
;; assigned.
(progn
  (defun type-bound (x) (declare (fixnum x)) x)
  (defun type-assigned (x) (let ((y 0)) (declare (fixnum y)) (setq y x) y))
  (compile 'type-bound)
  (compile 'type-assigned)
  (and (eq (handler-case (type-bound "text") (type-error (c) (type-error-expected-type c))) 'fixnum)
       (eq (handler-case (type-assigned 'a) (type-error (c) (type-error-datum c))) 'a)
       (eql (type-assigned 5) 5)))
