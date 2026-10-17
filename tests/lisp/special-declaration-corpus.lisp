;; Local special declarations: a binding declared special is dynamic, and
;; a reference declared special reads the dynamic value past any lexical
;; binding around it.

(eq (let ((local-dynamic :outer))
      (declare (special local-dynamic))
      (let ((reader (lambda () (declare (special local-dynamic)) local-dynamic)))
        (let ((local-dynamic :inner))
          (declare (special local-dynamic))
          (funcall reader))))
    :inner)

(equal (let ((shadow 1))
         (let ((shadow 2))
           (declare (special shadow))
           (list shadow (symbol-value 'shadow))))
       '(2 2))

(= (let ((free-reference 1))
     (setf (symbol-value 'free-reference) 5)
     (flet ((dynamic-read () (declare (special free-reference)) free-reference))
       (dynamic-read)))
   5)

(= (let ((assigned 1))
     (let ((assigned 2))
       (declare (special assigned))
       (setq assigned 3))
     assigned)
   1)

(eq (progn
      (defun read-declared-parameter () (symbol-value 'declared-parameter))
      (defun bind-declared-parameter (declared-parameter)
        (declare (special declared-parameter))
        (read-declared-parameter))
      (bind-declared-parameter :bound))
    :bound)

(eq (let* ((first-binding :one)
           (second-binding first-binding))
      (declare (special second-binding))
      (symbol-value 'second-binding))
    :one)

(equal (with-output-to-string (*error-output*)
         (funcall (lambda () (format *error-output* "captured"))))
       "captured")

(equal (with-output-to-string (*standard-output*)
         (funcall (lambda () (princ "captured"))))
       "captured")
