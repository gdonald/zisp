;; Generic functions, methods, method combinations and next methods.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn (use-package "ZISP-MOP") t)

;;; defgeneric

(typep (defgeneric area (shape)) 'standard-generic-function)
(eq (generic-function-name #'area) 'area)
(equal (generic-function-lambda-list #'area) '(shape))
(eq (handler-case (eval '(defgeneric car (x))) (program-error () :rejected)) :rejected)
(eq (handler-case (eval '(defgeneric bad-option (x) (:no-such-option 1))) (program-error () :rejected))
    :rejected)
(progn
  (defgeneric with-methods (x)
    (:method ((x integer)) :integer)
    (:method ((x symbol)) :symbol))
  (and (eq (with-methods 1) :integer) (eq (with-methods 'a) :symbol)))
(eq (handler-case (with-methods "string") (error () :no-method)) :no-method)

;;; defmethod lambda lists

(progn
  (defgeneric optional-args (a &optional b))
  (defmethod optional-args ((a integer) &optional (b 10)) (+ a b))
  (and (eql (optional-args 1) 11) (eql (optional-args 1 2) 3)))
(progn
  (defgeneric rest-args (a &rest more))
  (defmethod rest-args ((a integer) &rest more) (cons a more))
  (equal (rest-args 1 2 3) '(1 2 3)))
(progn
  (defgeneric key-args (a &key))
  (defmethod key-args ((a integer) &key (scale 1)) (* a scale))
  (defmethod key-args ((a float) &key (offset 0)) (+ a offset))
  (and (eql (key-args 2) 2) (eql (key-args 2 :scale 3) 6) (eql (key-args 1.0 :offset 1) 2.0)))
(eq (handler-case (key-args 2 :offset 1) (program-error () :rejected)) :rejected)
(eql (key-args 2 :offset 1 :allow-other-keys t) 2)
(eq (handler-case (eval '(defmethod optional-args ((a integer) b) a)) (program-error () :rejected))
    :rejected)
(progn
  (defmethod created-by-defmethod ((x integer) &optional y &key z) (list x y z))
  (equal (created-by-defmethod 1 2 :z 3) '(1 2 3)))

;;; specialization

(progn
  (defgeneric classify (x))
  (defmethod classify ((x t)) :thing)
  (defmethod classify ((x number)) :number)
  (defmethod classify ((x integer)) :integer)
  (defmethod classify ((x (eql 0))) :zero)
  (defmethod classify ((x null)) :null)
  (and (eq (classify 'a) :thing)
       (eq (classify 1.5) :number)
       (eq (classify 7) :integer)
       (eq (classify 0) :zero)
       (eq (classify nil) :null)))
(progn
  (defgeneric pair (a b))
  (defmethod pair ((a integer) (b t)) :integer-first)
  (defmethod pair ((a t) (b integer)) :integer-second)
  (and (eq (pair 1 1) :integer-first) (eq (pair 'x 1) :integer-second)))
(progn
  (defgeneric ordered-pair (a b) (:argument-precedence-order b a))
  (defmethod ordered-pair ((a integer) (b t)) :integer-first)
  (defmethod ordered-pair ((a t) (b integer)) :integer-second)
  (eq (ordered-pair 1 1) :integer-second))
(progn
  (defclass parent () ())
  (defclass child (parent) ())
  (defmethod classify ((x parent)) :parent)
  (defmethod classify ((x child)) (list :child (call-next-method)))
  (equal (classify (make-instance 'child)) '(:child :parent)))

;;; standard method combination

(progn
  (defvar *calls* nil)
  (defclass level-1 () ())
  (defclass level-2 (level-1) ())
  (defclass level-3 (level-2) ())
  (defgeneric combined (x))
  (defmethod combined :before ((x level-1)) (push :before-1 *calls*))
  (defmethod combined :before ((x level-2)) (push :before-2 *calls*))
  (defmethod combined :after ((x level-1)) (push :after-1 *calls*))
  (defmethod combined :after ((x level-2)) (push :after-2 *calls*))
  (defmethod combined :around ((x level-1))
    (push :around-1-in *calls*) (prog1 (call-next-method) (push :around-1-out *calls*)))
  (defmethod combined :around ((x level-2))
    (push :around-2-in *calls*) (prog1 (call-next-method) (push :around-2-out *calls*)))
  (defmethod combined ((x level-1)) (push :primary-1 *calls*) :result-1)
  (defmethod combined ((x level-2)) (push :primary-2 *calls*) (call-next-method))
  (defmethod combined ((x level-3)) (push :primary-3 *calls*) (call-next-method))
  (setq *calls* nil)
  (and (eq (combined (make-instance 'level-3)) :result-1)
       (equal (reverse *calls*)
              '(:around-2-in :around-1-in :before-2 :before-1
                :primary-3 :primary-2 :primary-1
                :after-1 :after-2 :around-1-out :around-2-out))))
(progn
  (defgeneric before-only (x))
  (defmethod before-only :before ((x integer)) nil)
  (eq (handler-case (before-only 1) (error () :no-primary)) :no-primary))

;;; built-in method combinations

(progn
  (defgeneric summed (x) (:method-combination +))
  (defmethod summed + ((x integer)) 1)
  (defmethod summed + ((x rational)) 10)
  (defmethod summed + ((x number)) 100)
  (eql (summed 5) 111))
(progn
  (defgeneric all-of (x) (:method-combination and))
  (defmethod all-of and ((x integer)) t)
  (defmethod all-of and ((x rational)) :rational)
  (defmethod all-of and ((x number)) :number)
  (eq (all-of 5) :number))
(progn
  (defgeneric any-of (x) (:method-combination or))
  (defmethod any-of or ((x integer)) nil)
  (defmethod any-of or ((x rational)) :rational)
  (defmethod any-of or ((x number)) :number)
  (eq (any-of 5) :rational))
(progn
  (defgeneric listed (x) (:method-combination list))
  (defmethod listed list ((x integer)) :integer)
  (defmethod listed list ((x rational)) :rational)
  (defmethod listed list ((x number)) :number)
  (equal (listed 5) '(:integer :rational :number)))
(progn
  (defgeneric listed-last (x) (:method-combination list :most-specific-last))
  (defmethod listed-last list ((x integer)) :integer)
  (defmethod listed-last list ((x rational)) :rational)
  (defmethod listed-last list ((x number)) :number)
  (equal (listed-last 5) '(:number :rational :integer)))
(progn
  (defgeneric appended (x) (:method-combination append))
  (defmethod appended append ((x integer)) (list 1))
  (defmethod appended append ((x rational)) (list 2))
  (defmethod appended append ((x number)) (list 3))
  (equal (appended 5) '(1 2 3)))
(progn
  (defgeneric nconced (x) (:method-combination nconc))
  (defmethod nconced nconc ((x integer)) (list 1))
  (defmethod nconced nconc ((x rational)) (list 2))
  (defmethod nconced nconc ((x number)) (list 3))
  (equal (nconced 5) '(1 2 3)))
(progn
  (defgeneric smallest (x) (:method-combination min))
  (defmethod smallest min ((x integer)) 3)
  (defmethod smallest min ((x rational)) 1)
  (defmethod smallest min ((x number)) 2)
  (eql (smallest 5) 1))
(progn
  (defgeneric largest (x) (:method-combination max))
  (defmethod largest max ((x integer)) 3)
  (defmethod largest max ((x rational)) 1)
  (defmethod largest max ((x number)) 2)
  (eql (largest 5) 3))
(progn
  (defvar *progn-calls* nil)
  (defgeneric sequenced (x) (:method-combination progn))
  (defmethod sequenced progn ((x integer)) (push :integer *progn-calls*) 1)
  (defmethod sequenced progn ((x rational)) (push :rational *progn-calls*) 2)
  (defmethod sequenced progn ((x number)) (push :number *progn-calls*) 3)
  (and (eql (sequenced 5) 3) (equal *progn-calls* '(:number :rational :integer))))
(progn
  (defgeneric standard-named (x) (:method-combination standard))
  (defmethod standard-named ((x integer)) (list* :integer (call-next-method)))
  (defmethod standard-named ((x rational)) (list* :rational (call-next-method)))
  (defmethod standard-named ((x number)) (list :number))
  (equal (standard-named 1) '(:integer :rational :number)))
(progn
  (defgeneric summed-around (x) (:method-combination +))
  (defmethod summed-around + ((x integer)) 1)
  (defmethod summed-around + ((x number)) 2)
  (defmethod summed-around :around ((x integer)) (* 10 (call-next-method)))
  (eql (summed-around 5) 30))
(progn
  (defgeneric badly-qualified (x) (:method-combination +))
  (defmethod badly-qualified :before ((x integer)) 1)
  (eq (handler-case (badly-qualified 1) (error () :invalid)) :invalid))

;;; define-method-combination, short form

(progn
  (define-method-combination all-true :identity-with-one-argument t :operator and)
  (defgeneric four-way (x) (:method-combination all-true))
  (defmethod four-way all-true ((x integer)) :integer)
  (defmethod four-way all-true ((x rational)) :rational)
  (defmethod four-way all-true ((x real)) :real)
  (defmethod four-way all-true ((x number)) :number)
  (eq (four-way 1) :number))
(progn
  (define-method-combination my-and :identity-with-one-argument t)
  (defun my-and (&rest values) (every #'identity values))
  (defgeneric five-way (x) (:method-combination my-and))
  (defmethod five-way my-and ((x integer)) t)
  (defmethod five-way my-and ((x rational)) t)
  (defmethod five-way my-and ((x real)) t)
  (defmethod five-way my-and ((x number)) t)
  (defmethod five-way my-and ((x t)) (numberp x))
  (and (eq (five-way 1) t) (null (five-way 'a))))

;;; next methods

(progn
  (defgeneric chained (x &optional tag))
  (defmethod chained ((x integer) &optional (tag :none)) (list :integer x tag))
  (defmethod chained :around ((x integer) &optional tag)
    (declare (ignore tag))
    (call-next-method (1+ x) :changed))
  (equal (chained 1) '(:integer 2 :changed)))
(progn
  (defgeneric rechained (x))
  (defmethod rechained ((x t)) x)
  (defmethod rechained ((x (eql 0))) (call-next-method 1))
  (eq (handler-case (rechained 0) (error () :different-methods)) :different-methods))
(progn
  (defgeneric probing (x))
  (defmethod probing ((x integer)) (next-method-p))
  (defmethod probing ((x (eql 3))) (list (next-method-p) (call-next-method)))
  (and (equal (probing 3) '(t nil)) (null (probing 4))))
(progn
  (defgeneric no-next (x))
  (defmethod no-next ((x integer)) (call-next-method))
  (eq (handler-case (no-next 1) (error () :no-next-method)) :no-next-method))
(progn
  (defgeneric next-as-function (x))
  (defmethod next-as-function ((x number)) (list :number x))
  (defmethod next-as-function ((x integer)) (funcall #'call-next-method))
  (equal (next-as-function 5) '(:number 5)))
(progn
  (defmethod no-next-method ((gf (eql #'no-next)) method &rest args)
    (declare (ignore method))
    (list :handled args))
  (equal (no-next 1) '(:handled (1))))
(progn
  (defgeneric unhandled (x))
  (defmethod no-applicable-method ((gf (eql #'unhandled)) &rest args) (list :no-method args))
  (equal (unhandled 1) '(:no-method (1))))

;;; adding, finding and removing methods

(let ((method (find-method #'classify nil (list (find-class 'integer)))))
  (and (typep method 'standard-method)
       (equal (method-qualifiers method) nil)
       (equal (method-specializers method) (list (find-class 'integer)))))
(null (find-method #'classify '(:before) (list (find-class 'integer)) nil))
(progn
  (remove-method #'classify (find-method #'classify nil (list (find-class 'integer))))
  (eq (classify 7) :number))
(progn
  (defmethod classify ((x integer)) :integer-again)
  (defmethod classify ((x integer)) :replaced)
  (eq (classify 7) :replaced))
(let ((specializer (car (method-specializers
                         (find-method #'classify nil (list (intern-eql-specializer 0)))))))
  (eql (eql-specializer-object specializer) 0))
(equal (multiple-value-list (function-keywords (find-method #'key-args nil (list (find-class 'integer)))))
       '((:scale) nil))
