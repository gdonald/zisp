;; Every form here must evaluate to T.
;;
;; Zig expressions evaluated at Zig compile time and read back as Lisp
;; forms. The test binds zig:*zig-cache-directory* to a fresh directory
;; before these forms run.

(progn (use-package '("ZISP-FFI" "ZISP-ZIG")) t)

(eql (comptime-eval "std.math.maxInt(i32)") 2147483647)

;; Each kind of value prints as the Lisp form the design gives it.
(equal (comptime-eval ".{ true, false, null, .little, \"a\\\"b\", .{ .count = 2, .max_depth = 3 }, [_]u8{ 1, 2 } }")
       '(t nil nil :little "a\"b" (:count 2 :max-depth 3) (1 2)))

;; A type prints as its description.
(equal (comptime-eval ".{ i32, u8, f64, bool, *u8, ?*u8 }")
       '((:signed 32) (:unsigned 8) (:float 64) :bool :pointer :pointer))

;; A macro calls into Zig while expanding.
(progn
  (defmacro int-max (bits)
    (comptime-eval (format nil "std.math.maxInt(i~d)" bits)))
  (and (eql (macroexpand-1 '(int-max 16)) 32767)
       (eql (int-max 8) 127)))

;; An imported Zig file is reachable under its name.
(eql (comptime-eval "limits.retry_limit * 2" :imports '(("limits" "tests/zig-fixtures/limits.zig")))
     10)

;; A Zig struct type becomes a C structure with Zig's layout.
(equal (macroexpand-1 '(define-cstruct-from-zig timespec "std.c.timespec"))
       '(defcstruct timespec (sec :int64) (nsec :int64)))
(progn
  (define-cstruct-from-zig header "limits.Header" :imports (("limits" "tests/zig-fixtures/limits.zig")))
  (and (equal (mapcar (lambda (field) (foreign-slot-offset 'header field)) (foreign-slot-names 'header))
              '(0 4 8))
       (eql (foreign-type-size '(:struct header)) 12)))

;; A field type with no C type here is refused, naming the field.
(handler-case (progn (macroexpand-1 '(define-cstruct-from-zig nested "struct { inner: struct { a: u8 } }")) nil)
  (error (condition) (and (search "INNER" (princ-to-string condition)) t)))

;; A field Zig places where the C rules would not is refused.
(handler-case (progn (macroexpand-1 '(define-cstruct-from-zig aligned "extern struct { a: u8, b: u8 align(4) }")) nil)
  (error (condition) (and (search "offset" (princ-to-string condition)) t)))

;; A value with no Lisp form is a Zig compile error.
(handler-case (progn (comptime-eval "std.builtin.Endian") nil)
  (zig-comptime-error (condition)
    (and (search "no Lisp form" (zig-error-output condition))
         (eql (zig-error-exit-code condition) 1))))

;; A repeated expression is answered from the cache without running Zig.
(let ((*zig-program* "/nonexistent/zig"))
  (eql (comptime-eval "std.math.maxInt(i32)") 2147483647))

;; A Zig that cannot be started signals zig-not-found.
(let ((*zig-program* "/nonexistent/zig"))
  (handler-case (progn (comptime-eval "std.math.maxInt(i31)") nil)
    (zig-not-found () t)))

;; The natives under comptime-eval.
(multiple-value-bind (code output errors)
    (cl::%run-program "/bin/sh" '("-c" "printf out; printf err >&2; exit 3") ".")
  (and (eql code 3) (equal output "out") (equal errors "err")))
(eql (cl::%run-program "/bin/sh" '("-c" "kill -9 $$") ".") 137)
(multiple-value-bind (code output reason) (cl::%run-program "/nonexistent/program" nil ".")
  (and (null code) (null output) (stringp reason)))
(handler-case (progn (cl::%run-program "/bin/sh" '("-c" . "exit 0") ".") nil) (type-error () t))
(handler-case (progn (cl::%run-program 5 nil ".") nil) (type-error () t))
(handler-case (progn (cl::%run-program "/bin/sh" nil) nil) (program-error () t))
(and (stringp (cl::%getenv "HOME")) (null (cl::%getenv "ZISP_VARIABLE_NO_TEST_SETS")))
(handler-case (progn (cl::%getenv) nil) (program-error () t))
(equal (cl::%sha256-hex "abc") "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(handler-case (progn (cl::%sha256-hex) nil) (program-error () t))
(and (search "pub fn print" (cl::%zig-printer-source)) t)
(handler-case (progn (cl::%zig-printer-source 1) nil) (program-error () t))

;; Zig extern structs from Lisp structures, compiled by zig build-obj.
(progn
  (defstruct point x y)
  (defstruct sample-record
    (count 0 :type (signed-byte 32))
    (total 0 :type fixnum)
    (ratio 0.0 :type single-float)
    (scale 0d0 :type double-float)
    (handle nil :type foreign-pointer)
    (flags 0 :type (unsigned-byte 16)))
  (defstruct (keyword-slots (:conc-name keyword-slots-)) (error 0 :type (unsigned-byte 8)) (fn 0 :type (unsigned-byte 8)))
  (let ((directory (namestring *zig-cache-directory*)))
    (write-zig-structs (concatenate 'string directory "shapes.zig") 'point 'sample-record 'keyword-slots)
    (and (eql (cl::%run-program "zig" '("build-obj" "--cache-dir" "zig-cache" "shapes.zig" "-femit-bin=shapes.o")
                            directory)
              0)
         (probe-file (concatenate 'string directory "shapes.o"))
         t)))
(equal (extern-struct-source 'point)
       "pub const Value = u64;

pub const Point = extern struct {
    x: Value,
    y: Value,
};
")
(equal (extern-struct-source 'sample-record)
       "pub const SampleRecord = extern struct {
    count: i32,
    total: i64,
    ratio: f32,
    scale: f64,
    handle: ?*anyopaque,
    flags: u16,
};
")
(and (search "@\"error\": u8," (extern-struct-source 'keyword-slots))
     (search "@\"fn\": u8," (extern-struct-source 'keyword-slots))
     t)

;; A slot type with no Zig type, and a name that is not a structure, are refused.
(progn
  (defstruct odd-width (bits 0 :type (signed-byte 12)))
  (handler-case (progn (extern-struct-source 'odd-width) nil)
    (error (condition) (and (search "BITS" (princ-to-string condition)) t))))
(progn
  (defstruct unbounded (count 0 :type integer))
  (handler-case (progn (extern-struct-source 'unbounded) nil)
    (error (condition) (and (search "COUNT" (princ-to-string condition)) t))))
(handler-case (progn (extern-struct-source 'no-such-structure) nil)
  (error (condition) (and (search "NO-SUCH-STRUCTURE" (princ-to-string condition)) t)))

;; Functions type-checked by Zig at macroexpansion time.
(handler-case (progn (macroexpand-1 '(defun-checked scale ((x (signed-byte 32)) (factor single-float)) (signed-byte 32)
                                       (* x factor)))
                     nil)
  (zig-type-error (condition)
    (and (eq (zig-type-error-function-name condition) 'scale)
         (equal (zig-type-error-form condition) '(* x factor))
         (equal (zig-type-error-message condition) "incompatible types: 'i32' and 'f32'"))))

;; Zig does not narrow implicitly.
(handler-case (progn (macroexpand-1 '(defun-checked narrow ((x (signed-byte 64))) (signed-byte 32) (+ x 1))) nil)
  (zig-type-error (condition)
    (and (equal (zig-type-error-form condition) '(+ x 1))
         (search "expected type 'i32', found 'i64'" (zig-type-error-message condition))
         t)))

;; An accepted function is a plain defun with the declared types.
(equal (macroexpand-1 '(defun-checked sum-squares ((x fixnum) (y fixnum)) fixnum
                         (+ (* x x) (* y y))))
       '(progn
         (eval-when (:compile-toplevel :load-toplevel :execute)
           (setf (gethash 'sum-squares cl::*%checked-functions*) '(("i61" "i61") "i61")))
         (defun sum-squares (x y)
           (declare (type fixnum x) (type fixnum y))
           (the fixnum (progn (+ (* x x) (* y y)))))))
(progn
  (defun-checked sum-squares ((x fixnum) (y fixnum)) fixnum
    (+ (* x x) (* y y)))
  (eql (sum-squares 3 4) 25))

;; Checked functions call each other and themselves.
(progn
  (defun-checked distance-squared ((a fixnum) (b fixnum)) fixnum
    (if (> a 0) (sum-squares a b) (- (sum-squares b a))))
  (defun-checked factorial ((n fixnum)) fixnum
    (if (<= n 1) 1 (* n (factorial (- n 1)))))
  (and (eql (distance-squared 1 2) 5)
       (eql (distance-squared -1 2) -5)
       (eql (factorial 10) 3628800)))
(handler-case (progn (macroexpand-1 '(defun-checked wrong-call ((x single-float)) fixnum (sum-squares x x))) nil)
  (zig-type-error (condition) (equal (zig-type-error-form condition) '(sum-squares x x))))

;; let, truncate, the, unary minus, float literals and earlier body forms.
(progn
  (defun-checked mixed ((total (signed-byte 32)) (count (signed-byte 32)) (ratio single-float)) single-float
    (- total count)
    (let ((average (truncate total count))
          (unused 1))
      (let ((average (the (signed-byte 32) (+ average 1)))
            (scaled (* ratio 2.5)))
        (if (= average 0) (- scaled) (* scaled (+ 1.0 (let ((half 0.5)) half)))))))
  (and (eql (mixed 10 5 1.0) 3.75)
       (eql (mixed -5 5 2.0) -5.0)))

;; A test that is not a bool is rejected, as Zig rejects it.
(handler-case (progn (macroexpand-1 '(defun-checked truthy ((x fixnum)) fixnum (if x 1 2))) nil)
  (zig-type-error (condition)
    (and (search "expected type 'bool'" (zig-type-error-message condition)) t)))

;; A form outside the translated subset, and a type with no Zig type, are refused.
(handler-case (progn (macroexpand-1 '(defun-checked looping ((x fixnum)) fixnum (loop (return x)))) nil)
  (zig-type-error () nil)
  (error (condition) (and (search "LOOP" (princ-to-string condition)) t)))
(handler-case (progn (macroexpand-1 '(defun-checked unbounded ((x integer)) fixnum x)) nil)
  (error (condition) (and (search "parameter X" (princ-to-string condition)) t)))

;; An accepted function is checked once, then answered from the cache.
(let ((*zig-program* "/nonexistent/zig"))
  (defun-checked sum-squares ((x fixnum) (y fixnum)) fixnum
    (+ (* x x) (* y y)))
  t)
