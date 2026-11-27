;; Run the whole ansi-test suite the way its doit.lsp does, from inside a
;; copy of the suite. An error while the suite loads ends the run with the
;; file it came from. A test named in the file *ansi-expected-failures*
;; names is expected to fail, and the run fails when one of those passes
;; as well as when any other test fails.

(defvar cl-user::*ansi-expected-failures* nil)

(handler-bind ((error (lambda (condition)
                        (format t "~&ANSI-LOAD-ERROR ~A ~S ~A~%"
                                *load-truename* (type-of condition) condition)
                        (finish-output)
                        (quit 3))))
  (load "init.lsp"))

(when *load-pathname*
  (mapc #'regression-test:rem-test '(cl-test::load-pathname.1 cl-test::load-truename.1)))

(rt::disable-note :nil-vectors-are-strings)

(if cl-user::*ansi-expected-failures*
    (regression-test:do-tests :expected-failures cl-user::*ansi-expected-failures*)
    (regression-test:do-tests))

(format t "~&ANSI-SUITE ~D ~D ~D ~D ~D~%"
        (length (cdr rt::*entries*))
        (length regression-test::*passed-tests*)
        (length regression-test::*failed-tests*)
        (length rt::*unexpected-failures*)
        (length rt::*unexpected-successes*))
(finish-output)
(quit (if (or rt::*unexpected-failures* rt::*unexpected-successes*) 1 0))
