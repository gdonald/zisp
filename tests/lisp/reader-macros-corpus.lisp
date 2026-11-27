;; Readtables, macro characters written in Lisp, and the functions that
;; read. Every form here must evaluate to T.

;; A macro function is called with the stream and the character, and the
;; reader carries on from where it leaves the stream.
(let ((*readtable* (copy-readtable)))
  (set-macro-character #\! (lambda (stream char)
                             (declare (ignore char))
                             (list 'not (read stream t nil t))))
  (equal (multiple-value-list (read-from-string "!x y")) '((not x) 3)))

;; One that returns no values reads nothing, the way a comment does.
(let ((*readtable* (copy-readtable)))
  (set-macro-character #\% (lambda (stream char)
                             (declare (ignore char))
                             (read-char stream)
                             (values)))
  (equal (read-from-string "(a %b c)") '(a c)))

;; A terminating macro character ends a token, a non-terminating one does not.
(let ((*readtable* (copy-readtable)))
  (set-macro-character #\$ (lambda (stream char) (declare (ignore stream char)) :dollar) t)
  (and (equal (multiple-value-list (get-macro-character #\$)) (list (get-macro-character #\$) t))
       (string= (symbol-name (read-from-string "a$b")) "A$B")
       (eq (read-from-string "$") :dollar)))

;; A dispatching macro character's function gets the sub-character and
;; the numeric argument.
(let ((*readtable* (copy-readtable)))
  (set-dispatch-macro-character #\# #\! (lambda (stream sub arg)
                                          (list sub arg (read stream t nil t))))
  (and (equal (read-from-string "#3!y") '(#\! 3 y))
       (equal (read-from-string "#!y") '(#\! nil y))
       (functionp (get-dispatch-macro-character #\# #\!))))

(let ((*readtable* (copy-readtable)))
  (make-dispatch-macro-character #\~)
  (set-dispatch-macro-character #\~ #\v (lambda (stream sub arg)
                                          (declare (ignore sub arg))
                                          (coerce (read stream t nil t) 'vector)))
  (equalp (read-from-string "~v(1 2)") #(1 2)))

;; The function for a standard macro character reads as the reader would.
(with-input-from-string (s "a b) rest")
  (and (equal (funcall (get-macro-character #\() s #\() '(a b))
       (eq (read s) 'rest)))

;; set-syntax-from-char gives a character another's syntax.
(let ((*readtable* (copy-readtable)))
  (set-syntax-from-char #\_ #\Space)
  (set-syntax-from-char #\' #\")
  (and (equal (read-from-string "(a_b)") '(a b))
       (equal (read-from-string "'text'") "text")))

;; Changing a copy leaves the readtable it came from alone.
(let ((copy (copy-readtable)))
  (set-macro-character #\@ (lambda (stream char) (declare (ignore stream char)) 1) nil copy)
  (and (null (get-macro-character #\@))
       (functionp (get-macro-character #\@ copy))))

;; :invert inverts a token whose letters are all one case.
(let ((*readtable* (copy-readtable)))
  (setf (readtable-case *readtable*) :invert)
  (and (string= (symbol-name (read-from-string "foo")) "FOO")
       (string= (symbol-name (read-from-string "FOO")) "foo")
       (string= (symbol-name (read-from-string "Foo")) "Foo")))

;; Under *read-suppress* every token, and every object a standard macro
;; character reads, is NIL.
(let ((*read-suppress* t))
  (equal (multiple-value-list (read-from-string "(no-such-package::x #c(1 2) #*12)"))
         '(nil 33)))

;; read-from-string takes the first of each keyword it is given.
(equal (multiple-value-list (read-from-string "7123  " t nil :start 1 :start 2)) '(123 5))
(equal (multiple-value-list (read-from-string "ab cd" t nil :preserve-whitespace t)) '(ab 2))
(equal (multiple-value-list (read-from-string "123 " t nil :foo 1 :allow-other-keys t)) '(123 4))
(equal (multiple-value-list (read-from-string "" nil :none)) '(:none 0))

;; read-preserving-whitespace leaves the whitespace after a token unread.
(with-input-from-string (s "x y")
  (read-preserving-whitespace s)
  (char= (read-char s) #\Space))
(with-input-from-string (s "x y")
  (read s)
  (char= (read-char s) #\y))

(with-input-from-string (s "1 2 3) after")
  (and (equal (read-delimited-list #\) s) '(1 2 3))
       (eq (read s) 'after)))

;; #S makes a structure with its keyword constructor.
(progn
  (defstruct reader-corpus-point x y)
  (let ((p (read-from-string "#S(reader-corpus-point :y 2 \"X\" 1)")))
    (and (reader-corpus-point-p p)
         (eql (reader-corpus-point-x p) 1)
         (eql (reader-corpus-point-y p) 2))))

;; An end of file and a reader error carry the stream being read.
(with-input-from-string (s "(a")
  (handler-case (progn (read s) nil)
    (end-of-file (c) (eq (stream-error-stream c) s))))
(handler-case (progn (read-from-string ")") nil)
  (reader-error (c) (streamp (stream-error-stream c))))
(handler-case (progn (read-from-string ",x") nil)
  (reader-error () t))
(handler-case (progn (read-from-string "a:b:c") nil)
  (reader-error () t))

;; A feature is a member of *features* by identity.
(let ((*features* '(:reader-corpus)))
  (equal (read-from-string "(#+reader-corpus a #-reader-corpus b #+(not reader-corpus) c)") '(a)))

;; The negation of 0.0 is -0.0, which conjugate gives too, and an
;; equalp hash table finds 0.0 under -0.0.
(eql (- 0.0) -0.0)
(eql (- 0.0d0) -0.0d0)
(eql (imagpart (conjugate #c(1.0 0.0))) -0.0)
(let ((table (make-hash-table :test 'equalp)))
  (setf (gethash 0.0 table) :zero)
  (eq (gethash -0.0 table) :zero))

;; A two-way stream reads from one stream and writes to another, and a
;; broadcast stream writes to each of its streams.
(let ((out (make-string-output-stream)))
  (with-input-from-string (in "42")
    (with-open-stream (both (make-two-way-stream in out))
      (write-string "seen" both)
      (and (eql (read both) 42)
           (eq (two-way-stream-input-stream both) in)
           (string= (get-output-stream-string out) "seen")))))
(let ((a (make-string-output-stream))
      (b (make-string-output-stream)))
  (let ((both (make-broadcast-stream a b)))
    (write-string "x" both)
    (and (equal (broadcast-stream-streams both) (list a b))
         (string= (get-output-stream-string a) "x")
         (string= (get-output-stream-string b) "x"))))
(progn (write-string "nothing" (make-broadcast-stream)) t)

;; A pprint dispatch entry prints atoms too, and the standard table has
;; none of the program's entries.
(let ((*print-pprint-dispatch* (copy-pprint-dispatch nil)))
  (set-pprint-dispatch 'symbol (lambda (stream object)
                                 (declare (ignore object))
                                 (write-string "SYM" stream)))
  (equal (list (let ((*print-pretty* t)) (princ-to-string 'x))
               (with-standard-io-syntax (let ((*print-pretty* t)) (princ-to-string 'x))))
         '("SYM" "X")))

;; princ prints with *print-readably* off.
(string= (with-standard-io-syntax (format nil "~a ~a" "s" #\c)) "s c")
