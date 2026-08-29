;; Pretty printer corpus.
;;
;; Each input is laid out against a stated right margin. The layout rules
;; are: a logical block prints flat when it fits before the margin;
;; otherwise its linear newlines all break together, and a broken line is
;; indented to the column just past the block's opening prefix. A break
;; discards the blanks that would have ended the line.
;;
;; Every expected string here is what SBCL 2.x produces for the same
;; input. `tests/lisp/pprint-check.lisp` runs the same cases under both
;; implementations so the two can be diffed directly.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defun laid-out (form margin)
    (let ((*print-right-margin* margin))
      (with-output-to-string (s) (pprint form s))))
  (defun laid-out-fill (form margin)
    (let ((*print-right-margin* margin))
      (with-output-to-string (s) (pprint-fill s form))))
  t)

;; 1. A form that fits stays on one line, after the leading newline
;;    pprint always writes.
(string= (laid-out '(1 2 3) 40) (concatenate 'string (string #\Newline) "(1 2 3)"))

;; 2. A form too wide for the margin breaks at every element.
(string= (laid-out '(aaaa bbbb cccc) 10)
         (concatenate 'string (string #\Newline) "(AAAA
 BBBB
 CCCC)"))

;; 3. A nested form breaks only at the level that does not fit.
(string= (laid-out '(a (bbbb cccc) (dddd eeee)) 12)
         (concatenate 'string (string #\Newline) "(A
 (BBBB
  CCCC)
 (DDDD
  EEEE))"))

;; 4. A wide margin leaves the same form flat.
(string= (laid-out '(a (bbbb cccc) (dddd eeee)) 60)
         (concatenate 'string (string #\Newline) "(A (BBBB CCCC) (DDDD EEEE))"))

;; 5. Fill style packs as many items on a line as fit.
(string= (laid-out-fill '(1 2 3 4 5 6 7 8 9 10 11 12) 20) "(1 2 3 4 5 6 7 8 9
 10 11 12)")

;; 6. A narrow margin under fill style still puts one item per line.
(string= (laid-out-fill '(aaaaa bbbbb ccccc) 8) "(AAAAA
 BBBBB
 CCCCC)")

;; 7. An atom wider than the whole margin is written anyway.
(string= (laid-out 'aaaaaaaaaaaaaaaaaaaaaaaa 5)
         (concatenate 'string (string #\Newline) "AAAAAAAAAAAAAAAAAAAAAAAA"))

;; 8. A list holding an atom wider than the margin breaks around it.
(string= (laid-out '(a bbbbbbbbbbbbbbbbbbbb c) 10)
         (concatenate 'string (string #\Newline) "(A
 BBBBBBBBBBBBBBBBBBBB
 C)"))

;; 9. The empty list is one token.
(string= (laid-out '() 40) (concatenate 'string (string #\Newline) "NIL"))

;; 10. A one-element list fits whatever the nesting.
(string= (laid-out '(((1))) 40) (concatenate 'string (string #\Newline) "(((1)))"))

;; 11. A dotted pair keeps its dot.
(string= (laid-out '(1 . 2) 40) (concatenate 'string (string #\Newline) "(1 . 2)"))

;; 12. Ten levels of nesting, flat when they fit.
(string= (laid-out '(1 (2 (3 (4 (5 (6 (7 (8 (9 (10)))))))))) 60)
         (concatenate 'string (string #\Newline) "(1 (2 (3 (4 (5 (6 (7 (8 (9 (10))))))))))"))

;; 13. The same ten levels break outward-in when the margin is tight.
(string= (laid-out '(1 (2 (3 (4 (5 (6 (7 (8 (9 (10)))))))))) 20)
         (concatenate 'string (string #\Newline) "(1
 (2
  (3
   (4
    (5
     (6
      (7
       (8
        (9
         (10))))))))))"))

;; 14. A string element keeps its quotes and counts its full width.
(string= (laid-out '("aaaa" "bbbb") 12)
         (concatenate 'string (string #\Newline) "(\"aaaa\"
 \"bbbb\")"))

;; 15. A vector, a string and a cons in one form.
(string= (laid-out '(#(1 2) "ab" (c . d)) 40)
         (concatenate 'string (string #\Newline) "(#(1 2) \"ab\" (C . D))"))

;; 16. The same mixed form, broken.
(string= (laid-out '(#(1 2) "ab" (c . d)) 12)
         (concatenate 'string (string #\Newline) "(#(1 2)
 \"ab\"
 (C . D))"))

;; --- logical blocks written by hand ---

;; 17. A block's prefix and suffix wrap its contents.
(string= (with-output-to-string (s)
           (pprint-logical-block (s nil :prefix "[" :suffix "]")
             (write-string "ab" s)))
         "[ab]")

;; 18. A conditional newline inside a block that fits does not break.
(string= (let ((*print-right-margin* 40))
           (with-output-to-string (s)
             (pprint-logical-block (s nil :prefix "(" :suffix ")")
               (write-string "a" s)
               (write-string " " s)
               (pprint-newline :linear s)
               (write-string "b" s))))
         "(a b)")

;; 19. The same block breaks when it does not fit, and the break takes the
;;     separating blank with it.
(string= (let ((*print-right-margin* 4))
           (with-output-to-string (s)
             (pprint-logical-block (s nil :prefix "(" :suffix ")")
               (write-string "aaa" s)
               (write-string " " s)
               (pprint-newline :linear s)
               (write-string "bbb" s))))
         "(aaa
 bbb)")

;; 20. A mandatory newline breaks however much room is left.
(string= (let ((*print-right-margin* 80))
           (with-output-to-string (s)
             (pprint-logical-block (s nil :prefix "(" :suffix ")")
               (write-string "a" s)
               (pprint-newline :mandatory s)
               (write-string "b" s))))
         "(a
 b)")

;; 21. pprint-indent moves where later breaks land.
(string= (let ((*print-right-margin* 4))
           (with-output-to-string (s)
             (pprint-logical-block (s nil :prefix "(" :suffix ")")
               (pprint-indent :block 3 s)
               (write-string "aaa" s)
               (pprint-newline :mandatory s)
               (write-string "bbb" s))))
         "(aaa
    bbb)")

;; 22. A per-line prefix goes on every line the block wraps onto. CLHS
;;     forbids giving both a prefix and a per-line prefix.
(string= (let ((*print-right-margin* 4))
           (with-output-to-string (s)
             (pprint-logical-block (s nil :per-line-prefix ";" :suffix ")")
               (write-string "aaa" s)
               (pprint-newline :mandatory s)
               (write-string "bbb" s))))
         ";aaa
;bbb)")

;; --- miser style ---

;; 23. A block with no more room left than the miser width lays out in
;;     miser style, where a fill newline behaves as a linear one and every
;;     part lands on its own line.
(string= (let ((*print-right-margin* 30) (*print-miser-width* 30))
           (with-output-to-string (s)
             (pprint-fill s '(aaaa bbbb cccc dddd eeee ffff gggg))))
         "(AAAA
 BBBB
 CCCC
 DDDD
 EEEE
 FFFF
 GGGG)")

;; 24. Without the miser width the same form fills.
(string= (let ((*print-right-margin* 30) (*print-miser-width* nil))
           (with-output-to-string (s)
             (pprint-fill s '(aaaa bbbb cccc dddd eeee ffff gggg))))
         "(AAAA BBBB CCCC DDDD EEEE
 FFFF GGGG)")

;; --- recursive and shared structure ---

;; 25. A circular list labels itself and refers back.
(string= (let ((*print-circle* t) (*print-right-margin* 40))
           (let ((x (list 1 2)))
             (setf (cddr x) x)
             (with-output-to-string (s) (pprint x s))))
         (concatenate 'string (string #\Newline) "#1=(1 2 . #1#)"))

;; 26. Structure shared between two places is labelled once.
(string= (let ((*print-circle* t) (*print-right-margin* 40))
           (let ((shared (list 'a)))
             (with-output-to-string (s) (pprint (list shared shared) s))))
         (concatenate 'string (string #\Newline) "(#1=(A) #1#)"))

;; 27. Without *print-circle* an ordinary list prints without labels.
(string= (let ((*print-circle* nil))
           (with-output-to-string (s) (write '(1 2 3) :stream s)))
         "(1 2 3)")

;; --- the dispatch table ---

;; 23. An entry takes over printing for its type.
(progn
  (set-pprint-dispatch 'integer (lambda (s x) (declare (ignore x)) (write-string "<int>" s)))
  (let ((text (with-output-to-string (s) (pprint 5 s))))
    (set-pprint-dispatch 'integer nil)
    (string= text (concatenate 'string (string #\Newline) "<int>"))))

;; 24. Turning the entry off puts the ordinary printing back.
(string= (laid-out 5 40) (concatenate 'string (string #\Newline) "5"))

;; 25. pprint-dispatch reports whether an entry matched.
(and (null (nth-value 1 (pprint-dispatch 5)))
     (progn
       (set-pprint-dispatch 'symbol (lambda (s x) (declare (ignore x)) (write-string "?" s)))
       (prog1 (nth-value 1 (pprint-dispatch 'a))
         (set-pprint-dispatch 'symbol nil))))
