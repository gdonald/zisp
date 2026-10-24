;; print-object is how every printing operation prints an instance, at
;; the top level and wherever the printer meets one inside something
;; else.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defclass my-class () ((name :initarg :name)))
  (defmethod print-object ((x my-class) stream)
    (format stream "<MY ~A>" (slot-value x 'name)))
  (defclass holder () ((held :initarg :held)))
  (defmethod print-object ((x holder) stream)
    (format stream "<HOLDING ~S>" (slot-value x 'held)))
  (defvar *mine* (make-instance 'my-class :name "a"))
  t)

;; 1. At the top level.
(equal (prin1-to-string *mine*) "<MY a>")
(equal (princ-to-string *mine*) "<MY a>")
(equal (with-output-to-string (s) (print *mine* s)) (format nil "~%<MY a> "))

;; 2. Inside a list.
(equal (prin1-to-string (list 1 *mine* (list *mine*))) "(1 <MY a> (<MY a>))")

;; 3. Inside a vector.
(equal (prin1-to-string (vector *mine* 2)) "#(<MY a> 2)")

;; 4. As a slot value another instance's method prints.
(equal (prin1-to-string (make-instance 'holder :held *mine*)) "<HOLDING <MY a>>")
(equal (prin1-to-string (make-instance 'holder :held (list *mine*))) "<HOLDING (<MY a>)>")

;; 5. Through format's ~A and ~S.
(equal (format nil "~A and ~S" *mine* *mine*) "<MY a> and <MY a>")
(equal (format nil "~{~A~^, ~}" (list *mine* *mine*)) "<MY a>, <MY a>")

;; *print-escape* is what the method sees.
(progn
  (defclass escapes () ())
  (defmethod print-object ((x escapes) stream)
    (write-string (if *print-escape* "escaped" "plain") stream))
  (and (equal (prin1-to-string (make-instance 'escapes)) "escaped")
       (equal (princ-to-string (make-instance 'escapes)) "plain")
       (equal (format nil "~A ~S" (make-instance 'escapes) (make-instance 'escapes))
              "plain escaped")))

;; An error inside a method reaches the caller as itself.
(progn
  (defclass broken-printer () ())
  (defmethod print-object ((x broken-printer) stream)
    (declare (ignore stream))
    (error "printing failed"))
  (equal (handler-case (prin1-to-string (make-instance 'broken-printer))
           (simple-error (e) (princ-to-string e)))
         "printing failed"))

;; The default method names the class and is not readable.
(progn
  (defclass plain-instance () ())
  (let ((text (prin1-to-string (make-instance 'plain-instance))))
    (and (eql (search "#<PLAIN-INSTANCE" text) 0)
         (char= (char text (1- (length text))) #\>))))
(eq (handler-case (let ((*print-readably* t)) (prin1-to-string (make-instance 'plain-instance)))
      (print-not-readable () :not-readable))
    :not-readable)

;; Classes and generic functions print with their names.
(equal (prin1-to-string (find-class 'plain-instance)) "#<STANDARD-CLASS PLAIN-INSTANCE>")
(equal (prin1-to-string #'print-object) "#<STANDARD-GENERIC-FUNCTION PRINT-OBJECT>")

;; A condition prints its report without escapes.
(equal (princ-to-string (make-condition 'simple-error :format-control "x ~A" :format-arguments '(1)))
       "x 1")
(equal (prin1-to-string (make-condition 'simple-error)) "#<SIMPLE-ERROR>")

;; print-unreadable-object
(progn
  (defclass unreadable () ())
  (defmethod print-object ((x unreadable) stream)
    (print-unreadable-object (x stream :type t) (write-string "body" stream)))
  (equal (prin1-to-string (make-instance 'unreadable)) "#<UNREADABLE body>"))

;;; describe

(progn
  (defclass described () ((a :initarg :a) (b)))
  (let ((text (with-output-to-string (s) (describe (make-instance 'described :a 1) s))))
    (and (search "DESCRIBED" text) (search "A = 1" text) (search "B is unbound" text) t)))
(progn
  (defmethod describe-object ((x described) stream) (write-string "custom description" stream))
  (equal (with-output-to-string (s) (describe (make-instance 'described) s)) "custom description"))
(numberp (search "is of type" (with-output-to-string (s) (describe 5 s))))
