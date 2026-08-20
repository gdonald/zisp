;; The type system: typep over atomic and compound specifiers, deftype,
;; and subtypep's two-value answer.
;;
;; Each top-level form is self-checking and evaluates to T.

;; --- atomic types, one case each ---

(typep nil 'null)
(typep '(1) 'cons)
(typep 'a 'symbol)
(typep 1 'fixnum)
(typep 1152921504606846976 'bignum)
(typep 5 'integer)
(typep 1/2 'ratio)
(typep 1.5 'float)
(typep "a" 'string)
(typep #(1 2) 'vector)
(typep (make-array '(2 2)) 'array)
(typep (make-hash-table) 'hash-table)
(typep #'car 'function)
(typep (find-package "COMMON-LISP") 'package)
(typep #p"/a/b" 'pathname)
(typep *standard-output* 'stream)
(typep #\a 'character)
(typep 5 't)
(not (typep 5 'nil))

;; The lattice puts each of those under the right heads.
(and (typep 5 'number) (typep 5 'real) (typep 5 'rational) (typep 5 'atom))
(and (typep nil 'list) (typep nil 'symbol) (typep nil 'boolean) (typep nil 'sequence))
(and (typep '(1) 'list) (typep '(1) 'sequence) (not (typep '(1) 'atom)))
(and (typep "a" 'vector) (typep "a" 'array) (typep "a" 'sequence))
(and (typep #C(1 2) 'complex) (typep #C(1 2) 'number) (not (typep #C(1 2) 'real)))

;; --- compound numeric types, six cases ---

(and (typep 5 '(integer 0 100)) (not (typep 200 '(integer 0 100))))
(and (typep 0.5 '(real * 1.0)) (not (typep 1.5 '(real * 1.0))))
(and (typep 200 '(unsigned-byte 8)) (not (typep 256 '(unsigned-byte 8)))
     (not (typep -1 '(unsigned-byte 8))))
(and (typep -300 '(signed-byte 16)) (typep 32767 '(signed-byte 16))
     (not (typep 32768 '(signed-byte 16))))
(and (typep 3 '(mod 5)) (not (typep 5 '(mod 5))) (not (typep -1 '(mod 5))))
;; An exclusive bound is written as a one-element list.
(and (typep 5 '(integer 0 (6))) (not (typep 6 '(integer 0 (6)))))

;; --- compound combinators, six cases ---

(and (typep 3 '(or string integer)) (not (typep 'a '(or string integer))))
(and (typep 3 '(and integer (satisfies oddp)))
     (not (typep 4 '(and integer (satisfies oddp)))))
(and (typep 3 '(not string)) (not (typep "a" '(not string))))
(and (typep 3 '(satisfies oddp)) (not (typep 4 '(satisfies oddp))))
(and (typep 'a '(member a b)) (not (typep 'c '(member a b))))
(and (typep 3 '(eql 3)) (not (typep 4 '(eql 3))))
;; Nesting: the combinators compose.
(and (typep 3 '(or (and integer (satisfies oddp)) string))
     (typep "x" '(or (and integer (satisfies oddp)) string))
     (not (typep 4 '(or (and integer (satisfies oddp)) string))))

;; --- cons and array specifiers ---

(and (typep '(1 . 2) '(cons integer integer))
     (not (typep '(1 . a) '(cons integer integer)))
     (typep '(1 . a) '(cons integer *)))
(and (typep #(1 2) '(vector t 2)) (not (typep #(1 2) '(vector t 3))))
(and (typep "abc" '(string 3)) (not (typep "abc" '(string 4))))
(and (typep (make-array '(2 3)) '(array t (2 3)))
     (not (typep (make-array '(2 3)) '(array t (3 2)))))

;; --- deftype, four cases ---

(progn (deftype small-number () '(integer 0 9)) (typep 5 'small-number))
(progn (deftype small-number () '(integer 0 9)) (not (typep 50 'small-number)))
;; A parameterized type takes its arguments from the specifier.
(progn (deftype ranged (low high) (list 'integer low high))
       (and (typep 5 '(ranged 0 9)) (not (typep 50 '(ranged 0 9)))))
;; One deftype composes with another.
(progn (deftype small-number () '(integer 0 9))
       (deftype small-or-text () '(or small-number string))
       (and (typep 5 'small-or-text) (typep "x" 'small-or-text)
            (not (typep 50 'small-or-text))))

;; --- subtypep over the atomic lattice, ten cases ---

(equal (multiple-value-list (subtypep 'integer 'number)) '(t t))
(equal (multiple-value-list (subtypep 'fixnum 'integer)) '(t t))
(equal (multiple-value-list (subtypep 'bignum 'integer)) '(t t))
(equal (multiple-value-list (subtypep 'null 'list)) '(t t))
(equal (multiple-value-list (subtypep 'null 'symbol)) '(t t))
(equal (multiple-value-list (subtypep 'string 'vector)) '(t t))
(equal (multiple-value-list (subtypep 'vector 'sequence)) '(t t))
(equal (multiple-value-list (subtypep 'integer 'string)) '(nil t))
(equal (multiple-value-list (subtypep 'number 'integer)) '(nil t))
(equal (multiple-value-list (subtypep 'nil 'integer)) '(t t))
(equal (multiple-value-list (subtypep 'integer t)) '(t t))

;; --- subtypep over numeric intervals, eight cases ---

(equal (multiple-value-list (subtypep '(integer 0 5) '(integer 0 10))) '(t t))
(equal (multiple-value-list (subtypep '(integer 0 15) '(integer 0 10))) '(nil t))
(equal (multiple-value-list (subtypep '(integer 2 5) '(integer 0 10))) '(t t))
(equal (multiple-value-list (subtypep '(integer 0 5) 'integer)) '(t t))
(equal (multiple-value-list (subtypep 'integer '(integer 0 5))) '(nil t))
(equal (multiple-value-list (subtypep '(unsigned-byte 8) '(integer 0 255))) '(t t))
(equal (multiple-value-list (subtypep '(mod 5) '(integer 0 4))) '(t t))
;; An exclusive bound is tighter than the inclusive one at the same value.
(equal (multiple-value-list (subtypep '(integer 0 (5)) '(integer 0 5))) '(t t))
(equal (multiple-value-list (subtypep '(integer 0 5) '(integer 0 (5)))) '(nil t))

;; --- subtypep over combinators, ten cases ---

(equal (multiple-value-list (subtypep 'integer '(or integer string))) '(t t))
(equal (multiple-value-list (subtypep '(or integer fixnum) 'number)) '(t t))
(equal (multiple-value-list (subtypep '(or integer string) 'number)) '(nil t))
(equal (multiple-value-list (subtypep 'string '(and vector sequence))) '(t t))
(equal (multiple-value-list (subtypep '(and integer string) 'integer)) '(t t))
(equal (multiple-value-list (subtypep 'string '(and vector integer))) '(nil t))
(equal (multiple-value-list (subtypep 'integer '(not string))) '(t t))
(equal (multiple-value-list (subtypep 'null '(or symbol list))) '(t t))
(equal (multiple-value-list (subtypep '(integer 0 5) '(or (integer 0 3) integer))) '(t t))
(equal (multiple-value-list (subtypep '(or (integer 0 5) (integer 6 9)) 'integer)) '(t t))

;; A question the lattice cannot settle comes back as "do not know"
;; rather than as a wrong answer.
(equal (multiple-value-list (subtypep 'integer '(not integer))) '(nil nil))
(equal (multiple-value-list (subtypep '(satisfies oddp) 'integer)) '(nil nil))

;; --- coerce ---

(and (= (coerce 1 'float) 1.0) (typep (coerce 1 'float) 'single-float))
(typep (coerce 1 'double-float) 'double-float)
(equal (coerce '(1 2) 'list) '(1 2))
(equal (concatenate 'list (coerce '(1 2) 'vector)) '(1 2))
(string= (coerce '(#\a #\b) 'string) "ab")
(eq (coerce 5 't) 5)

;; --- check-type ---

(null (check-type 5 integer))
(not (null (nth-value 1 (ignore-errors (check-type 5 string)))))
