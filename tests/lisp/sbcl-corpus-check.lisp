;; Run under SBCL, not zisp: `tests/run-corpus-sbcl.sh` loads this with
;; `*corpus*` naming a self-checking corpus. Each top-level form of the
;; corpus is evaluated, every one that does not come back T is printed,
;; and the last line is `SBCL-CORPUS forms failures`.

(defvar *corpus*)

(with-open-file (in *corpus*)
  (loop with failures = 0
        for index from 1
        for form = (read in nil in)
        until (eq form in)
        do (let ((got (eval form)))
             (unless (eq got t)
               (incf failures)
               (format t "FORM ~d: ~s~%" index got)))
        finally (format t "SBCL-CORPUS ~d ~d~%" (1- index) failures)))
