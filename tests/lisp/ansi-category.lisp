;; Run one category of the ansi-test suite the way the suite's own
;; gclload2.lsp loads it, from inside a copy of the suite: gclload1.lsp
;; brings up rt and the auxiliary files, then the category's load.lsp
;; loads its tests. cl-user::*ansi-category* names the category.

(defvar cl-user::*ansi-category*)

(handler-bind ((error (lambda (condition)
                        (format t "~&ANSI-LOAD-ERROR ~A ~S ~A~%"
                                *load-truename* (type-of condition) condition)
                        (finish-output)
                        (quit 3))))
  (load "gclload1.lsp")
  (in-package :cl-test)
  (load (concatenate 'string cl-user::*ansi-category* "/load.lsp")))

(when *load-pathname*
  (mapc #'regression-test:rem-test '(cl-test::load-pathname.1 cl-test::load-truename.1)))

(rt::disable-note :nil-vectors-are-strings)

(regression-test:do-tests)
(format t "~&ANSI-RT ~A ~D ~D ~D~%"
        cl-user::*ansi-category*
        (length (cdr rt::*entries*))
        (length regression-test::*passed-tests*)
        (length regression-test::*failed-tests*))
(finish-output)
