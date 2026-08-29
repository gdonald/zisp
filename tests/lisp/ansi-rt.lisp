;; The ansi-test framework, brought up far enough to run a slice of the
;; suite against zisp.
;;
;; A driver loads this with `vendor/ansi-test` as the working directory,
;; which is what the relative loads below need, then calls
;; `run-ansi-files` with the files it wants. `tests/run-rt-tests.sh` is
;; what does that.

(load "rt-package.lsp")
(load "rt.lsp")
(load "cl-test-package.lsp")

(in-package :cl-test)

;; ansi-test compiles its auxiliary files before loading them. zisp has
;; no compiler, so loading the source is what these two come to.
(defun %ansi-relative (path)
  "PATH against the directory of the file being loaded, which is what
ansi-test's own `compile-and-load` does through `merge-pathnames`."
  (let* ((base *load-pathname*)
         (slash (and (stringp base) (position #\/ base :from-end t))))
    (if slash
        (concatenate 'string (subseq base 0 (+ slash 1)) path)
        path)))

(defun compile-and-load (path &key force)
  (declare (ignore force))
  (load (%ansi-relative path)))

(defun compile-and-load* (path &key force)
  (declare (ignore force))
  (load (concatenate 'string "auxiliary/" path)))

;; `random-aux.lsp` defines one method combination for its randomized
;; generators. Nothing in this slice calls through it, and zisp has no
;; `define-method-combination` yet, so the definition is read and
;; dropped.
(defmacro define-method-combination (&rest ignored)
  (declare (ignore ignored))
  nil)

;; `ansi-aux.lsp` defines one generic function, `is-similar*`, with a
;; method per type. zisp has no CLOS yet, so the definitions are read and
;; a call to what they would have defined fails rather than answering
;; something made up.
(defmacro defgeneric (name lambda-list &rest options)
  (declare (ignore lambda-list options))
  `(defun ,name (&rest arguments)
     (declare (ignore arguments))
     (error "~s needs generic functions, which are not defined yet." ',name)))

(defmacro defmethod (&rest ignored)
  (declare (ignore ignored))
  nil)

(load "auxiliary/ansi-aux-macros.lsp")

;; `ansi-aux.lsp` reads `*condition-types*` out of `universe.lsp`, which
;; builds its object universe with CLOS. The list itself needs none of
;; that, so it is repeated here rather than pulling that file in.
(defparameter *condition-types*
  '(arithmetic-error cell-error condition control-error division-by-zero
    end-of-file error file-error floating-point-inexact
    floating-point-invalid-operation floating-point-underflow
    floating-point-overflow package-error parse-error print-not-readable
    program-error reader-error serious-condition simple-condition
    simple-error simple-type-error simple-warning storage-condition
    stream-error style-warning type-error unbound-slot unbound-variable
    undefined-function warning))

;; `universe.lsp` builds its object list with CLOS, which zisp has no
;; part of yet. What the files here want of it is a spread of objects of
;; different types, so one is put together from the types zisp has. A
;; test reading it covers those rather than the whole standard set.
(defparameter *mini-universe*
  (list nil t 'a :b 0 1 -1 1000000 12345678901234567890 1/2 -3/4
        1.5 1.5d0 #\a #\Space "" "abc" (list 1) (cons 1 2)
        (make-array 3 :initial-element 0)
        (make-hash-table) (find-package "COMMON-LISP")
        (pathname "foo.txt") *standard-output* *readtable* #'car
        (make-condition 'simple-error :format-control "x")))

(defparameter *universe* *mini-universe*)

(load "auxiliary/random-aux.lsp")
(load "auxiliary/ansi-aux.lsp")
(load "auxiliary/printer-aux.lsp")

;; Load each file, run what they registered, and print the tally the
;; harness reads. A file that will not load registers no tests, so what
;; it holds counts as failed rather than as absent, and its name is
;; reported.
(defun run-ansi-files (label paths)
  (let ((loaded 0)
        (unloadable nil))
    (dolist (path paths)
      (if (car (multiple-value-list
                (handler-case (progn (load path) nil)
                  (error (e) (declare (ignore e)) t))))
          (push path unloadable)
          (setq loaded (1+ loaded))))
    (do-tests)
    (format t "ANSI-RT ~a ~d ~d ~d ~d~%"
            label
            (length *passed-tests*)
            (length *failed-tests*)
            loaded
            (length paths))
    (format t "ANSI-RT-UNLOADABLE ~a~%" (reverse unloadable))))
