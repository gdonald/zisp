;; A control string in the shape of a function, and the pieces that go
;; with running one: `formatter`, `assert`, and `values` reached as a
;; function rather than as a special form.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "format check failed: ~s" ',form)))

;; The function writes to the stream it is handed.
(check (string= "1-2" (with-output-to-string (s) (funcall (formatter "~a-~a") s 1 2))))

;; What comes back is the arguments it did not use.
(defvar *tail* nil)

(with-output-to-string (s) (setq *tail* (funcall (formatter "~a") s 1 2 3)))

(check (equal '(2 3) *tail*))

(with-output-to-string (s) (setq *tail* (funcall (formatter "~a ~a") s 1 2)))

(check (null *tail*))

;; `format` takes one for its control string, whatever the destination.
(check (string= "x7y" (format nil (formatter "x~ay") 7)))
(check (string= "x7y" (with-output-to-string (s) (format s (formatter "x~ay") 7))))

;; An assertion that holds is quiet, and one that fails signals.
(check (null (assert (= 1 1))))
(check (eq :caught (handler-case (assert (= 1 2)) (error (e) :caught))))
(check (eq :caught (handler-case (assert (= 1 2) () "no: ~a" 3) (error (e) :caught))))

;; `values` and `values-list` are functions as well as special forms.
(check (equal '(1 2) (multiple-value-list (apply #'values '(1 2)))))
(check (equal '(3 4) (multiple-value-list (funcall #'values-list '(3 4)))))
(check (equal '() (multiple-value-list (funcall #'values))))

;; What `functionp` says about each of the three things that can name a
;; function.
(check (functionp #'car))
(check (null (functionp 'car)))
(check (null (functionp '(lambda (x) x))))

;; zisp interprets, so `compile` hands back the function it was given and
;; reports neither warnings nor failure.
(defun twice (x) (* 2 x))

(check (equal '(twice nil nil) (multiple-value-list (compile 'twice))))
(check (= 42 (funcall (compile nil '(lambda (y) (* 2 y))) 21)))

;; A string coerced to each of the string types is still the same string.
(check (string= "abc" (coerce "abc" 'simple-base-string)))
(check (string= "abc" (coerce "abc" 'base-string)))
