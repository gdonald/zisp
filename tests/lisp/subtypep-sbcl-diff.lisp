;; Replays the `subtypep` calls SBCL answered for the ansi-test `subtypep`
;; files and compares zisp's answers. `tests/run-subtypep-sbcl-diff.sh`
;; loads `tests/lisp/ansi-rt.lisp` first, binds `*sbcl-calls-file*` to the
;; file `tests/lisp/subtypep-sbcl-log.lisp` wrote, and then loads this.
;;
;; Each record is one line, which zisp reads with `read-from-string`,
;; and starts with the objects its types name by identity. An
;; uncertain answer from zisp where SBCL is certain is a violation, and so
;; is an error from either reading the record or calling `subtypep`. A
;; certain answer that differs from a certain SBCL answer is a
;; disagreement. Each is listed, and the tally line reads
;; `SUBTYPEP-SBCL calls violations disagreements`.

(in-package :cl-test)

(load "auxiliary/types-aux.lsp")

(defvar *sbcl-calls-file*)

(defun restore-objects (form objects)
  "FORM with each placeholder OBJECTS names replaced by its object."
  (cond ((and (symbolp form) (assoc form objects)) (cdr (assoc form objects)))
        ((consp form) (cons (restore-objects (car form) objects)
                            (restore-objects (cdr form) objects)))
        (t form)))

(defun compare-with-sbcl (line)
  "What is wrong with zisp's answer to the call LINE records: :violation,
:disagreement, or nil."
  (destructuring-bind (objects type-1 type-2 sbcl-subtype-p sbcl-certain-p)
      (read-from-string line)
    (setq type-1 (restore-objects type-1 objects)
          type-2 (restore-objects type-2 objects))
    (multiple-value-bind (subtype-p certain-p) (subtypep type-1 type-2)
      (cond ((and sbcl-certain-p (not certain-p)) :violation)
            ((and sbcl-certain-p (not (eq (and subtype-p t) sbcl-subtype-p))) :disagreement)
            (t nil)))))

(let ((calls 0)
      (violations 0)
      (disagreements 0))
  (with-open-file (in *sbcl-calls-file*)
    (loop for line = (read-line in nil nil)
          while line
          do (incf calls)
             (case (handler-case (compare-with-sbcl line)
                     (error () :violation))
               (:violation
                (incf violations)
                (format t "VIOLATION ~a~%" line))
               (:disagreement
                (incf disagreements)
                (format t "DISAGREEMENT ~a~%" line)))))
  (format t "SUBTYPEP-SBCL ~d ~d ~d~%" calls violations disagreements))
