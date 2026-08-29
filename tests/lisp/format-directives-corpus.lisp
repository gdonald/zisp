;; Every form here must evaluate to T.

(string= (format nil "~D test~:P" 2) "2 tests")
(string= (format nil "~D test~:P" 1) "1 test")
(string= (format nil "~D famil~:@P" 2) "2 families")
(string= (format nil "~D famil~:@P" 1) "1 family")
(string= (format nil "1 penn~@P" 1) "1 penny")
(string= (format nil "~(HELLO World~)") "hello world")
(string= (format nil "~:(hello world~)") "Hello World")
(string= (format nil "~@(hello world~)") "Hello world")
(string= (format nil "~:@(~S~)" 'ab) "AB")
(string= (format nil "~(~S ~S~)" 'ab 'cd) "ab cd")
(string= (format nil "a~<~%~:; ~>b") "a b")
;; `~@<` hands the block the rest of the argument list, where `~<`
;; would take one list argument.
(string= (format nil "~@<~@{~S~^, ~:_~}~:>" 1 2) "1, 2")
(string= (format nil "a~
      b") "ab")
(string= (format nil "a~:
      b") "a      b")
(string= (format nil "a~@
      b") (concatenate 'string "a" (string #\Newline) "b"))
(string= (format nil "~W" '(1 "x")) "(1 \"x\")")
(string= (format nil "a~_b") "ab")
(string= (format nil "~2Ia") "a")
(string= (format nil "~:[no~;yes~]" nil) "no")
(string= (format nil "~@[~a~]" 5) "5")
(string= (format nil "~{~a-~}" '(1 2)) "1-2-")
(string= (format nil "~?" "~a" '(7)) "7")
