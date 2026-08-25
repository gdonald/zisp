;; The ansi-test format suite, loaded and run against zisp.
;;
;; `tests/run-format-tests.sh` runs this with `vendor/ansi-test` as the
;; working directory, which is what the relative loads below need.
;;
;; The suite is rt-based: each file registers tests with `deftest`, and
;; `do-tests` runs them and collects what passed and what failed. The
;; count printed at the end is what the harness reports.

(load "rt-package.lsp")
(load "rt.lsp")
(load "cl-test-package.lsp")

(in-package :cl-test)

;; ansi-test compiles its auxiliary files before loading them. zisp has
;; no compiler, so loading the source is what these two come to.
(defun compile-and-load (path &key force)
  (declare (ignore force))
  (load path))

(defun compile-and-load* (path &key force)
  (declare (ignore force))
  (load (concatenate 'string "auxiliary/" path)))

;; `random-aux.lsp` defines one method combination for its randomized
;; generators. Nothing in the format suite calls through it, and zisp has
;; no `define-method-combination` yet, so the definition is read and
;; dropped.
(defmacro define-method-combination (&rest ignored)
  (declare (ignore ignored))
  nil)

;; `ansi-aux.lsp` defines one generic function, `is-similar*`, with a
;; method per type. zisp has no CLOS yet, so the definitions are read and
;; a call to what they would have defined fails rather than answering
;; something made up. The format tests do not call it.
(defmacro defgeneric (name lambda-list &rest options)
  (declare (ignore lambda-list options))
  `(defun ,name (&rest arguments)
     (declare (ignore arguments))
     (error "~s needs generic functions, which are not defined yet." ',name)))

(defmacro defmethod (&rest ignored)
  (declare (ignore ignored))
  nil)

(load "auxiliary/ansi-aux-macros.lsp")
(load "auxiliary/random-aux.lsp")
(load "auxiliary/ansi-aux.lsp")
(load "auxiliary/printer-aux.lsp")

(defvar *format-test-files*
  '("format-c" "formatter-c" "format-percent" "format-ampersand" "format-page"
    "format-tilde" "format-r" "format-d" "format-b" "format-o" "format-x"
    "format-f" "format-e" "format-a" "format-s" "format-underscore"
    "format-logical-block" "format-i" "format-slash" "format-t" "format-justify"
    "format-goto" "format-conditional" "format-brace" "format-question"
    "format-paren" "format-p" "format-circumflex" "format-newline"))

(defvar *loaded* 0)
(defvar *unloadable* nil)

;; A file that will not load registers no tests, so what it holds counts
;; as failed rather than as absent. The names are reported at the end.
(dolist (name *format-test-files*)
  (let ((path (concatenate 'string "printer/format/" name ".lsp")))
    (if (car (multiple-value-list
              (handler-case (progn (load path) nil)
                (error (e) (declare (ignore e)) t))))
        (push name *unloadable*)
        (setq *loaded* (1+ *loaded*)))))

(do-tests)

(format t "ANSI-FORMAT ~d ~d ~d ~d~%"
        (length *passed-tests*)
        (length *failed-tests*)
        *loaded*
        (length *format-test-files*))
(format t "ANSI-FORMAT-UNLOADABLE ~a~%" (reverse *unloadable*))
