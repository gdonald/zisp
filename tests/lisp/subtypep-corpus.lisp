;; `subtypep` over every kind of type specifier, and the class objects
;; `find-class` hands out.

(progn
  (defun answer (type-1 type-2) (multiple-value-list (subtypep type-1 type-2)))
  t)

;; --- combinations ---

(equal (answer '(and (or symbol (integer 0 15)) (or symbol (integer 10 25)))
               '(or symbol (integer 10 15)))
       '(t t))
(equal (answer '(or symbol (integer 10 15))
               '(and (or symbol (integer 0 15)) (or symbol (integer 10 25))))
       '(t t))
(equal (answer 't '(or (not (real 0 10)) (not (real -100 -50)))) '(t t))
(equal (answer 'atom '(not cons)) '(t t))
(equal (answer '(and) 't) '(t t))
(equal (answer 't '(and)) '(t t))
(equal (answer '(or) 'nil) '(t t))

;; --- numbers ---

(equal (answer '(integer 0 (5)) '(integer 0 4)) '(t t))
(equal (answer '(rational 1/3 1/2) '(real 0 1)) '(t t))
(equal (answer '(real 0 1) '(rational 0 1)) '(nil t))
(equal (answer 'bignum '(not fixnum)) '(t t))
(equal (answer '(and integer (not fixnum)) 'bignum) '(t t))
(equal (answer '(mod 256) '(unsigned-byte 8)) '(t t))
(equal (answer '(signed-byte 8) '(integer -128 127)) '(t t))
(equal (answer 'ratio '(not integer)) '(t t))
(equal (answer '(and ratio (rational 1 1)) 'nil) '(t t))
(equal (answer '(single-float 0.0 (10.0)) '(single-float 0.0 10.0)) '(t t))
(equal (answer '(single-float 0.0) '(or (single-float (0.0)) (member 0.0))) '(nil t))
(equal (answer '(eql -0.0) '(single-float 0.0 0.0)) '(t t))
(equal (answer '(eql -0.0) '(eql 0.0)) '(nil t))
(equal (answer 'double-float 'long-float) '(t t))
(equal (answer 'float '(or single-float double-float)) '(t t))

;; --- complexes ---

(equal (answer '(complex (integer 0 5)) '(complex rational)) '(t t))
(equal (answer '(complex single-float) '(complex float)) '(t t))
(equal (answer '(complex double-float) '(complex single-float)) '(nil t))
(equal (answer '(complex) 'complex) '(t t))
(equal (answer 'complex 'number) '(t t))
(eq (upgraded-complex-part-type 'bit) 'rational)
(eq (upgraded-complex-part-type '(float 0.0 1.0)) 'float)
(eq (upgraded-complex-part-type '(or integer single-float)) 'real)

;; --- characters ---

(equal (answer 'standard-char 'base-char) '(t t))
(equal (answer '(member #\a #\Space) 'standard-char) '(t t))
(equal (answer 'extended-char '(and character (not base-char))) '(t t))
(equal (answer '(not base-char) '(not base-char)) '(t t))

;; --- symbols and members ---

(equal (answer 'null '(member nil t)) '(t t))
(equal (answer 'boolean 'symbol) '(t t))
(equal (answer '(member :a :b) 'keyword) '(t t))
(equal (answer '(member a b 10) 'symbol) '(nil t))
(equal (answer '(member) 'nil) '(t t))
(let ((object (list 'a)))
  (equal (answer `(member 10 ,object) `(member ,object 10 20)) '(t t)))
(equal (answer `(member ,(list 'a)) `(member ,(list 'a))) '(nil t))

;; --- conses ---

(equal (answer '(cons nil) 'nil) '(t t))
(equal (answer '(and (cons symbol *) (cons * symbol)) '(cons symbol symbol)) '(t t))
(equal (answer '(and cons (not (cons symbol symbol)))
               '(or (cons (not symbol) *) (cons * (not symbol))))
       '(t t))
(equal (answer '(cons (or integer symbol) (or integer symbol))
               '(or (cons integer symbol) (cons symbol integer)))
       '(nil t))
(equal (answer `(eql ,(list 'a)) '(cons symbol null)) '(t t))

;; --- arrays ---

(equal (answer '(array t (* 10 * * *)) '(array t 5)) '(t t))
(equal (answer '(and (array * (* 10)) (array * (3 *))) '(array * (3 10))) '(t t))
(equal (answer '(array t (1)) '(array t nil)) '(nil t))
(equal (answer 'simple-string '(simple-array character (*))) '(t t))
(equal (answer 'string '(vector character)) '(t t))
(equal (answer 'simple-vector '(simple-array t (*))) '(t t))
(equal (answer 'bit-vector '(vector bit)) '(t t))
(equal (answer '(vector t 3) 'sequence) '(t t))
(equal (answer '(simple-bit-vector 4) '(bit-vector *)) '(t t))
(equal (answer '(string 3) '(base-string 3)) '(t t))
(equal (answer '(simple-vector 2) '(vector * 2)) '(t t))
(equal (answer `(eql ,(make-array 2)) '(simple-vector 2)) '(t t))
(equal (answer `(eql ,(make-array 2 :adjustable t)) 'simple-array) '(nil t))
(equal (answer `(eql ,(make-array 3 :element-type 'bit)) 'bit-vector) '(t t))
(equal (answer `(eql ,(make-array 3 :element-type '(unsigned-byte 8))) '(vector (unsigned-byte 8))) '(t t))
(equal (answer `(eql ,(make-string 2)) 'string) '(t t))
(eq (upgraded-array-element-type '(integer 0 1)) 'bit)
(equal (upgraded-array-element-type '(integer 0 200)) '(unsigned-byte 8))
(eq (upgraded-array-element-type 'base-char) 'character)
(eq (upgraded-array-element-type 'fixnum) t)

;; --- functions ---

(equal (answer '(function (t) integer) '(function (t) real)) '(t t))
(equal (answer '(function (t) real) '(function (t) integer)) '(nil t))
(equal (answer '(function (integer) t) '(function (t) t)) '(nil t))
(equal (answer '(function (t) t) 'function) '(t t))
(equal (answer 'function '(function (t) t)) '(nil t))
(equal (answer '(function (&optional t) t) '(function (&optional t) t)) '(t t))
(equal (answer '(function (t) (values t)) '(function (t) (values t))) '(t t))
(equal (answer '(function (t t) t) '(function (t) t)) '(nil t))
(equal (answer '(function * t) '(function (t) t)) '(nil t))
(equal (answer '(function (t)) '(function (t) *)) '(t t))
(equal (answer `(eql ,#'car) 'function) '(t t))
(equal (answer `(eql ,#'car) '(not (function (t) t))) '(t t))
(equal (answer 'generic-function 'function) '(t t))
(equal (answer 'standard-generic-function 'standard-object) '(t t))
(equal (answer '(and function standard-object) 'generic-function) '(t t))
(equal (answer 'compiled-function 'function) '(t t))

;; --- predicates ---

(equal (answer '(satisfies symbolp) 'symbol) '(t t))
(equal (answer '(satisfies oddp) 'integer) '(nil nil))
(equal (answer '(member 1 3 5) '(satisfies oddp)) '(t t))
(equal (answer '(member 1 2 3) '(satisfies oddp)) '(nil t))
(equal (answer '(and (satisfies oddp) (member 1 2)) '(eql 1)) '(t t))
(equal (answer '(and (satisfies plusp) (rational -1/2 -1/2)) 'nil) '(t t))
(equal (answer '(and (satisfies plusp) (member 0.0 -0.0 1.5d0)) 'double-float) '(t t))
(equal (answer '(and (satisfies plusp) (member #\a)) 'nil) '(nil nil))
(equal (answer '(and (satisfies oddp) (integer 0 1000)) 'nil) '(nil nil))
(equal (answer '(and (satisfies oddp) (integer 0)) 'nil) '(nil nil))
(equal (answer '(and (satisfies oddp) (rational 1/3 1/2)) 'nil) '(nil nil))
(equal (answer '(and (satisfies plusp) (single-float 1.0 2.0)) 'nil) '(nil nil))
(equal (answer '(and (satisfies symbolp) (cons symbol)) 'nil) '(t t))
(equal (answer '(and (satisfies oddp) (not integer)) 'nil) '(nil nil))
(equal (answer '(and (satisfies oddp) (member 1 a)) '(eql 1)) '(nil nil))
(equal (answer 'no-such-type 'integer) '(nil nil))
(equal (answer '(no-such-type 1) 'integer) '(nil nil))
(equal (answer 3 'integer) '(nil nil))

;; --- classes, structures and conditions ---

(equal (answer 'error 'condition) '(t t))
(equal (answer 'condition 'error) '(nil t))
(equal (answer '(and error warning) 'nil) '(t t))
(equal (answer 'simple-error '(and simple-condition error)) '(t t))
(progn
  (define-condition corpus-error (error) ())
  (and (equal (answer 'corpus-error 'error) '(t t))
       (equal (answer 'error '(or corpus-error (not corpus-error))) '(t t))
       (equal (answer `(eql ,(make-condition 'corpus-error)) 'corpus-error) '(t t))))
(progn
  (defstruct corpus-point x y)
  (and (equal (answer 'corpus-point 'structure-object) '(t t))
       (equal (answer 'structure-object 'corpus-point) '(nil t))
       (equal (answer `(eql ,(make-corpus-point)) 'corpus-point) '(t t))))
(equal (answer 'file-stream 'stream) '(t t))
(equal (answer 'string-stream 'file-stream) '(nil t))
(equal (answer 'echo-stream '(or two-way-stream synonym-stream)) '(nil t))
(equal (answer `(eql ,(make-string-output-stream)) 'string-stream) '(t t))
(equal (answer `(eql ,*standard-output*) '(or file-stream string-stream)) '(nil t))
(equal (answer 'built-in-class 'class) '(t t))
(equal (answer 'standard-class 'standard-object) '(t t))
(equal (answer 'method 'standard-object) '(t t))
(equal (answer 'standard-method 'method) '(t t))
(equal (answer 'method-combination 'standard-object) '(t t))
(equal (answer 'structure-class 'class) '(t t))
(equal (answer (find-class 'integer) 'rational) '(t t))
(equal (answer `(eql ,(find-class 'integer)) 'built-in-class) '(t t))
(equal (answer `(eql ,(find-class 'error)) '(and class (not built-in-class))) '(t t))
(equal (answer `(eql ,(make-hash-table)) 'hash-table) '(t t))
(equal (answer `(eql ,(find-package "COMMON-LISP")) 'package) '(t t))
(equal (answer `(eql ,(pathname "a.txt")) '(and pathname (not logical-pathname))) '(t t))
(equal (answer `(eql ,(make-random-state)) 'random-state) '(t t))
(equal (answer `(eql ,*readtable*) 'readtable) '(t t))
(equal (answer `(eql #c(1 2)) '(complex rational)) '(t t))
(equal (answer `(eql #c(1.0 2.0)) '(complex single-float)) '(t t))
(equal (answer `(eql #c(1.0d0 2.0d0)) '(complex double-float)) '(t t))
(equal (answer `(eql ,(code-char 955)) 'extended-char) '(t t))

;; --- deftype ---

(progn
  (deftype corpus-small () '(integer 0 9))
  (deftype corpus-range (low high) `(integer ,low ,high))
  (and (equal (answer 'corpus-small '(corpus-range 0 20)) '(t t))
       (equal (answer '(corpus-range 5 30) 'corpus-small) '(nil t))))

;; --- find-class ---

(eq (find-class 'symbol) (find-class 'symbol))
(eq (find-class 'error) (find-condition-class 'error))
(null (find-class 'no-such-class nil))
(eq (find-class 'corpus-point) (find-class 'corpus-point))
(typep 'a (find-class 'symbol))
(not (typep 10 (find-class 'symbol)))
(typep 'a `(or ,(find-class 'number) ,(find-class 'symbol)))
(typep (make-condition 'simple-error) (find-class 'error))
(not (typep (make-condition 'simple-warning) (find-class 'error)))
(typep (find-class 'symbol) 'class)
(typep (find-class 'symbol) 'built-in-class)
(not (typep (find-class 'error) 'built-in-class))
(not (typep 'a 'class))
(not (typep 'a 'built-in-class))
(eq (handler-case (find-class 'no-such-class) (error () :signaled)) :signaled)

;; --- typep on the stream and CLOS class names ---

(typep (make-string-output-stream) 'string-stream)
(not (typep (make-string-output-stream) 'file-stream))
(not (typep 'a 'string-stream))
(not (typep (make-string-output-stream) 'synonym-stream))
(not (typep #'car 'generic-function))
(not (typep 'a 'standard-object))
(typep #'car 'compiled-function)
(typep (lambda (x) x) 'compiled-function)
(not (typep 'a 'compiled-function))
