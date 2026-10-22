;; Function and macro bodies: the block named after the function that
;; `return-from` reaches, and macros in tail position.

;; --- the implicit block ---

(progn
  (defun body-early-exit (x)
    (when (> x 10) (return-from body-early-exit :big))
    :small)
  (and (eq (body-early-exit 20) :big) (eq (body-early-exit 1) :small)))

(eq (flet ((early () (return-from early :flet) :after)) (early)) :flet)

(eq (labels ((early () (return-from early :labels) :after)) (early)) :labels)

(progn
  (defmacro body-early-macro () (return-from body-early-macro :macro) :after)
  (eq (body-early-macro) :macro))

(eq (macrolet ((early () (return-from early :macrolet) :after)) (early)) :macrolet)

;; A docstring and declarations stay ahead of the block, so the
;; declaration still makes the binding dynamic.
(progn
  (defvar *body-probe* :outer)
  (defun body-probe-reader () *body-probe*)
  (defun body-declared (*body-probe*)
    "Reads its own argument through a special binding."
    (declare (special *body-probe*))
    (return-from body-declared (body-probe-reader)))
  (eq (body-declared :inner) :inner))

(progn
  (defun body-documented ()
    "Says what it returns."
    (return-from body-documented :documented))
  (eq (body-documented) :documented))

;; A body that only returns its docstring keeps it as the value.
(progn
  (defun body-only-string () (if nil (return-from body-only-string 1)) "value")
  (equal (body-only-string) "value"))

;; --- macros in tail position ---

;; A macro call in tail position is expanded once for its call site, not
;; once for every call.
(progn
  (defvar *tail-expansions* 0)
  (defmacro counted-tail () (incf *tail-expansions*) :expanded)
  (defun calls-counted-tail () (counted-tail))
  (calls-counted-tail)
  (calls-counted-tail)
  (calls-counted-tail)
  (= *tail-expansions* 1))

;; Deep self recursion in tail position still runs in constant host
;; stack when the body has no `return-from`.
(progn
  (defun count-down (n) (cond ((= n 0) :done) (t (count-down (1- n)))))
  (eq (count-down 100000) :done))

;; --- constantp ---

(constantp 1)
(constantp "string")
(constantp :keyword)
(constantp nil)
(constantp ''quoted)
(constantp 'call-arguments-limit)
(not (constantp 'body-probe-variable))
(not (constantp '(car x)))
(eq (handler-case (constantp) (error () :signaled)) :signaled)
