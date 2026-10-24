;; The long form of define-method-combination: what it parses to, how
;; methods are sorted into groups, and the effective methods it builds.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

;;; sorting methods into groups

(progn
  (define-method-combination grouped ()
    ((exact (:exact))
     (pair (:first :second))
     (wild (:any *))
     (plain ())
     (other *))
    `(list ,@(mapcar (lambda (group-name group)
                       `(list ',group-name ,@(mapcar (lambda (m) `(call-method ,m)) group)))
                     '(exact pair wild plain other)
                     (list exact pair wild plain other))))
  (defgeneric sorted (x) (:method-combination grouped))
  (defmethod sorted :exact ((x integer)) :exact-method)
  (defmethod sorted :first :second ((x integer)) :pair-method)
  (defmethod sorted :any :thing ((x integer)) :wild-method)
  (defmethod sorted ((x integer)) :plain-method)
  (defmethod sorted :unmatched ((x integer)) :other-method)
  t)

(equal (assoc 'exact (sorted 1)) '(exact :exact-method))
(equal (assoc 'pair (sorted 1)) '(pair :pair-method))
(equal (assoc 'wild (sorted 1)) '(wild :wild-method))
(equal (assoc 'other (sorted 1)) '(other :other-method))

(progn
  (defun two-qualifiers-p (qualifiers) (= (length qualifiers) 2))
  (define-method-combination by-predicate ()
    ((two two-qualifiers-p)
     (one (*)))
    `(list (list ,@(mapcar (lambda (m) `(call-method ,m)) two))
           (list ,@(mapcar (lambda (m) `(call-method ,m)) one))))
  (defgeneric predicated (x) (:method-combination by-predicate))
  (defmethod predicated :a :b ((x integer)) :two)
  (defmethod predicated :c ((x integer)) :one)
  (equal (predicated 1) '((:two) (:one))))

(progn
  (define-method-combination strict () ((only (:only))) `(call-method ,(car only)))
  (defgeneric strictly (x) (:method-combination strict))
  (defmethod strictly :only ((x integer)) :fine)
  (defmethod strictly :stray ((x integer)) :never)
  (eq (handler-case (strictly 1) (error () :invalid-method)) :invalid-method))

(progn
  (define-method-combination needs-one () ((required () :required t)) `(call-method ,(car required)))
  (defgeneric needing (x) (:method-combination needs-one))
  (defmethod needing ((x integer)) :present)
  (and (eq (needing 1) :present)
       (eq (handler-case (needing 'a) (error () :missing)) :missing)))

;;; the effective method

(progn
  (define-method-combination reversed ()
    ((primary () :order :most-specific-last))
    `(list ,@(mapcar (lambda (m) `(call-method ,m)) primary)))
  (defgeneric reverse-order (x) (:method-combination reversed))
  (defmethod reverse-order ((x integer)) :integer)
  (defmethod reverse-order ((x number)) :number)
  (defmethod reverse-order ((x t)) :t)
  (equal (reverse-order 1) '(:t :number :integer)))

(progn
  (define-method-combination ordering (&optional (order :most-specific-first))
    ((primary () :order order))
    `(list ,@(mapcar (lambda (m) `(call-method ,m)) primary)))
  (defgeneric first-way (x) (:method-combination ordering))
  (defgeneric last-way (x) (:method-combination ordering :most-specific-last))
  (defmethod first-way ((x integer)) 1)
  (defmethod first-way ((x number)) 2)
  (defmethod last-way ((x integer)) 1)
  (defmethod last-way ((x number)) 2)
  (and (equal (first-way 1) '(1 2)) (equal (last-way 1) '(2 1))))

(progn
  (define-method-combination wrapped ()
    ((around (:around)) (primary ()))
    (let ((form `(call-method ,(car primary) ,(cdr primary))))
      (if around
          `(call-method ,(car around) (,@(cdr around) (make-method ,form)))
          form)))
  (defgeneric wrapping (x) (:method-combination wrapped))
  (defmethod wrapping ((x number)) (list :number))
  (defmethod wrapping ((x integer)) (cons :integer (call-next-method)))
  (defmethod wrapping :around ((x integer)) (list :around (call-next-method)))
  (equal (wrapping 1) '(:around (:integer :number))))

(progn
  (define-method-combination with-arguments ()
    ((primary ()))
    (:arguments object)
    `(if (integerp ,object)
         (call-method ,(car primary))
         :not-an-integer))
  (defgeneric argued (x) (:method-combination with-arguments))
  (defmethod argued ((x t)) :ran)
  (and (eq (argued 1) :ran) (eq (argued 'a) :not-an-integer)))

;;; compute-effective-method

(progn
  (define-method-combination tagged-list ()
    ((around (:around)) (primary ()))
    (let ((form `(list ,@(mapcar (lambda (m) `(call-method ,m)) primary))))
      (if around
          `(call-method ,(car around) (,@(cdr around) (make-method ,form)))
          form)))
  (defgeneric tagged (x) (:method-combination tagged-list))
  (defmethod tagged ((x integer)) :integer)
  (defmethod tagged ((x rational)) :rational)
  (defmethod tagged ((x number)) :number)
  (defmethod tagged :around ((x integer)) (list :around-result (call-next-method)))
  (equal (tagged 1) '(:around-result (:integer :rational :number))))

(let* ((gf #'tagged)
       (methods (compute-applicable-methods gf (list 1)))
       (form (compute-effective-method gf (generic-function-method-combination gf) methods)))
  (and (consp form)
       (eq (car form) 'call-method)
       (equal (method-qualifiers (cadr form)) '(:around))))
