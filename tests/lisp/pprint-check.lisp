;;;; pprint-check.lisp - print the layout of the pretty-printer corpus
;;;; inputs. The same file runs under both implementations, so their
;;;; output can be diffed directly:
;;;;
;;;;   sbcl --script tests/lisp/pprint-check.lisp > /tmp/sbcl.txt
;;;;   zig-out/bin/zisp --batch --load tests/lisp/pprint-check.lisp > /tmp/zisp.txt
;;;;   diff /tmp/sbcl.txt /tmp/zisp.txt
;;;;
;;;; Each line is `<case-number> <printed-string>`, where the string is
;;;; written with prin1 so newlines and quotes are unambiguous. The case
;;;; numbers match the numbered comments in tests/lisp/pprint-corpus.lisp.

(defvar *case* 0)

(defun emit (text)
  (incf *case*)
  (format t "~D " *case*)
  (prin1 text)
  (terpri))

(defun laid-out (form margin)
  (let ((*print-right-margin* margin)
        (*print-pretty* t))
    (with-output-to-string (s) (pprint form s))))

(defun laid-out-fill (form margin)
  (let ((*print-right-margin* margin)
        (*print-pretty* t))
    (with-output-to-string (s) (pprint-fill s form))))

;; 1-4: nesting and the margin.
(emit (laid-out '(1 2 3) 40))
(emit (laid-out '(aaaa bbbb cccc) 10))
(emit (laid-out '(a (bbbb cccc) (dddd eeee)) 12))
(emit (laid-out '(a (bbbb cccc) (dddd eeee)) 60))

;; 5-6: fill style.
(emit (laid-out-fill '(1 2 3 4 5 6 7 8 9 10 11 12) 20))
(emit (laid-out-fill '(aaaaa bbbbb ccccc) 8))

;; 7-8: atoms wider than the margin.
(emit (laid-out 'aaaaaaaaaaaaaaaaaaaaaaaa 5))
(emit (laid-out '(a bbbbbbbbbbbbbbbbbbbb c) 10))

;; 9-11: small forms.
(emit (laid-out '() 40))
(emit (laid-out '(((1))) 40))
(emit (laid-out '(1 . 2) 40))

;; 12-13: ten levels of nesting, loose and tight.
(emit (laid-out '(1 (2 (3 (4 (5 (6 (7 (8 (9 (10)))))))))) 60))
(emit (laid-out '(1 (2 (3 (4 (5 (6 (7 (8 (9 (10)))))))))) 20))

;; 14-16: strings, vectors and conses together.
(emit (laid-out '("aaaa" "bbbb") 12))
(emit (laid-out '(#(1 2) "ab" (c . d)) 40))
(emit (laid-out '(#(1 2) "ab" (c . d)) 12))

;; 17-22: logical blocks written by hand.
(emit (with-output-to-string (s)
        (pprint-logical-block (s nil :prefix "[" :suffix "]")
          (write-string "ab" s))))

(emit (let ((*print-right-margin* 40))
        (with-output-to-string (s)
          (pprint-logical-block (s nil :prefix "(" :suffix ")")
            (write-string "a" s)
            (write-string " " s)
            (pprint-newline :linear s)
            (write-string "b" s)))))

(emit (let ((*print-right-margin* 4))
        (with-output-to-string (s)
          (pprint-logical-block (s nil :prefix "(" :suffix ")")
            (write-string "aaa" s)
            (write-string " " s)
            (pprint-newline :linear s)
            (write-string "bbb" s)))))

(emit (let ((*print-right-margin* 80))
        (with-output-to-string (s)
          (pprint-logical-block (s nil :prefix "(" :suffix ")")
            (write-string "a" s)
            (pprint-newline :mandatory s)
            (write-string "b" s)))))

(emit (let ((*print-right-margin* 4))
        (with-output-to-string (s)
          (pprint-logical-block (s nil :prefix "(" :suffix ")")
            (pprint-indent :block 3 s)
            (write-string "aaa" s)
            (pprint-newline :mandatory s)
            (write-string "bbb" s)))))

(emit (let ((*print-right-margin* 4))
        (with-output-to-string (s)
          (pprint-logical-block (s nil :per-line-prefix ";" :suffix ")")
            (write-string "aaa" s)
            (pprint-newline :mandatory s)
            (write-string "bbb" s)))))

;; 23-24: miser mode. The inner block starts past the miser width, so
;; every conditional newline in it breaks rather than filling.
(emit (let ((*print-right-margin* 30)
            (*print-miser-width* 30)
            (*print-pretty* t))
        (with-output-to-string (s)
          (pprint-fill s '(aaaa bbbb cccc dddd eeee ffff gggg)))))

(emit (let ((*print-right-margin* 30)
            (*print-miser-width* nil)
            (*print-pretty* t))
        (with-output-to-string (s)
          (pprint-fill s '(aaaa bbbb cccc dddd eeee ffff gggg)))))

;; 25-26: recursive structure through *print-circle*.
(emit (let ((*print-circle* t)
            (*print-right-margin* 40)
            (*print-pretty* t))
        (let ((x (list 1 2)))
          (setf (cddr x) x)
          (with-output-to-string (s) (pprint x s)))))

(emit (let ((*print-circle* t)
            (*print-right-margin* 40)
            (*print-pretty* t))
        (let ((shared (list 'a)))
          (with-output-to-string (s) (pprint (list shared shared) s)))))
