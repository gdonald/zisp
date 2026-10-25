;; Compiled to the fasls beside it by an aarch64 zisp and an x86_64 one.
;; `tests/run-fasl-fixtures.sh` writes them, and the compile-file tests
;; load each one on whatever machine the tests run on.

(defvar *cross-loaded* 0)

(defmacro cross-twice (form) `(* 2 ,form))

(defun cross-literals ()
  (list 1 -7 123456789012345678901234567890 -98765432109876543210 3/4 #c(1 2)
        1.5 2.25d0 #\a #\λ "strings with λ" :keyword 'cross-symbol
        '(nested (list . dotted)) #(1 "two" three) #*1011
        (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(1 2 255))))

(defun cross-arguments (a &optional (b 10) &rest more &key (c (cross-twice a)) &allow-other-keys)
  (list a b more c))

(let ((count 0))
  (defun cross-count () count)
  (defun cross-bump () (incf count)))

(defun cross-exits (list)
  (block found
    (dolist (x list)
      (when (minusp x) (return-from found x)))
    (catch :tag
      (unwind-protect (throw :tag :thrown)
        (incf *cross-loaded* 100)))))

(incf *cross-loaded*)
