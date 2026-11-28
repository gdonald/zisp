;; The environment functions, the standard symbols and the package rules.
;; Every form here must evaluate to T.

;; COMMON-LISP exports the standard symbols and no others.
(let ((n 0)) (do-external-symbols (s :cl) (declare (ignore s)) (incf n)) (= n 978))
(null (nth-value 1 (find-symbol "%STRUCTURE-P" "CL-USER")))
(eq (nth-value 1 (find-symbol "GC" "EXT")) :external)

;; Universal time round-trips, counting from 1900 in UTC.
(= (encode-universal-time 0 0 0 1 1 2000 0) 3155673600)
(equal (multiple-value-list (decode-universal-time (encode-universal-time 5 4 3 2 1 2020 0) 0))
       '(5 4 3 2 1 2020 3 nil 0))
(integerp (get-universal-time))

;; Text into characters and integers.
(equal (multiple-value-list (parse-integer " -12 ")) '(-12 5))
(equal (multiple-value-list (parse-integer "ff" :radix 16)) '(255 2))
(equal (multiple-value-list (parse-integer "12ab" :junk-allowed t)) '(12 2))
(handler-case (progn (parse-integer "x") nil) (parse-error () t))
(eql (character "a") #\a)
(eql (character 'b) #\B)

;; A character names a package.
(progn (unless (find-package "Q") (make-package "Q" :use nil))
       (eq (find-package #\Q) (find-package "Q")))

;; The standard macros zisp runs as special operators have macro
;; definitions too.
(and (macro-function 'defun) (not (special-operator-p 'defun)))
(equal (funcall (macro-function 'lambda) '(lambda (x) x) nil) '(function (lambda (x) x)))
(equal (multiple-value-list (funcall #'macroexpand-1 '(no-such-macro 1))) '((no-such-macro 1) nil))

;; The counter in gensym names is *gensym-counter*, any size.
(let ((*gensym-counter* 12345)) (gensym) (= *gensym-counter* 12346))
(string= (let ((*gensym-counter* (expt 10 30))) (symbol-name (gensym)))
         "G1000000000000000000000000000000")
(handler-case (progn (gensym t) nil)
  (type-error (c) (equal (type-error-expected-type c) '(or string unsigned-byte))))
(and (typep 5 'unsigned-byte) (not (typep -5 'unsigned-byte)) (typep -5 'signed-byte))

;; apropos finds symbols by name, ignoring case.
(not (null (member 'car (apropos-list "car" :cl))))

;; trace writes each call and its values, and untrace puts the function back.
(progn
  (defun environment-corpus-square (x) (* x x))
  (trace environment-corpus-square)
  (let ((out (with-output-to-string (*trace-output*) (environment-corpus-square 3))))
    (untrace environment-corpus-square)
    (and (search "called with (3)" out)
         (search "returned 9" out)
         (string= "" (with-output-to-string (*trace-output*) (environment-corpus-square 4))))))
(not (null (search "Evaluation took" (with-output-to-string (*trace-output*) (time (+ 1 2))))))

;; Synonym, concatenated and echo streams.
(let ((s (make-string-output-stream)))
  (let ((*standard-output* s))
    (write-string "x" (make-synonym-stream '*standard-output*)))
  (string= (get-output-stream-string s) "x"))
(with-input-from-string (a "1 ")
  (with-input-from-string (b "2")
    (let ((both (make-concatenated-stream a b)))
      (and (eql (read both) 1) (eql (read both) 2)))))
(let ((in (make-string-input-stream "x")) (out (make-string-output-stream)))
  (let ((echo (make-echo-stream in out)))
    (and (eq (echo-stream-input-stream echo) in)
         (eq (echo-stream-output-stream echo) out))))
(eq (stream-external-format (make-string-input-stream "")) :utf-8)

(and (pathname-match-p "a/b.lisp" "a/*.lisp")
     (not (pathname-match-p "a/b.txt" "a/*.lisp")))

(stringp (lisp-implementation-type))
(stringp (machine-type))

(let ((*modules* *modules*))
  (provide "CORPUS-MODULE")
  (and (null (require "CORPUS-MODULE"))
       (handler-case (progn (require "CORPUS-MISSING-MODULE") nil)
         (error () t))))
(handler-case (progn (funcall 'when t) nil)
  (undefined-function (condition) (eq (cell-error-name condition) 'when)))
(handler-case (progn (apply 'defconstant '(x 10)) nil)
  (undefined-function () t))
