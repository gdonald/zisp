;; tests/lisp/key-args-corpus.lisp
;;
;; Acceptance corpus for &key argument processing.
;;
;; Each non-comment line: <expected> <form>
;;   <expected> — comma-separated elements of the list the form returns,
;;                each a decimal integer, NIL, or T (no spaces)
;;   <form>     — a single form; each calls a lambda via funcall and returns
;;                a list built from the bound variables
;;
;; The driver registers funcall and list as scaffolding; everything else is
;; the core evaluator and lambda-list binder. Every expected value matches
;; SBCL 2.x.
;;
;; Coverage: basic binding, order independence, defaults, supplied-p,
;; explicit keyword names, duplicate-key first-wins, &allow-other-keys,
;; caller :allow-other-keys t / nil, &rest interaction, and combination
;; with required / &optional parameters.

;; a bound, b defaulted
1,10 (funcall (lambda (&key a (b 10)) (list a b)) :a 1)

;; both keys supplied
1,2 (funcall (lambda (&key a b) (list a b)) :a 1 :b 2)

;; keyword order does not matter
2,1 (funcall (lambda (&key a b) (list a b)) :b 1 :a 2)

;; missing key takes its default form
0 (funcall (lambda (&key (a 0)) (list a)) )

;; missing key with no default is NIL
NIL (funcall (lambda (&key a) (list a)))

;; supplied-p is T when the key is present
5,T (funcall (lambda (&key (a 0 ap)) (list a ap)) :a 5)

;; supplied-p is NIL when the key is absent
0,NIL (funcall (lambda (&key (a 0 ap)) (list a ap)))

;; explicit ((:keyword var)) form binds the named variable
7 (funcall (lambda (&key ((:foo x) 0)) (list x)) :foo 7)

;; explicit keyword form with its default
0 (funcall (lambda (&key ((:foo x) 0)) (list x)))

;; duplicate keyword: the first value wins
1 (funcall (lambda (&key a) (list a)) :a 1 :a 2)

;; &allow-other-keys accepts an unknown keyword
1 (funcall (lambda (&key a &allow-other-keys) (list a)) :a 1 :b 2)

;; caller :allow-other-keys t overrides strictness
1 (funcall (lambda (&key a) (list a)) :a 1 :zzz 9 :allow-other-keys t)

;; caller :allow-other-keys nil keeps strictness (only known keys here)
1 (funcall (lambda (&key a) (list a)) :a 1 :allow-other-keys nil)

;; &rest and &key bind over the same tail
5 (funcall (lambda (&rest r &key a) (list a)) :a 5)

;; required parameter then a key
3,2 (funcall (lambda (x &key a) (list x a)) 3 :a 2)

;; required, optional, then a key
1,9,2 (funcall (lambda (a &optional b &key k) (list a b k)) 1 9 :k 2)

;; several keys, some defaulted
1,0,3 (funcall (lambda (&key a (b 0) (c 3)) (list a b c)) :a 1)

;; explicit NIL value still counts as supplied
NIL,T (funcall (lambda (&key (a 5 ap)) (list a ap)) :a nil)

;; a later key default sees an earlier key
7,7 (funcall (lambda (&key (a 1) (b a)) (list a b)) :a 7)

;; a key default sees a required parameter
4 (funcall (lambda (x &key (a x)) (list a)) 4)

;; &allow-other-keys with unknown keys surrounding the known one
1 (funcall (lambda (&key a &allow-other-keys) (list a)) :b 2 :a 1 :c 3)

;; only unknown keys with &allow-other-keys: known key defaults
NIL (funcall (lambda (&key a &allow-other-keys) (list a)) :b 2)

;; no keys passed, multiple defaults
1,2 (funcall (lambda (&key (a 1) (b 2)) (list a b)))

;; caller :allow-other-keys t alongside a known key
9 (funcall (lambda (&key (a 0)) (list a)) :a 9 :other 1 :allow-other-keys t)

;; keyword arguments may repeat a default-bearing key; first wins
3 (funcall (lambda (&key (a 0)) (list a)) :a 3 :a 99)
