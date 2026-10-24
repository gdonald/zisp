;; validate-superclass decides which metaclasses can be mixed in a
;; class's superclasses.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

(eq (handler-case (progn (defclass from-built-in (integer) ()) :accepted)
      (error () :rejected))
    :rejected)
(progn
  (defclass permissive-class (standard-class) ())
  (defmethod validate-superclass ((class permissive-class) (super built-in-class)) t)
  (eq (handler-case (progn (defclass permitted (sequence) () (:metaclass permissive-class))
                           :accepted)
        (error () :rejected))
      :accepted))
(numberp (search "INTEGER"
                 (handler-case (progn (defclass names-the-superclass (integer) ()) "")
                   (error (e) (princ-to-string e)))))
