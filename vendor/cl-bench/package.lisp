;;;; package.lisp

(defpackage #:cl-bench
  (:use #:cl)
  (:export #:bench-run-1
           #:bench-run
           #:defbench))
