;; What the long form of define-method-combination parses to: the
;; name, the lambda list, each method group specifier, the :arguments and
;; :generic-function options, the documentation, declarations and body.
;;
;; Each top-level form is self-checking and evaluates to T.

(let ((parsed (cl::%dmc-parse-long-form 'simple '() '((primary ())) '((call-method (car primary))))))
  (and (eq (getf parsed :name) 'simple)
       (null (getf parsed :lambda-list))
       (equal (getf parsed :groups) '((primary (nil) nil :most-specific-first nil nil)))
       (equal (getf parsed :body) '((call-method (car primary))))))

(let ((parsed (cl::%dmc-parse-long-form
               'ordered '(&optional (order :most-specific-first))
               '((around (:around)) (primary () :order order :required t))
               '(primary))))
  (and (equal (getf parsed :lambda-list) '(&optional (order :most-specific-first)))
       (equal (getf parsed :groups)
              '((around ((:around)) nil :most-specific-first nil nil)
                (primary (nil) nil order t nil)))))

(let ((parsed (cl::%dmc-parse-long-form 'by-predicate '() '((odd oddp-qualifiers) (rest *)) '(nil))))
  (equal (getf parsed :groups)
         '((odd nil oddp-qualifiers :most-specific-first nil nil)
           (rest (*) nil :most-specific-first nil nil))))

(let ((parsed (cl::%dmc-parse-long-form
               'with-options '() '((all * :description "every method"))
               '((:arguments object) (:generic-function gf) "The documentation." (declare (ignorable gf))
                 object))))
  (and (equal (getf parsed :arguments) '(object))
       (eq (getf parsed :generic-function) 'gf)
       (equal (getf parsed :documentation) "The documentation.")
       (equal (getf parsed :declarations) '((declare (ignorable gf))))
       (equal (getf parsed :body) '(object))
       (equal (nth 5 (car (getf parsed :groups))) "every method")))

(let ((parsed (cl::%dmc-parse-long-form 'multi '() '((tagged (:a) (:b :c) (:d *))) '(nil))))
  (equal (cadr (car (getf parsed :groups))) '((:a) (:b :c) (:d *))))

