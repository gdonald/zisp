;; Boot prelude: standard macros defined in Lisp, loaded after the native
;; builtins are registered. Expansions bottom out in the if / progn / let
;; special forms.
;;
;; Everything here is read in COMMON-LISP so the standard names it defines
;; are inherited by every package that uses CL. The export list at the end
;; keeps the `%`-prefixed helpers internal.

(in-package "COMMON-LISP")

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

(defmacro ecase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (case ,tmp
         ,@clauses
         (otherwise (error "~s fell through ECASE expression" ,tmp))))))

;; Without the condition system there is no store-value restart, so ccase
;; signals like ecase.
(defmacro ccase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (case ,tmp
         ,@clauses
         (otherwise (error "~s fell through CCASE expression" ,tmp))))))

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
         (otherwise (error "~s fell through ETYPECASE expression" ,tmp))))))

;; Like ccase, ctypecase signals like its e-variant until restarts exist.
(defmacro ctypecase (keyform &rest clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,keyform))
       (typecase ,tmp
         ,@clauses
         (otherwise (error "~s fell through CTYPECASE expression" ,tmp))))))

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
            (error "no setf expander for ~s" (car place))))))

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
(defsetf row-major-aref %set-row-major-aref)
(defsetf fill-pointer %set-fill-pointer)
(defsetf logical-pathname-translations %set-logical-pathname-translations)
(defsetf char %set-char)
(defsetf schar %set-char)
(defsetf symbol-value %set-symbol-value)
(defsetf symbol-function %set-symbol-function)
(defsetf symbol-plist %set-symbol-plist)

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
                 (unless (member key '(:conc-name :constructor :predicate :copier))
                   (error "defstruct option ~S is not supported" key)))
               (scan (cdr rest)))))
    (scan options)))

(defun %struct-slot-name (slot)
  (if (consp slot) (car slot) slot))

(defun %struct-slot-initform (slot)
  (if (consp slot) (car (cdr slot)) nil))

(defun %struct-accessors (conc slot-names)
  (mapcar (lambda (slot) (%struct-symbol conc slot)) slot-names))

(defun %struct-accessor-forms (accessors index)
  (if (null accessors)
      nil
      (list* `(defun ,(car accessors) (%struct) (%structure-ref %struct ,index))
             `(defsetf ,(car accessors) (%obj) (%new)
                (list '%set-structure-ref %obj ,index %new))
             (%struct-accessor-forms (cdr accessors) (+ index 1)))))

(defmacro defstruct (name-and-options &rest slots)
  (let* ((name (if (consp name-and-options) (car name-and-options) name-and-options))
         (options (if (consp name-and-options) (cdr name-and-options) nil))
         (raw-conc (%struct-option options :conc-name (format nil "~A-" name)))
         (conc (if raw-conc (%struct-string raw-conc) ""))
         (constructor (%struct-option options :constructor (%struct-symbol "MAKE-" name)))
         (predicate (%struct-option options :predicate (%struct-symbol name "-P")))
         (copier (%struct-option options :copier (%struct-symbol "COPY-" name)))
         (slot-names (mapcar #'%struct-slot-name slots))
         (accessors (%struct-accessors conc slot-names)))
    (%struct-check-options options)
    `(progn
       (%put ',name '%structure-slots ',slot-names)
       ,@(when constructor
           (list `(defun ,constructor
                      (&key ,@(mapcar (lambda (slot)
                                        (list (%struct-slot-name slot)
                                              (%struct-slot-initform slot)))
                                      slots))
                    (%make-structure ',name ,@slot-names))))
       ,@(when predicate
           (list `(defun ,predicate (%struct)
                    (and (%structure-p %struct)
                         (eq (%structure-name %struct) ',name)))))
       ,@(when copier
           (list `(defun ,copier (%struct) (%copy-structure %struct))))
       ,@(%struct-accessor-forms accessors 0)
       ',name)))

(defun identity (x) x)

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

(defmacro check-type (place type &optional string)
  (declare (ignore string))
  `(unless (typep ,place ',type)
     (error "value is not of the required type")))

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

(defmacro nth-value (n form)
  `(nth ,n (multiple-value-list ,form)))

;; No condition can be signaled yet, so the handlers are evaluated and
;; discarded and the body runs unguarded.
(defmacro handler-bind (bindings &body body)
  `(progn ,@(mapcar #'cadr bindings) (progn ,@body)))

(export '(when unless cond and or prog1 prog2 case ecase ccase
          typecase etypecase ctypecase
          get-setf-expansion setf defsetf define-setf-expander
          push pop pushnew incf decf
          defstruct otherwise nth-value handler-bind identity
          with-hash-table-iterator with-open-file
          with-input-from-string with-output-to-string
          do-symbols do-external-symbols do-all-symbols dolist-over defpackage
          deftype check-type pprint-logical-block))

(in-package "COMMON-LISP-USER")
