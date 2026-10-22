;; A form typed at the debugger sees the lexical bindings where the
;; condition was signaled: a let at the top level, then the parameters and
;; let bindings of a function.
(let ((retries 3)) (error "Gave up after ~d retries." retries))
(* retries 10)
0
(defun port-separator (text)
  (let ((colon (position #\: text)))
    (when (null colon) (error "No port separator in ~s." text))
    colon))
(list (port-separator "db:5432") (port-separator "localhost"))
(list text colon)
0
