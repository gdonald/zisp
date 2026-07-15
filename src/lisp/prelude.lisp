;; Boot prelude: standard macros defined in Lisp, loaded after the native
;; builtins are registered. Expansions bottom out in the if / progn / let
;; special forms.

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
(defsetf elt %set-elt)
(defsetf aref %set-aref)
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
