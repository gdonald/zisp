;; Iteration macros, loaded after the boot prelude: psetq and the do family.
;; They expand into block / tagbody / go, so nothing here needs a native
;; iteration primitive.

(in-package "COMMON-LISP")

(defun %pairs (plist)
  (if (null plist)
      nil
      (cons (list (car plist) (cadr plist)) (%pairs (cddr plist)))))

(defun %strip-declares (body)
  (if (and (consp (car body)) (eq (caar body) 'declare))
      (%strip-declares (cdr body))
      body))

(defmacro psetq (&rest pairs)
  (let* ((assignments (%pairs pairs))
         (temps (mapcar (lambda (assignment) (gensym)) assignments)))
    `(let ,(mapcar #'list temps (mapcar #'cadr assignments))
       ,@(mapcar (lambda (assignment temp) (list 'setq (car assignment) temp))
                 assignments temps)
       nil)))

(defun %do-binding (spec)
  (if (symbolp spec)
      (list spec nil)
      (list (car spec) (cadr spec))))

(defun %do-steps (specs)
  (if (null specs)
      nil
      (let ((spec (car specs))
            (rest (%do-steps (cdr specs))))
        (if (and (consp spec) (cddr spec))
            (cons (car spec) (cons (caddr spec) rest))
            rest))))

(defun %expand-do (varlist endlist body binder setter)
  (let ((top (gensym "TOP"))
        (steps (%do-steps varlist)))
    `(block nil
       (,binder ,(mapcar #'%do-binding varlist)
         (tagbody
            ,top
            (if ,(car endlist) (return (progn ,@(cdr endlist))))
            ,@(%strip-declares body)
            ,@(if steps (list (cons setter steps)) nil)
            (go ,top))))))

(defmacro do (varlist endlist &body body)
  (%expand-do varlist endlist body 'let 'psetq))

(defmacro do* (varlist endlist &body body)
  (%expand-do varlist endlist body 'let* 'setq))

(defmacro dolist ((var list &optional result) &body body)
  (let ((remaining (gensym "REST"))
        (top (gensym "TOP"))
        (done (gensym "DONE")))
    `(block nil
       (let ((,remaining ,list) (,var nil))
         (tagbody
            ,top
            (if (endp ,remaining) (go ,done))
            (setq ,var (car ,remaining))
            ,@(%strip-declares body)
            (setq ,remaining (cdr ,remaining))
            (go ,top)
            ,done
            (setq ,var nil))
         ,result))))

(defmacro dotimes ((var count &optional result) &body body)
  (let ((limit (gensym "LIMIT"))
        (top (gensym "TOP"))
        (done (gensym "DONE")))
    `(block nil
       (let ((,limit ,count) (,var 0))
         (tagbody
            ,top
            (if (>= ,var ,limit) (go ,done))
            ,@(%strip-declares body)
            (setq ,var (1+ ,var))
            (go ,top)
            ,done)
         ,result))))

(export '(psetq do do* dolist dotimes))

(in-package "COMMON-LISP-USER")
