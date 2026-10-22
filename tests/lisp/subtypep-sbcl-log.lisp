;; Run under SBCL, not zisp: `tests/gen-subtypep-sbcl.sh` loads this with
;; `vendor/ansi-test` as the working directory.
;;
;; Runs the ansi-test `subtypep` files with every call to `subtypep` they
;; make recorded, and writes each distinct call with SBCL's two values to
;; the file named by the SUBTYPEP_SBCL_OUT environment variable, one
;; `(objects type-1 type-2 subtypep-p certain-p)` per line. Calls whose
;; types do not print as something that reads back, or that name a type
;; of SBCL's own, are left out.

(defpackage :subtypep-log
  (:use :common-lisp)
  (:shadow #:subtypep)
  (:export #:subtypep #:*calls*))

(in-package :subtypep-log)

(defvar *calls* nil)

(defun subtypep (type-1 type-2 &optional environment)
  (multiple-value-bind (subtype-p certain-p) (cl:subtypep type-1 type-2 environment)
    (unless environment
      (push (list type-1 type-2 (and subtype-p t) (and certain-p t)) *calls*))
    (values subtype-p certain-p)))

(in-package :common-lisp-user)

(defvar *extrinsic-symbols* (list 'subtypep-log:subtypep))

(defun compile-and-load (path &key force)
  (declare (ignore force))
  (load path))

(defun compile-and-load* (path &key force)
  (declare (ignore force))
  (load (concatenate 'string "auxiliary/" path)))

(load "rt-package.lsp")
(load "rt.lsp")
(load "cl-test-package.lsp")

(in-package :cl-test)

(load "auxiliary/ansi-aux-macros.lsp")
(load "notes.lsp")
(handler-bind ((warning #'muffle-warning))
  (load "universe.lsp"))
(load "auxiliary/random-aux.lsp")
(load "auxiliary/ansi-aux.lsp")
(load "auxiliary/types-aux.lsp")

(dolist (file '("types-and-classes/subtypep.lsp"
                "types-and-classes/subtypep-array.lsp"
                "types-and-classes/subtypep-complex.lsp"
                "types-and-classes/subtypep-cons.lsp"
                "types-and-classes/subtypep-eql.lsp"
                "types-and-classes/subtypep-float.lsp"
                "types-and-classes/subtypep-function.lsp"
                "types-and-classes/subtypep-integer.lsp"
                "types-and-classes/subtypep-member.lsp"
                "types-and-classes/subtypep-rational.lsp"
                "types-and-classes/subtypep-real.lsp"))
  (load file))

(do-tests)

(defun shared-literal-p (object)
  (not (or (symbolp object) (numberp object) (characterp object))))

(defun placeholders (record)
  "RECORD with each object an `eql` or `member` type names by identity
replaced by a placeholder symbol, consed onto the list of placeholders
and the objects they stand for. Printing loses identity, and the record
keeps it this way: zisp builds each object once and puts it back."
  (let ((objects nil)
        (count 0))
    (labels ((placeholder (object)
               (let ((known (rassoc object objects :test #'eq)))
                 (if known
                     (car known)
                     (let ((name (intern (format nil "%OBJECT-~d" (incf count)) :cl-test)))
                       (push (cons name object) objects)
                       name))))
             (walk (form)
               (cond ((not (consp form)) form)
                     ((member (car form) '(eql member))
                      (cons (car form)
                            (mapcar (lambda (object)
                                      (if (shared-literal-p object) (placeholder object) object))
                                    (cdr form))))
                     (t (mapcar #'walk form)))))
      (let ((walked (mapcar #'walk record)))
        (cons (reverse objects) walked)))))

(defun printed-line (record)
  "RECORD printed on one line, or nil where some part of it does not
print as something that reads back or names one of SBCL's own types."
  (let ((line (let ((*print-pretty* nil)
                    (*package* (find-package :cl-test)))
                (prin1-to-string (placeholders record)))))
    (if (or (search "#<" line) (search "SB-" line)) nil line)))

(with-open-file (out (sb-ext:posix-getenv "SUBTYPEP_SBCL_OUT")
                     :direction :output :if-exists :supersede)
  ;; Two calls on `equal` types can differ in which of their objects are
  ;; the same object, so calls are told apart by the printed record,
  ;; which shows that.
  (let ((lines (make-hash-table :test 'equal)))
    (dolist (call subtypep-log:*calls*)
      (let ((line (printed-line call)))
        (when line (setf (gethash line lines) t))))
    (dolist (line (sort (loop for line being the hash-keys of lines collect line) #'string<))
      (write-line line out))))
