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

(load "auxiliary/ansi-aux-macros.lsp")

;; The notes a test can be tagged with. An array zisp is asked to make of
;; element type `nil` upgrades to `bit`, so no `(vector nil)` is a string,
;; and the tests that assume one is are switched off.
(load "notes.lsp")
(rt::disable-note :nil-vectors-are-strings)

(load "universe.lsp")
(load "cl-symbol-names.lsp")
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
