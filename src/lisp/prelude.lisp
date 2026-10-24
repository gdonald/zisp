;; Boot prelude: standard macros defined in Lisp, loaded after the native
;; builtins are registered. Expansions bottom out in the if / progn / let
;; special forms.
;;
;; Everything here is read in COMMON-LISP so the standard names it defines
;; are inherited by every package that uses CL. The export list at the end
;; keeps the `%`-prefixed helpers internal.

(in-package "COMMON-LISP")

(defconstant lambda-list-keywords
  '(&allow-other-keys &aux &body &environment &key &optional &rest &whole))

;; No fixed cap on argument or value counts: a call is limited only by what
;; a fixnum can index.
(defconstant call-arguments-limit most-positive-fixnum)
(defconstant lambda-parameters-limit most-positive-fixnum)
(defconstant multiple-values-limit most-positive-fixnum)

(defmacro when (test &body body)
  `(if ,test (progn ,@body) nil))

(defmacro unless (test &body body)
  `(if ,test nil (progn ,@body)))

(defmacro cond (&rest clauses)
  (if (null clauses)
      nil
      (let ((clause (car clauses)))
        (if (atom clause)
            (error "COND clause is not a list: ~s" clause)
            (if (cdr clause)
                `(if ,(car clause)
                     (progn ,@(cdr clause))
                     (cond ,@(cdr clauses)))
                (let ((tmp (gensym)))
                  `(let ((,tmp ,(car clause)))
                     (if ,tmp ,tmp (cond ,@(cdr clauses))))))))))

(defmacro and (&rest forms)
  (if (null forms)
      t
      (if (null (cdr forms))
          (car forms)
          `(if ,(car forms) (and ,@(cdr forms)) nil))))

(defmacro or (&rest forms)
  (if (null forms)
      nil
      (if (null (cdr forms))
          (car forms)
          (let ((tmp (gensym)))
            `(let ((,tmp ,(car forms)))
               (if ,tmp ,tmp (or ,@(cdr forms))))))))

