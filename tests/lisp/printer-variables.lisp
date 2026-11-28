;; The printer variables, and what binding them does to what comes out.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "printer check failed: ~s" ',form)))

;; What a name looks like when the reader would fold it back to itself.
(check (string= "FOO-BAR" (prin1-to-string 'foo-bar)))
(check (string= "foo-bar" (let ((*print-case* :downcase)) (prin1-to-string 'foo-bar))))
(check (string= "Foo-Bar" (let ((*print-case* :capitalize)) (prin1-to-string 'foo-bar))))

;; Escaping is what `prin1` and `princ` differ over. `prin1` escapes
;; whatever the variable says, and `write` does what it says.
(check (string= "\"hi\"" (prin1-to-string "hi")))
(check (string= "\"hi\"" (let ((*print-escape* nil)) (prin1-to-string "hi"))))
(check (string= "hi" (let ((*print-escape* nil)) (write-to-string "hi"))))
(check (string= "hi" (princ-to-string "hi")))

;; `princ` prints with `*print-readably*` off, whatever it was, and
;; `write` escapes what must read back.
(check (string= "hi" (let ((*print-readably* t)) (princ-to-string "hi"))))
(check (string= "hi" (let ((*print-readably* t)) (format nil "~a" "hi"))))
(check (string= "\"hi\"" (let ((*print-readably* t) (*print-escape* nil)) (write-to-string "hi"))))

;; Printing that must read back ignores the length and depth limits.
(check (string= "(1 (2 (3)))"
                (let ((*print-readably* t) (*print-level* 1) (*print-length* 1))
                  (prin1-to-string '(1 (2 (3)))))))
(check (string= "#2A((#\\a #\\a) (#\\a #\\a))"
                (let ((*print-readably* t) (*print-level* 0))
                  (prin1-to-string (make-array '(2 2) :initial-element #\a)))))

;; Integers print in the base asked for, with the radix marker where one
;; is wanted.
(check (string= "FF" (let ((*print-base* 16)) (prin1-to-string 255))))
(check (string= "#xFF" (let ((*print-base* 16) (*print-radix* t)) (prin1-to-string 255))))
(check (string= "1010" (let ((*print-base* 2)) (prin1-to-string 10))))

;; A structure deeper than the level asked for stands in as `#`, and
;; what is past the length as `...`.
(check (string= "(1 # 4)" (let ((*print-level* 1)) (prin1-to-string '(1 (2 3) 4)))))
(check (string= "#" (let ((*print-level* 0)) (prin1-to-string '(1 2)))))
(check (string= "5" (let ((*print-level* 0)) (prin1-to-string 5))))
(check (string= "(1 2 3 ...)" (let ((*print-length* 3)) (prin1-to-string '(1 2 3 4 5)))))
(check (string= "#(1 2 ...)" (let ((*print-length* 2)) (prin1-to-string #(1 2 3)))))

;; An uninterned symbol says so, unless it is asked not to.
(check (string= "#:G" (prin1-to-string (make-symbol "G"))))
(check (string= "G" (let ((*print-gensym* nil)) (prin1-to-string (make-symbol "G")))))

;; `format` prints through the same variables.
(check (string= "FF" (let ((*print-base* 16)) (format nil "~s" 255))))
(check (string= "foo" (let ((*print-case* :downcase)) (format nil "~s" 'foo))))

;; What the standard says each of them holds, whatever the program had
;; set them to.
(check (string= "\"hi\"" (let ((*print-escape* nil) (*print-base* 8))
                           (with-standard-io-syntax (prin1-to-string "hi")))))
(check (string= "255" (let ((*print-base* 8))
                        (with-standard-io-syntax (prin1-to-string 255)))))

;; A bignum prints in any base, with the digit case a fixnum uses, and a
;; base whose digits straddle two limbs gets every digit right.
(check (string= "3FFFFFFFFFFFFFFFFF" (let ((*print-base* 16)) (prin1-to-string (1- (expt 2 70))))))
(check (string= "VVVVVVVVVVVVVV" (let ((*print-base* 32)) (prin1-to-string (1- (expt 2 70))))))
(check (string= (concatenate 'string "1" (make-string 100 :initial-element #\0))
                (let ((*print-base* 8)) (prin1-to-string (expt 8 100)))))
(check (string= (concatenate 'string "#o-" (make-string 200 :initial-element #\7))
                (let ((*print-base* 8) (*print-radix* t)) (prin1-to-string (- 1 (expt 8 200))))))
(check (string= "-100000000000000000000000000000000"
                (let ((*print-base* 16)) (prin1-to-string (- (expt 2 128))))))
(check (string= "7B6A43A7EF901FD29F05F9E837D8" (let ((*print-base* 16)) (prin1-to-string (1- (expt 3 70))))))

;; A symbol is cased by *print-case* and the readtable's case together.
(check (string= "xYZ" (let ((*readtable* (copy-readtable nil)))
                        (setf (readtable-case *readtable*) :downcase)
                        (let ((*print-case* :downcase)) (princ-to-string '|xYZ|)))))
(check (string= "foo" (let ((*readtable* (copy-readtable nil)))
                        (setf (readtable-case *readtable*) :invert)
                        (princ-to-string 'foo))))
(check (string= "|foo|" (prin1-to-string '|foo|)))
(check (string= "|FF|" (let ((*print-base* 16)) (prin1-to-string 'ff))))

;; Printing that must read back is for the standard readtable, and what
;; cannot read back signals print-not-readable.
(check (string= ":|foo|" (let ((*readtable* (copy-readtable nil)))
                           (setf (readtable-case *readtable*) :preserve)
                           (write-to-string :|foo| :readably t))))
(check (handler-case (progn (write-to-string #'car :readably t) nil)
         (print-not-readable (c) (eq (print-not-readable-object c) #'car))))
(check (handler-case (progn (write-to-string (make-array 2 :element-type 'bit :initial-element 1 :adjustable t :fill-pointer 2) :readably t) t)
         (print-not-readable () nil)))
(check (handler-case (progn (write-to-string (make-array '(0 3)) :readably t) nil)
         (print-not-readable () t)))
(check (let* ((state (make-random-state))
              (copy (read-from-string (write-to-string state :readably t))))
         (= (random 1000000 state) (random 1000000 copy))))

;; *print-array* off prints an array as #<...>, and a space prints as
;; itself.
(check (string= "#<" (subseq (write-to-string #(1 2) :array nil) 0 2)))
(check (string= "#\\ " (prin1-to-string #\Space)))

;; Each list of a multidimensional array's contents is a level, and a
;; string or bit vector is never abbreviated.
(check (string= "#2A((a ...) ...)" (write-to-string #2a((a b) (c d)) :length 1 :case :downcase)))
(check (string= "#2A(#)" (write-to-string #2a((a)) :level 1)))
(check (string= "(# #*1101 \"abc\")" (write-to-string '(#(a) #*1101 "abc") :level 1)))
