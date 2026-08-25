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

;; Escaping is what `prin1` and `princ` differ over, and the variable is
;; what says so.
(check (string= "\"hi\"" (prin1-to-string "hi")))
(check (string= "hi" (let ((*print-escape* nil)) (prin1-to-string "hi"))))
(check (string= "hi" (princ-to-string "hi")))

;; A `princ` that must read back is escaped anyway.
(check (string= "\"hi\"" (let ((*print-readably* t)) (princ-to-string "hi"))))

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
