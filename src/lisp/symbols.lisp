;;; Symbols, packages as collections of symbols, and the binding forms
;;; built on block, let and tagbody.

(in-package "COMMON-LISP")

(defun set (symbol value)
  (setf (symbol-value symbol) value))

(defun remprop (symbol indicator)
  (let ((plist (symbol-plist symbol)))
    (cond ((null plist) nil)
          ((eq (car plist) indicator)
           (setf (symbol-plist symbol) (cddr plist))
           t)
          (t (do ((tail plist (cddr tail)))
                 ((null (cddr tail)) nil)
               (when (eq (caddr tail) indicator)
                 (setf (cddr tail) (cddddr tail))
                 (return t)))))))

(defun copy-symbol (symbol &optional copy-properties)
  (check-type symbol symbol)
  (let ((copy (make-symbol (symbol-name symbol))))
    (when copy-properties
      (when (boundp symbol) (setf (symbol-value copy) (symbol-value symbol)))
      (when (fboundp symbol) (setf (symbol-function copy) (symbol-function symbol)))
      (setf (symbol-plist copy) (copy-list (symbol-plist symbol))))
    copy))

(defmacro prog (bindings &body body)
  `(block nil
     (let ,bindings
       ,@(%leading-declares body)
       (tagbody ,@(%strip-declares body)))))

(defmacro prog* (bindings &body body)
  `(block nil
     (let* ,bindings
       ,@(%leading-declares body)
       (tagbody ,@(%strip-declares body)))))

(defun find-all-symbols (string)
  (let ((name (string string))
        (found nil))
    (dolist (package (list-all-packages) found)
      (multiple-value-bind (symbol status) (find-symbol name package)
        (when (and status (not (eq status :inherited)))
          (pushnew symbol found))))))

;; Each entry is (symbol status package), gathered when the iterator is
;; made, and the box holds the ones not handed out yet.
(defun %package-iterator-entries (packages symbol-types)
  (let ((entries nil))
    (dolist (designator (if (listp packages) packages (list packages)))
      (let ((package (or (find-package designator)
                         (error 'package-error :package designator))))
        (do-symbols (symbol package)
          (multiple-value-bind (found status) (find-symbol (symbol-name symbol) package)
            (when (and (eq found symbol) (member status symbol-types))
              (pushnew (list symbol status package) entries :test #'equal))))))
    (list (nreverse entries))))

(defun %package-iterator-next (box)
  (let ((entry (pop (car box))))
    (if entry
        (values t (first entry) (second entry) (third entry))
        nil)))

(defmacro with-package-iterator ((name package-list &rest symbol-types) &body body)
  (when (null symbol-types)
    (error 'program-error))
  (dolist (type symbol-types)
    (unless (member type '(:internal :external :inherited))
      (error 'program-error)))
  (let ((box (gensym "ENTRIES")))
    `(let ((,box (%package-iterator-entries ,package-list ',symbol-types)))
       (macrolet ((,name () '(%package-iterator-next ,box)))
         ,@body))))

(defmacro define-modify-macro (name lambda-list function &optional documentation)
  (let ((place (gensym "PLACE"))
        (environment (gensym "ENVIRONMENT"))
        (temps (gensym "TEMPS"))
        (forms (gensym "FORMS"))
        (stores (gensym "STORES"))
        (store-form (gensym "STORE-FORM"))
        (access-form (gensym "ACCESS-FORM"))
        (arguments nil)
        (rest nil))
    (do ((tail lambda-list (cdr tail)))
        ((null tail))
      (let ((item (car tail)))
        (cond ((eq item '&optional))
              ((eq item '&rest) (setq rest (cadr tail)) (setq tail (cdr tail)))
              (t (push (if (consp item) (car item) item) arguments)))))
    `(defmacro ,name (,place ,@lambda-list &environment ,environment)
       ,@(when documentation (list documentation))
       (multiple-value-bind (,temps ,forms ,stores ,store-form ,access-form)
           (get-setf-expansion ,place ,environment)
         (list 'let* (mapcar #'list ,temps ,forms)
               (list 'multiple-value-bind ,stores
                     (append (list ',function ,access-form) (list ,@(nreverse arguments)) ,rest)
                     ,store-form))))))

(in-package "COMMON-LISP-USER")