(defmacro prog1 (first-form &body body)
  (let ((tmp (gensym)))
    `(let ((,tmp ,first-form))
       ,@body
       ,tmp)))

(defmacro prog2 (first-form second-form &body body)
  `(progn ,first-form (prog1 ,second-form ,@body)))

(defmacro case (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (cond
         ,@(mapcar
            (lambda (clause)
              (if (atom clause)
                  (error "CASE clause is not a list: ~s" clause)
                  (let ((keys (car clause)))
                    (if (or (eq keys 't) (eq keys 'otherwise))
                        `(t ,@(cdr clause))
                        (if (listp keys)
                            `((or ,@(mapcar (lambda (key) `(eql ,tmp ',key)) keys))
                              ,@(cdr clause))
                            `((eql ,tmp ',keys) ,@(cdr clause)))))))
            clauses)))))

(defun %case-keys (clauses)
  "Every key the clauses of a `case` name, for the type a ccase error expects."
  (mapcan (lambda (clause)
            (let ((keys (car clause)))
              (if (listp keys) (copy-list keys) (list keys))))
          clauses))

(defmacro ecase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (case ,tmp
         ,@clauses
         (otherwise (error 'type-error
                           :datum ,tmp
                           :expected-type '(member ,@(%case-keys clauses))))))))

(defmacro ccase (keyplace &rest clauses)
  (let ((block (gensym "CCASE"))
        (current (gensym "VALUE"))
        (new (gensym "NEW"))
        (stream (gensym "STREAM")))
    `(block ,block
       (loop
         (let ((,current ,keyplace))
           (case ,current
             ,@(mapcar (lambda (clause)
                         `(,(car clause) (return-from ,block (progn ,@(cdr clause)))))
                       clauses))
           (restart-case
               (error 'type-error
                      :datum ,current
                      :expected-type '(member ,@(%case-keys clauses)))
             (store-value (,new)
               :report (lambda (,stream)
                         (format ,stream "Supply a new value for ~S." ',keyplace))
               :interactive %prompt-for-value
               (setf ,keyplace ,new))))))))

(defmacro typecase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (cond
         ,@(mapcar
            (lambda (clause)
              (if (atom clause)
                  (error "TYPECASE clause is not a list: ~s" clause)
                  (if (or (eq (car clause) 't) (eq (car clause) 'otherwise))
                      `(t ,@(cdr clause))
                      `((typep ,tmp ',(car clause)) ,@(cdr clause)))))
            clauses)))))

(defmacro etypecase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (typecase ,tmp
         ,@clauses
         (otherwise (error 'type-error
                           :datum ,tmp
                           :expected-type '(or ,@(mapcar #'car clauses))))))))

(defmacro ctypecase (keyplace &rest clauses)
  (let ((block (gensym "CTYPECASE"))
        (current (gensym "VALUE"))
        (new (gensym "NEW"))
        (stream (gensym "STREAM")))
    `(block ,block
       (loop
         (let ((,current ,keyplace))
           (typecase ,current
             ,@(mapcar (lambda (clause)
                         `(,(car clause) (return-from ,block (progn ,@(cdr clause)))))
                       clauses))
           (restart-case
               (error 'type-error
                      :datum ,current
                      :expected-type '(or ,@(mapcar #'car clauses)))
             (store-value (,new)
               :report (lambda (,stream)
                         (format ,stream "Supply a new value for ~S." ',keyplace))
               :interactive %prompt-for-value
               (setf ,keyplace ,new))))))))

;; --- setf ---

(defun %pair-lists (names forms)
  (mapcar (lambda (name form) (list name form)) names forms))

(defun get-setf-expansion (place &optional env)
  (if (symbolp place)
      (let ((store (gensym)))
        (values nil nil (list store) `(setq ,place ,store) place))
      (let ((expander (get (car place) '%setf-expander)))
        (if expander
            (funcall expander place env)
            (multiple-value-bind (expansion expanded) (macroexpand-1 place env)
              (if expanded
                  (get-setf-expansion expansion env)
                  (%setf-function-expansion place)))))))

(defun %setf-function-expansion (place)
  "CLHS 5.1.2.9: a place with no expander that is not a macro form is a
call to the function named `(setf accessor)`, given the new value first."
  (let ((temps (mapcar (lambda (arg) (declare (ignore arg)) (gensym)) (cdr place)))
        (store (gensym)))
    (values temps (cdr place) (list store)
            `(funcall #'(setf ,(car place)) ,store ,@temps)
            `(,(car place) ,@temps))))

(defun %setf-expand-1 (place val-form)
  (if (symbolp place)
      `(setq ,place ,val-form)
      (multiple-value-bind (temps vals stores store-form access-form)
          (get-setf-expansion place)
        (declare (ignore access-form))
        `(let* ,(%pair-lists temps vals)
           (multiple-value-bind ,stores ,val-form
             ,store-form)))))

(defun %setf-pairs (pairs)
  (if (null pairs)
      nil
      (cons (%setf-expand-1 (car pairs) (cadr pairs))
            (%setf-pairs (cddr pairs)))))

(defmacro setf (&rest pairs)
  (cond ((null pairs) nil)
        ((null (cdr pairs)) (error "odd number of arguments to SETF"))
        ((null (cddr pairs)) (%setf-expand-1 (car pairs) (cadr pairs)))
        (t `(progn ,@(%setf-pairs pairs)))))

(defun %make-short-setf-expander (accessor update)
  (lambda (place env)
    (declare (ignore env))
    (let ((temps (mapcar (lambda (arg) (declare (ignore arg)) (gensym)) (cdr place)))
          (store (gensym)))
      (values temps (cdr place) (list store)
              `(,update ,@temps ,store)
              `(,accessor ,@temps)))))

(defun %make-long-setf-expander (accessor stores expansion-fn)
  (lambda (place env)
    (declare (ignore env))
    (let ((temps (mapcar (lambda (arg) (declare (ignore arg)) (gensym)) (cdr place)))
          (store-syms (mapcar (lambda (store) (declare (ignore store)) (gensym)) stores)))
      (values temps (cdr place) store-syms
              (funcall expansion-fn temps store-syms)
              `(,accessor ,@temps)))))

(defmacro defsetf (accessor second &rest rest)
  (if (symbolp second)
      `(progn
         (%put ',accessor '%setf-expander (%make-short-setf-expander ',accessor ',second))
         ',accessor)
      `(progn
         (%put ',accessor '%setf-expander
               (%make-long-setf-expander ',accessor ',(car rest)
                                          (lambda (%temps %stores)
                                            (destructuring-bind ,second %temps
                                              (destructuring-bind ,(car rest) %stores
                                                ,@(cdr rest))))))
         ',accessor)))

(defmacro define-setf-expander (accessor lambda-list &body body)
  (let ((expander (gensym)))
    `(progn
       (defmacro ,expander ,lambda-list ,@body)
       (%put ',accessor '%setf-expander (macro-function ',expander))
       ',accessor)))

;; Built-in places. Store forms return the new value.

(defsetf car (cell) (new) `(progn (rplaca ,cell ,new) ,new))
(defsetf cdr (cell) (new) `(progn (rplacd ,cell ,new) ,new))
(defsetf nth (n list) (new) `(progn (rplaca (nthcdr ,n ,list) ,new) ,new))

;; setf on the compound accessors: the first letter picks which half
;; of the innermost cons to replace, and the rest is the path to it.
(defsetf caar (x) (v) `(progn (rplaca (car ,x) ,v) ,v))
(defsetf cadr (x) (v) `(progn (rplaca (cdr ,x) ,v) ,v))
(defsetf cdar (x) (v) `(progn (rplacd (car ,x) ,v) ,v))
(defsetf cddr (x) (v) `(progn (rplacd (cdr ,x) ,v) ,v))
(defsetf caaar (x) (v) `(progn (rplaca (caar ,x) ,v) ,v))
(defsetf caadr (x) (v) `(progn (rplaca (cadr ,x) ,v) ,v))
(defsetf cadar (x) (v) `(progn (rplaca (cdar ,x) ,v) ,v))
(defsetf caddr (x) (v) `(progn (rplaca (cddr ,x) ,v) ,v))
(defsetf cdaar (x) (v) `(progn (rplacd (caar ,x) ,v) ,v))
(defsetf cdadr (x) (v) `(progn (rplacd (cadr ,x) ,v) ,v))
(defsetf cddar (x) (v) `(progn (rplacd (cdar ,x) ,v) ,v))
(defsetf cdddr (x) (v) `(progn (rplacd (cddr ,x) ,v) ,v))
(defsetf caaaar (x) (v) `(progn (rplaca (caaar ,x) ,v) ,v))
(defsetf caaadr (x) (v) `(progn (rplaca (caadr ,x) ,v) ,v))
(defsetf caadar (x) (v) `(progn (rplaca (cadar ,x) ,v) ,v))
(defsetf caaddr (x) (v) `(progn (rplaca (caddr ,x) ,v) ,v))
(defsetf cadaar (x) (v) `(progn (rplaca (cdaar ,x) ,v) ,v))
(defsetf cadadr (x) (v) `(progn (rplaca (cdadr ,x) ,v) ,v))
(defsetf caddar (x) (v) `(progn (rplaca (cddar ,x) ,v) ,v))
(defsetf cadddr (x) (v) `(progn (rplaca (cdddr ,x) ,v) ,v))
(defsetf cdaaar (x) (v) `(progn (rplacd (caaar ,x) ,v) ,v))
(defsetf cdaadr (x) (v) `(progn (rplacd (caadr ,x) ,v) ,v))
(defsetf cdadar (x) (v) `(progn (rplacd (cadar ,x) ,v) ,v))
(defsetf cdaddr (x) (v) `(progn (rplacd (caddr ,x) ,v) ,v))
(defsetf cddaar (x) (v) `(progn (rplacd (cdaar ,x) ,v) ,v))
(defsetf cddadr (x) (v) `(progn (rplacd (cdadr ,x) ,v) ,v))
(defsetf cdddar (x) (v) `(progn (rplacd (cddar ,x) ,v) ,v))
(defsetf cddddr (x) (v) `(progn (rplacd (cdddr ,x) ,v) ,v))
(defsetf elt %set-elt)
(defsetf aref %set-aref)
(defsetf svref %set-svref)
(defsetf row-major-aref %set-row-major-aref)
(defsetf fill-pointer %set-fill-pointer)
(defsetf logical-pathname-translations %set-logical-pathname-translations)
(defsetf char %set-char)
(defsetf schar %set-char)
(defsetf symbol-value %set-symbol-value)
(defsetf symbol-function %set-symbol-function)
(defsetf symbol-plist %set-symbol-plist)
(defsetf fdefinition %set-fdefinition)

(defsetf gethash (key table &optional default) (new)
  (declare (ignore default))
  `(%puthash ,key ,table ,new))

(defsetf get (sym indicator &optional default) (new)
  (declare (ignore default))
  `(%put ,sym ,indicator ,new))

;; --- place-modifying macros ---

(defmacro push (item place)
  (if (symbolp place)
      `(setq ,place (cons ,item ,place))
      (multiple-value-bind (temps vals stores store-form access-form)
          (get-setf-expansion place)
        (let ((item-temp (gensym)))
          `(let* ((,item-temp ,item)
                  ,@(%pair-lists temps vals)
                  (,(car stores) (cons ,item-temp ,access-form)))
             ,store-form)))))

(defmacro pop (place)
  (if (symbolp place)
      (let ((old (gensym)))
        `(let ((,old ,place))
           (setq ,place (cdr ,old))
           (car ,old)))
      (multiple-value-bind (temps vals stores store-form access-form)
          (get-setf-expansion place)
        (let ((old (gensym)))
          `(let* (,@(%pair-lists temps vals)
                  (,old ,access-form)
                  (,(car stores) (cdr ,old)))
             ,store-form
             (car ,old))))))

(defun %getf-form (plist indicator)
  (if (null plist)
      nil
      (if (eq (car plist) indicator)
          (cadr plist)
          (%getf-form (cddr plist) indicator))))

;; member keys only the list elements, so pushnew keys the item itself
;; before the membership test (adjoin semantics, CLHS 5.1.2.5).
(defmacro pushnew (item place &rest keys)
  (let* ((keyfn (%getf-form keys :key))
         (item-temp (gensym))
         (probe (if keyfn `(funcall ,keyfn ,item-temp) item-temp)))
    (if (symbolp place)
        `(let ((,item-temp ,item))
           (if (member ,probe ,place ,@keys)
               ,place
               (setq ,place (cons ,item-temp ,place))))
        (multiple-value-bind (temps vals stores store-form access-form)
            (get-setf-expansion place)
          (let ((list-temp (gensym)))
            `(let* ((,item-temp ,item)
                    ,@(%pair-lists temps vals)
                    (,list-temp ,access-form))
               (if (member ,probe ,list-temp ,@keys)
                   ,list-temp
                   (let ((,(car stores) (cons ,item-temp ,list-temp)))
                     ,store-form))))))))

(defmacro incf (place &optional (delta 1))
  (if (symbolp place)
      `(setq ,place (+ ,place ,delta))
      (multiple-value-bind (temps vals stores store-form access-form)
          (get-setf-expansion place)
        `(let* (,@(%pair-lists temps vals)
                (,(car stores) (+ ,access-form ,delta)))
           ,store-form))))

(defmacro decf (place &optional (delta 1))
  (if (symbolp place)
      `(setq ,place (- ,place ,delta))
      (multiple-value-bind (temps vals stores store-form access-form)
          (get-setf-expansion place)
        `(let* (,@(%pair-lists temps vals)
                (,(car stores) (- ,access-form ,delta)))
           ,store-form))))

;; --- psetf, rotatef, shiftf, multiple-value-setq ---

(defun %place-expansions (places)
  (mapcar (lambda (place) (multiple-value-list (get-setf-expansion place))) places))

(defmacro psetf (&rest pairs)
  "Every place's subforms and its new value are evaluated left to right,
and only then are the places stored into."
  (when (oddp (length pairs))
    (error "odd number of arguments to PSETF"))
  (let ((steps nil))
    (do ((walk pairs (cddr walk)))
        ((null walk))
      (push (cons (multiple-value-list (get-setf-expansion (car walk))) (cadr walk)) steps))
    (setq steps (nreverse steps))
    (let ((body `(progn ,@(mapcar (lambda (step) (nth 3 (car step))) steps) nil)))
      (dolist (step (reverse steps) body)
        (destructuring-bind ((temps vals stores store-form access-form) . value) step
          (declare (ignore store-form access-form))
          (setq body `(let* ,(%pair-lists temps vals)
                        (multiple-value-bind ,stores ,value ,body))))))))

(defmacro rotatef (&rest places)
  (if (null places)
      nil
      (let* ((expansions (%place-expansions places))
             (bindings (mapcan (lambda (e) (%pair-lists (first e) (second e))) expansions))
             (rotated (append (cdr expansions) (list (car expansions))))
             (body `(progn ,@(mapcar #'fourth expansions) nil)))
        (mapc (lambda (target source)
                (setq body `(multiple-value-bind ,(third target) ,(fifth source) ,body)))
              (reverse expansions) (reverse rotated))
        `(let* ,bindings ,body))))

(defmacro shiftf (&rest places-and-value)
  (let* ((places (butlast places-and-value))
         (new-value (car (last places-and-value)))
         (expansions (%place-expansions places))
         (bindings (mapcan (lambda (e) (%pair-lists (first e) (second e))) expansions))
         (old (gensym "OLD"))
         (sources (append (mapcar #'fifth (cdr expansions)) (list new-value)))
         (body `(progn ,@(mapcar #'fourth expansions) ,old)))
    (mapc (lambda (target source)
            (setq body `(multiple-value-bind ,(third target) ,source ,body)))
          (reverse expansions) (reverse sources))
    `(let* (,@bindings (,old ,(fifth (car expansions))))
       ,body)))

(defmacro multiple-value-setq (variables form)
  (let ((values (gensym "VALUES")))
    `(let ((,values (multiple-value-list ,form)))
       ,@(let ((index -1))
           (mapcar (lambda (variable)
                     (setq index (1+ index))
                     `(setf ,variable (nth ,index ,values)))
                   variables))
       (car ,values))))

(defun (setf aref) (new-value array &rest subscripts)
  (apply #'%set-aref array (append subscripts (list new-value))))

(define-setf-expander apply (function &rest arguments)
  "`(setf (apply #'name ...) new)` calls `(setf name)` with the new value
first and the arguments spread the way `apply` spreads them."
  (unless (and (consp function) (eq (car function) 'function))
    (error "setf of apply needs a function named with #', given ~S." function))
  (let ((temps (mapcar (lambda (argument) (declare (ignore argument)) (gensym)) arguments))
        (store (gensym "NEW")))
    (values temps arguments (list store)
            `(apply #'(setf ,(cadr function)) ,store ,@temps)
            `(apply ,function ,@temps))))

;; --- defstruct ---

(defun %struct-string (x)
  (format nil "~A" x))

(defun %struct-symbol (prefix suffix)
  (intern (format nil "~A~A" prefix suffix)))

(defun %struct-option (options key default)
  (labels ((scan (rest)
             (cond ((null rest) default)
                   ((eq (car rest) key) default)
                   ((and (consp (car rest)) (eq (car (car rest)) key))
                    (if (consp (cdr (car rest))) (car (cdr (car rest))) default))
                   (t (scan (cdr rest))))))
    (scan options)))

(defun %struct-check-options (options)
  (labels ((scan (rest)
             (unless (null rest)
               (let ((key (if (consp (car rest)) (car (car rest)) (car rest))))
                 (unless (member key '(:conc-name :constructor :predicate :copier :include
                                       :print-function :print-object))
                   (error "defstruct option ~S is not supported" key)))
               (scan (cdr rest)))))
    (scan options)))

(defun %struct-slot-name (slot)
  (if (consp slot) (car slot) slot))

(defun %struct-slot-initform (slot)
  (if (consp slot) (car (cdr slot)) nil))

(defun %struct-description (slot)
  "A slot description as (name initform)."
  (list (%struct-slot-name slot) (%struct-slot-initform slot)))

(defun %struct-include (options)
  "The (:include name override...) option, or nil."
  (dolist (option options nil)
    (when (and (consp option) (eq (car option) :include))
      (return option))))

(defun %struct-included-descriptions (include)
  "The slot descriptions a structure takes from the one it includes, each
override given in the :include option replacing the included initform."
  (when include
    (let ((parent (cadr include))
          (overrides (mapcar #'%struct-description (cddr include))))
      (unless (get parent '%structure-descriptions)
        (error "~S is not a structure type that can be included." parent))
      (mapcar (lambda (description)
                (or (assoc (car description) overrides) description))
              (get parent '%structure-descriptions)))))

(defun %struct-constructors (name options)
  "Each constructor the options ask for, as (name lambda-list), the
lambda list nil for a keyword constructor. Without a :constructor option
there is one keyword constructor named make-NAME."
  (let ((found nil) (given nil))
    (dolist (option options)
      (cond ((eq option :constructor) (setq given t))
            ((and (consp option) (eq (car option) :constructor))
             (setq given t)
             (when (cadr option)
               (push (list (cadr option) (cddr option)) found)))))
    (if given
        (nreverse found)
        (list (list (%struct-symbol "MAKE-" name) nil)))))

(defun %struct-lambda-variables (lambda-list)
  (let ((names nil))
    (dolist (item lambda-list names)
      (unless (member item lambda-list-keywords)
        (push (let ((head (if (consp item) (car item) item)))
                (if (consp head) (cadr head) head))
              names)))))

(defun %struct-constructor-form (name constructor descriptions)
  (destructuring-bind (function-name positional) constructor
    (if (null positional)
        `(defun ,function-name (&key ,@descriptions)
           (%make-structure ',name ,@(mapcar #'car descriptions)))
        (let* ((variables (%struct-lambda-variables (car positional)))
               (others (remove-if (lambda (description) (member (car description) variables))
                                  descriptions)))
          `(defun ,function-name (,@(car positional)
                                  ,@(when others
                                      (if (member '&aux (car positional))
                                          others
                                          (cons '&aux others))))
             (%make-structure ',name ,@(mapcar #'car descriptions)))))))

(defun %struct-accessors (conc slot-names)
  (mapcar (lambda (slot) (%struct-symbol conc slot)) slot-names))

(defun %struct-accessor-forms (accessors index)
  (if (null accessors)
      nil
      (list* `(defun ,(car accessors) (%struct) (%structure-ref %struct ,index))
             `(defsetf ,(car accessors) (%obj) (%new)
                (list '%set-structure-ref %obj ,index %new))
             (%struct-accessor-forms (cdr accessors) (+ index 1)))))

(defun %struct-printer-forms (name options)
  "A print-object method for the :print-function or :print-object option."
  (let ((print-function (%struct-option options :print-function nil))
        (print-object (%struct-option options :print-object nil)))
    (cond (print-function
           `((setq *%structure-print-object* t)
             (defmethod print-object ((%object ,name) %stream)
               (funcall (function ,print-function) %object %stream 0)
               %object)))
          (print-object
           `((setq *%structure-print-object* t)
             (defmethod print-object ((%object ,name) %stream)
               (funcall (function ,print-object) %object %stream)
               %object)))
          (t nil))))

(defmacro defstruct (name-and-options &rest slots)
  (let* ((name (if (consp name-and-options) (car name-and-options) name-and-options))
         (options (if (consp name-and-options) (cdr name-and-options) nil))
         (slots (if (stringp (car slots)) (cdr slots) slots))
         (include (%struct-include options))
         (descriptions (append (%struct-included-descriptions include)
                               (mapcar #'%struct-description slots)))
         (raw-conc (%struct-option options :conc-name (format nil "~A-" name)))
         (conc (if raw-conc (%struct-string raw-conc) ""))
         (constructors (%struct-constructors name options))
         (predicate (%struct-option options :predicate (%struct-symbol name "-P")))
         (copier (%struct-option options :copier (%struct-symbol "COPY-" name)))
         (slot-names (mapcar #'car descriptions))
         (accessors (%struct-accessors conc slot-names)))
    (%struct-check-options options)
    `(progn
       (%put ',name '%structure-slots ',slot-names)
       (%put ',name '%structure-descriptions ',descriptions)
       (%define-structure-class ',name ',slot-names ',(cadr include))
       ,@(mapcar (lambda (constructor) (%struct-constructor-form name constructor descriptions))
                 constructors)
       ,@(when predicate
           (list `(defun ,predicate (%struct)
                    (typep %struct ',name))))
       ,@(when copier
           (list `(defun ,copier (%struct) (%copy-structure %struct))))
       ,@(%struct-accessor-forms accessors 0)
       ,@(%struct-printer-forms name options)
       ',name)))

;; Set once a print-object method is defined for some structure type,
;; which is when the printer starts asking print-object about structures.
(defvar *%structure-print-object* nil)

(%put '%lexical-environment '%structure-slots '(value-frames function-frames))

(defun identity (x) x)

(defun sleep (seconds)
  (unless (and (realp seconds) (not (minusp seconds)))
    (error 'type-error :datum seconds :expected-type '(real 0)))
  (%sleep-nanoseconds (round (* seconds 1000000000)))
  nil)

;; `write` and `write-to-string` take the printer variables as keyword
;; arguments, each defaulting to what the variable already holds. Binding
;; them around the call is what makes the argument and the variable mean
;; the same thing.
(defmacro %with-print-options (options &body body)
  `(let ((*print-array* (getf ,options :array *print-array*))
         (*print-base* (getf ,options :base *print-base*))
         (*print-case* (getf ,options :case *print-case*))
         (*print-circle* (getf ,options :circle *print-circle*))
         (*print-escape* (getf ,options :escape *print-escape*))
         (*print-gensym* (getf ,options :gensym *print-gensym*))
         (*print-length* (getf ,options :length *print-length*))
         (*print-level* (getf ,options :level *print-level*))
         (*print-lines* (getf ,options :lines *print-lines*))
         (*print-miser-width* (getf ,options :miser-width *print-miser-width*))
         (*print-pprint-dispatch* (getf ,options :pprint-dispatch
                                        *print-pprint-dispatch*))
         (*print-pretty* (getf ,options :pretty *print-pretty*))
         (*print-radix* (getf ,options :radix *print-radix*))
         (*print-readably* (getf ,options :readably *print-readably*))
         (*print-right-margin* (getf ,options :right-margin *print-right-margin*)))
     ,@body))

(defun write-to-string (object &rest options)
  (%with-print-options options (%write-to-string object)))

(defun write (object &rest options)
  (%with-print-options options (%write object (getf options :stream nil)))
  object)

;; A declaration says nothing zisp acts on yet, so proclaiming one records
;; nothing. `declaim` is the special form beside it.
(defun proclaim (declaration)
  (declare (ignore declaration))
  nil)

(defmacro pprint-logical-block ((stream-var object &key prefix per-line-prefix suffix)
                                &body body)
  "Print BODY as one logical block, breaking its conditional newlines only
when the block will not fit before the right margin."
  (when (and prefix per-line-prefix)
    (error "cannot specify values for both prefix and per-line-prefix"))
  (let ((target (gensym))
        (pretty (gensym)))
    `(let* ((,target ,stream-var)
            (,pretty (%make-pretty-stream ,target))
            (,stream-var ,pretty))
       (declare (ignore ,object))
       (unwind-protect
            (progn
              ;; A per-line prefix goes on the first line as well, so it
              ;; serves as the block's prefix too.
              (%pprint-block-start ,pretty ,(or prefix per-line-prefix "")
                                   ,(or per-line-prefix "") "")
              ,@body
              (%pprint-block-end ,pretty ,(or suffix "")))
         (%pretty-stream-finish ,pretty)))))

(defmacro deftype (name lambda-list &body body)
  `(%put-deftype ',name
                 (lambda (%args)
                   (destructuring-bind ,lambda-list %args ,@body))))

(defun %prompt-for-value ()
  (format *query-io* "~&Enter a form to be evaluated: ")
  (finish-output *query-io*)
  (list (eval (read *query-io*))))

(defmacro check-type (place type &optional type-string)
  (let ((current (gensym "VALUE"))
        (new (gensym "NEW"))
        (stream (gensym "STREAM")))
    `(loop
       (let ((,current ,place))
         (when (typep ,current ',type) (return nil))
         (restart-case
             (error 'simple-type-error
                    :datum ,current
                    :expected-type ',type
                    :format-control "The value of ~S is ~S, which is not ~A."
                    :format-arguments (list ',place ,current
                                            ,(or type-string
                                                 `(format nil "of type ~S" ',type))))
           (store-value (,new)
             :report (lambda (,stream)
                       (format ,stream "Supply a new value for ~S." ',place))
             :interactive %prompt-for-value
             (setf ,place ,new)))))))

(defmacro do-symbols ((var &optional (package '*package*) result) &body body)
  `(progn
     (dolist-over (,var (%package-symbols ,package "PRESENT")) ,@body)
     (dolist-over (,var (%package-symbols ,package "INHERITED")) ,@body)
     ,result))

(defmacro do-external-symbols ((var &optional (package '*package*) result) &body body)
  `(progn
     (dolist-over (,var (%package-symbols ,package "EXTERNAL")) ,@body)
     ,result))

(defmacro do-all-symbols ((var &optional result) &body body)
  `(progn
     (dolist-over (,var (%all-symbols)) ,@body)
     ,result))

;; The walking half of the do-symbols family, so each of them is one line
;; of iteration rather than its own tagbody.
(defmacro dolist-over ((var list) &body body)
  (let ((rest (gensym)))
    `(let ((,rest ,list))
       (tagbody
        step
          (when ,rest
            (let ((,var (car ,rest)))
              ,@body)
            (setq ,rest (cdr ,rest))
            (go step))))))

(defun %designator-name (thing)
  (cond ((stringp thing) thing)
        ((symbolp thing) (symbol-name thing))
        ((characterp thing) (string thing))
        (t (error "not a string designator"))))

(defun %defpackage-option (option package-name)
  "One defpackage option as the form that carries it out."
  (let ((key (car option))
        (args (cdr option)))
    (cond
      ((eq key :use)
       (list 'use-package (list 'quote (mapcar #'%designator-name args)) package-name))
      ((eq key :nicknames)
       (list '%add-nicknames (list 'quote (mapcar #'%designator-name args)) package-name))
      ((eq key :shadow)
       (list 'shadow (list 'quote (mapcar #'%designator-name args)) package-name))
      ((eq key :intern)
       (list '%intern-all (list 'quote (mapcar #'%designator-name args)) package-name))
      ((eq key :export)
       (list '%export-names (list 'quote (mapcar #'%designator-name args)) package-name))
      ((eq key :shadowing-import-from)
       (list '%shadowing-import-from
             (%designator-name (car args))
             (list 'quote (mapcar #'%designator-name (cdr args)))
             package-name))
      ((eq key :import-from)
       (list '%import-from
             (%designator-name (car args))
             (list 'quote (mapcar #'%designator-name (cdr args)))
             package-name))
      ((eq key :documentation) nil)
      ((eq key :size) nil)
      (t (error "unknown defpackage option")))))

(defun %intern-all (names package)
  (dolist-over (n names) (intern n package))
  nil)

(defun %export-names (names package)
  (dolist-over (n names) (export (list (intern n package)) package))
  nil)

(defun %import-from (from names package)
  (dolist-over (n names) (import (list (find-symbol n from)) package))
  nil)

(defun %shadowing-import-from (from names package)
  (dolist-over (n names) (shadowing-import (list (find-symbol n from)) package))
  nil)

(defmacro defpackage (name &rest options)
  (let ((package-name (%designator-name name)))
    `(progn
       (unless (find-package ,package-name)
         (make-package ,package-name :use nil))
       ,@(mapcar (lambda (option) (%defpackage-option option package-name)) options)
       (find-package ,package-name))))

(defmacro with-open-file ((var filespec &rest options) &body body)
  `(let ((,var (open ,filespec ,@options)))
     (unwind-protect (progn ,@body)
       (when ,var (close ,var)))))

(defmacro with-input-from-string ((var string &rest options) &body body)
  (declare (ignore options))
  `(let ((,var (make-string-input-stream ,string)))
     (unwind-protect (progn ,@body)
       (close ,var))))

(defmacro with-output-to-string ((var) &body body)
  `(let ((,var (make-string-output-stream)))
     (unwind-protect (progn ,@body (get-output-stream-string ,var))
       (close ,var))))

(defmacro with-hash-table-iterator ((name table) &body body)
  (let ((remaining (gensym)))
    `(let ((,remaining (%hash-table-entries ,table)))
       (flet ((,name ()
                (if (null ,remaining)
                    nil
                    (let ((entry (car ,remaining)))
                      (setq ,remaining (cdr ,remaining))
                      (values t (car entry) (cdr entry))))))
         ,@body))))

(defmacro locally (&body body)
  (if (and (consp (car body)) (eq (caar body) 'declare))
      `(locally ,@(cdr body))
      `(progn ,@body)))

(defmacro nth-value (n form)
  `(nth ,n (multiple-value-list ,form)))

;; No condition can be signaled yet, so the handlers are evaluated and
;; discarded and the body runs unguarded.
(defmacro handler-bind (bindings &body body)
  `(progn ,@(mapcar #'cadr bindings) (progn ,@body)))

;; Until conditions are objects, an error carries only its name, so the first
;; handler clause takes every error rather than dispatching on the type.
(defmacro handler-case (form &rest clauses)
  (let* ((no-error (assoc :no-error clauses))
         (handlers (remove-if (lambda (clause) (eq (car clause) :no-error)) clauses))
         (outcome (gensym "OUTCOME")))
    (if (null handlers)
        (if no-error
            `(multiple-value-call (lambda ,(cadr no-error) ,@(cddr no-error)) ,form)
            form)
        `(let ((,outcome (multiple-value-list (%catch-error ,form))))
           (if (car ,outcome)
               ,(let ((clause (car handlers)))
                  (if (cadr clause)
                      `(let ((,(car (cadr clause)) (car ,outcome))) ,@(cddr clause))
                      `(progn ,@(cddr clause))))
               ,(if no-error
                    `(apply (lambda ,(cadr no-error) ,@(cddr no-error)) (cdr ,outcome))
                    `(values-list (cdr ,outcome))))))))

;; zisp interprets, so what there is to hand back is the function that
;; was already there. The two flags say the same thing either way: no
;; warnings, and nothing failed.
(defun compile (name &optional definition)
  (let ((fn (cond ((functionp definition) definition)
                  ((consp definition) (eval (list 'function definition)))
                  ((null name) (error "COMPILE needs a name or a definition."))
                  (t (symbol-function name)))))
    (when name (setf (symbol-function name) fn))
    (values (or name fn) nil nil)))

;; A control string in the shape of a function: it writes to the stream
;; it is handed and gives back the arguments it did not use.
(defmacro formatter (control-string)
  `(lambda (stream &rest args) (apply #'%format-tail stream ,control-string args)))

(defmacro assert (test-form &optional places datum &rest arguments)
  (let ((stream (gensym "STREAM")))
    `(loop
       (when ,test-form (return nil))
       (restart-case
           ,(if datum
                `(error ,datum ,@arguments)
                `(error "The assertion ~S failed." ',test-form))
         (continue ()
           :report (lambda (,stream)
                     (format ,stream ,(if places
                                          "Retry the assertion after setting new values."
                                          "Retry the assertion.")))
           ,@(mapcar (lambda (place)
                       `(setf ,place (car (%prompt-for-value))))
                     places))))))

;; The printer and reader variables the standard names, each bound to
;; what the standard says it holds, so what a form prints does not depend
;; on what the program had set.
(defmacro with-standard-io-syntax (&body body)
  `(let ((*package* (find-package "COMMON-LISP-USER"))
         (*print-array* t)
         (*print-base* 10)
         (*print-case* :upcase)
         (*print-circle* nil)
         (*print-escape* t)
         (*print-gensym* t)
         (*print-length* nil)
         (*print-level* nil)
         (*print-lines* nil)
         (*print-miser-width* nil)
         (*print-pprint-dispatch* (copy-pprint-dispatch nil))
         (*print-pretty* nil)
         (*print-radix* nil)
         (*print-readably* t)
         (*print-right-margin* nil)
         (*read-base* 10)
         (*read-default-float-format* 'single-float)
         (*read-eval* t)
         (*read-suppress* nil)
         (*readtable* (copy-readtable nil)))
     ,@body))

(export '(sleep psetf rotatef shiftf multiple-value-setq with-standard-io-syntax formatter assert compile proclaim
          write write-to-string
          lambda-list-keywords call-arguments-limit lambda-parameters-limit
          multiple-values-limit
          when unless cond and or prog1 prog2 case ecase ccase
          typecase etypecase ctypecase
          get-setf-expansion setf defsetf define-setf-expander
          push pop pushnew incf decf
          defstruct otherwise nth-value locally handler-bind handler-case identity
          with-hash-table-iterator with-open-file
          with-input-from-string with-output-to-string
          do-symbols do-external-symbols do-all-symbols dolist-over defpackage
          deftype check-type pprint-logical-block))

(in-package "COMMON-LISP-USER")
