;; Backtraces of errors that start inside macro expansions, using macros
;; from `tests/lisp/macroexpand-positions.lisp`. A call a macro builds is
;; placed where the person wrote the macro's call, not in the macro's
;; definition, and a call passed through verbatim keeps its own place.

(progn
  (defmacro backtrace-of (form)
    `(block captured
       (let ((*debugger-hook* (lambda (condition hook)
                                (declare (ignore condition hook))
                                (return-from captured (backtrace)))))
         ,form)))

  ;; wraps the body in a synthesized progn under a synthesized if
  (defmacro mp-2 (c &body b)
    (list 'if c (cons 'progn b) 'nil))

  ;; prepends a block header onto the verbatim body spine
  (defmacro mp-4 (name &body b)
    (cons 'block (cons name b)))

  ;; threads a user form through two synthesized call shells
  (defmacro mp-6 (x f g)
    (list g (list f x)))

  ;; synthesizes a call to another macro without expanding it
  (defmacro mp-8 (&body b)
    (cons 'mp-4 (cons 'blk2 b)))

  ;; builds a let with a synthesized binding list around the verbatim body
  (defmacro mp-9 (var val &body b)
    (cons 'let (cons (list (list var val)) b)))

  (defun sink (value) (error "Rejected ~s." value))
  (defun pass (value) value)
  t)

;; The call to SINK is one MP-6 built.
(equal (backtrace-of (mp-6 3 sink pass))
       '(("SINK" ("backtrace-macroexpand.lisp" 39 22) (3))))

;; The outer call MP-6 built fails after the inner one returns.
(equal (backtrace-of (mp-6 4 pass sink))
       '(("SINK" ("backtrace-macroexpand.lisp" 43 22) (4))))

;; MP-2 passes its body through, so the call keeps its own place.
(equal (backtrace-of (mp-2 t (sink 5)))
       '(("SINK" ("backtrace-macroexpand.lisp" 47 30) (5))))

;; MP-9 binds around the verbatim body.
(equal (backtrace-of (mp-9 v 6 (sink v)))
       '(("SINK" ("backtrace-macroexpand.lisp" 51 32) (6))))

;; MP-8 builds a call to MP-4, which passes the MP-6 call through; the
;; call MP-6 builds is placed where that MP-6 call was written.
(equal (backtrace-of (mp-8 (mp-6 7 sink pass)))
       '(("SINK" ("backtrace-macroexpand.lisp" 56 28) (7))))
