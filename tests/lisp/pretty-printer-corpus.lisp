;; Logical blocks laid out by the pretty printer, from pprint-logical-block
;; and from format. Every form here must evaluate to T.

(progn
  (defun pretty-out (margin thunk)
    (let ((*print-pretty* t)
          (*print-right-margin* margin)
          (*print-escape* nil))
      (with-output-to-string (s) (funcall thunk s))))
  t)

;; A fill newline breaks where the next section does not fit, and the
;; blank before the break is dropped.
(string= (pretty-out 10 (lambda (s)
                          (pprint-logical-block (s nil)
                            (dotimes (i 2) (write "A " :stream s) (pprint-newline :fill s))
                            (format s "B ~_")
                            (dotimes (i 3) (write "A " :stream s) (pprint-newline :fill s)))))
         "A A B
A A A ")

;; Indentation counts from where the block's text starts.
(string= (pretty-out 100 (lambda (s) (format s "~<M~3:i~:@_M~:>" '(m m))))
         "M
    M")

;; A newline written as text starts its line with no indentation.
(string= (pretty-out 100 (lambda (s)
                           (pprint-logical-block (s '(1 2 3))
                             (pprint-indent :block 2 s)
                             (write 1 :stream s)
                             (terpri s)
                             (write 2 :stream s)
                             (pprint-newline :mandatory s)
                             (write 3 :stream s))))
         "1
2
  3")

;; A per-line prefix starts every line of its block.
(string= (pretty-out 100 (lambda (s)
                           (pprint-logical-block (s nil :per-line-prefix ";; ")
                             (write "a" :stream s)
                             (pprint-newline :mandatory s)
                             (write "b" :stream s))))
         ";; a
;; b")

;; *print-lines* ends the output with " .." and the open suffixes.
(string= (let ((*print-lines* 1))
           (pretty-out 100 (lambda (s)
                             (pprint-logical-block (s nil :prefix "(" :suffix ")")
                               (write "a" :stream s)
                               (pprint-newline :mandatory s)
                               (write "b" :stream s)))))
         "(a ..)")

;; pprint-pop stops at *print-length* and at a tail that is not a list.
(string= (let ((*print-length* 2))
           (pretty-out 100 (lambda (s) (pprint-fill s '(1 2 3)))))
         "(1 2 ...)")
(string= (pretty-out 100 (lambda (s)
                           (pprint-logical-block (s '(1 2 . 3) :prefix "<" :suffix ">")
                             (loop (write (pprint-pop) :stream s)
                                   (pprint-exit-if-list-exhausted)
                                   (write-char #\Space s)))))
         "<1 2 . 3>")

;; A circular tail prints as a reference, labeled only where it prints.
(string= (let ((*print-circle* t))
           (pretty-out 100 (lambda (s)
                             (let* ((tail (list 1)) (x (list* tail 2 tail)))
                               (pprint-fill s x)))))
         "(#1=(1) 2 . #1#)")
(string= (let ((*print-circle* t) (*print-length* 1))
           (pretty-out 100 (lambda (s)
                             (let* ((tail (list 1)) (x (list* tail 2 tail)))
                               (pprint-fill s x)))))
         "((1) ...)")

;; A tabular list puts each element at a multiple of its column width.
(string= (pretty-out 100 (lambda (s) (format s "~<~4:/pprint-tabular/~:>" '((m m)))))
         "(M   M)")

;; A section tab does nothing with the pretty printer off.
(string= (let ((*print-pretty* nil))
           (with-output-to-string (s)
             (pprint-logical-block (s '(a b c))
               (format s "XX~10:tYY"))))
         "XXYY")

;; ~/name/ reads its parameters ahead of its argument.
(progn
  (defun pretty-corpus-slash (stream arg colon at &rest params)
    (format stream "~a ~a ~a ~s" arg colon at params))
  (string= (format nil "~v,'x:/cl-user::pretty-corpus-slash/" 19 7) "7 T NIL (19 #\\x)"))

;; A justification's first segment ended by ~n,m:; goes out only when the
;; rest would pass column m.
(string= (format nil "~%X ~<~%X ~0,3:;AAA~>") "
X 
X AAA")
(string= (format nil "~15,,,'*<AA~;BBBB~;CCCC~>") "AA**BBBB***CCCC")
(string= (format nil "~7,,4<~A~>" "xxxxxx") " xxxxxx")

;; A justification holding pretty printing is an error.
(handler-case (progn (format nil "~< ~_ ~>") nil) (error () t))
(handler-case (progn (format nil "~<X~:;Y~>~I") nil) (error () t))

;; pprint-indent takes any real, and is ignored with the pretty printer off.
(null (let ((*print-pretty* nil)) (pprint-indent :block 1/2 (make-string-output-stream))))
(string= (pretty-out 100 (lambda (s)
                           (pprint-logical-block (s nil)
                             (write "MMM" :stream s)
                             (pprint-indent :block 3.0 s)
                             (pprint-newline :mandatory s)
                             (write "M" :stream s))))
         "MMM
   M")

;; pprint returns no values, after a newline.
(equal (let ((*print-right-margin* 80))
         (multiple-value-list (pprint 'x (make-string-output-stream))))
       nil)
