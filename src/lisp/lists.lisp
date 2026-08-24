;; Conses, lists, plists, alists and the set operations over them, plus the
;; sequence predicates that take a test/key pair.

(in-package "COMMON-LISP")

(defun %key-of (key element)
  (if key (funcall key element) element))

(defun %test-satisfied (item element test test-not key)
  (let ((value (%key-of key element)))
    (if test-not
        (not (funcall test-not item value))
        (funcall (or test #'eql) item value))))

(defun rest (list) (cdr list))

(defun copy-list (list)
  (if (atom list)
      list
      (let ((head (cons (car list) nil)))
        (let ((tail head)
              (remaining (cdr list)))
          (tagbody
             next
             (when (atom remaining)
               (rplacd tail remaining)
               (go done))
             (let ((cell (cons (car remaining) nil)))
               (rplacd tail cell)
               (setq tail cell))
             (setq remaining (cdr remaining))
             (go next)
             done)
          head))))

(defun copy-tree (tree)
  (if (consp tree)
      (cons (copy-tree (car tree)) (copy-tree (cdr tree)))
      tree))

(defun copy-alist (alist)
  (mapcar (lambda (entry) (if (consp entry) (cons (car entry) (cdr entry)) entry))
          alist))

(defun list-length (list)
  (do ((slow list (cdr slow))
       (fast list (cddr fast))
       (count 0 (+ count 2)))
      (nil)
    (when (endp fast) (return count))
    (when (endp (cdr fast)) (return (1+ count)))
    (when (and (eq slow fast) (> count 0)) (return nil))))

(defun last (list &optional (n 1))
  (let ((length 0))
    (do ((walk list (cdr walk)))
        ((atom walk))
      (setq length (1+ length)))
    (nthcdr (if (< n length) (- length n) 0) list)))

(defun butlast (list &optional (n 1))
  (let ((length 0))
    (do ((walk list (cdr walk)))
        ((atom walk))
      (setq length (1+ length)))
    (if (<= length n)
        nil
        (subseq list 0 (- length n)))))

(defun nbutlast (list &optional (n 1))
  (let ((kept (butlast list n)))
    (if (null kept)
        nil
        (progn (rplacd (nthcdr (1- (length kept)) list) nil) list))))

(defun make-list (size &key initial-element)
  (let ((result nil))
    (dotimes (index size result)
      (setq result (cons initial-element result)))))

(defun nconc (&rest lists)
  (let ((result nil)
        (tail nil))
    (dolist (list lists result)
      (unless (null list)
        (if (null result)
            (setq result list)
            (rplacd (last tail) list))
        (setq tail list)))))

(defun revappend (list tail)
  (dolist (element list tail)
    (setq tail (cons element tail))))

(defun nreconc (list tail)
  (revappend list tail))

(defun ldiff (list sublist)
  (let ((result nil))
    (do ((walk list (cdr walk)))
        ((or (atom walk) (eql walk sublist))
         (if (and (atom walk) (not (null walk)) (not (eql walk sublist)))
             (nreverse (cons walk result))
             (nreverse result)))
      (setq result (cons (car walk) result)))))

(defun tailp (object list)
  (do ((walk list (cdr walk)))
      ((atom walk) (eql walk object))
    (when (eql walk object) (return t))))

(defun getf (plist indicator &optional default)
  (do ((walk plist (cddr walk)))
      ((null walk) default)
    (when (eq (car walk) indicator) (return (cadr walk)))))

(defun get-properties (plist indicators)
  (do ((walk plist (cddr walk)))
      ((null walk) (values nil nil nil))
    (when (member (car walk) indicators :test #'eq)
      (return (values (car walk) (cadr walk) walk)))))

(defun %remf-plist (plist indicator)
  (cond ((null plist) nil)
        ((eq (car plist) indicator) (cddr plist))
        (t (cons (car plist)
                 (cons (cadr plist) (%remf-plist (cddr plist) indicator))))))

(defmacro remf (place indicator)
  (let ((key (gensym "KEY"))
        (old (gensym "OLD")))
    `(let* ((,key ,indicator)
            (,old ,place))
       (if (eq (getf ,old ,key %remf-missing) %remf-missing)
           nil
           (progn (setf ,place (%remf-plist ,old ,key)) t)))))

(defvar %remf-missing (list :missing))

(defun acons (key datum alist)
  (cons (cons key datum) alist))

(defun pairlis (keys data &optional alist)
  (do ((remaining-keys keys (cdr remaining-keys))
       (remaining-data data (cdr remaining-data)))
      ((null remaining-keys) alist)
    (setq alist (acons (car remaining-keys) (car remaining-data) alist))))

(defun member-if (predicate list &key key)
  (do ((walk list (cdr walk)))
      ((endp walk) nil)
    (when (funcall predicate (%key-of key (car walk))) (return walk))))

(defun member-if-not (predicate list &key key)
  (member-if (lambda (element) (not (funcall predicate element))) list :key key))

(defun assoc-if (predicate alist &key key)
  (dolist (entry alist nil)
    (when (and (consp entry) (funcall predicate (%key-of key (car entry))))
      (return entry))))

(defun assoc-if-not (predicate alist &key key)
  (assoc-if (lambda (element) (not (funcall predicate element))) alist :key key))

(defun rassoc (item alist &key test test-not key)
  (dolist (entry alist nil)
    (when (and (consp entry) (%test-satisfied item (cdr entry) test test-not key))
      (return entry))))

(defun rassoc-if (predicate alist &key key)
  (dolist (entry alist nil)
    (when (and (consp entry) (funcall predicate (%key-of key (cdr entry))))
      (return entry))))

(defun rassoc-if-not (predicate alist &key key)
  (rassoc-if (lambda (element) (not (funcall predicate element))) alist :key key))

(defun adjoin (item list &key test test-not key)
  (if (%member-under item list test test-not key)
      list
      (cons item list)))

(defun %member-under (item list test test-not key)
  (dolist (element list nil)
    (when (%test-satisfied (%key-of key item) element test test-not key)
      (return t))))

(defun union (list1 list2 &key test test-not key)
  (let ((result list2))
    (dolist (element list1 result)
      (unless (%member-under element list2 test test-not key)
        (setq result (cons element result))))))

(defun nunion (list1 list2 &key test test-not key)
  (union list1 list2 :test test :test-not test-not :key key))

(defun intersection (list1 list2 &key test test-not key)
  (let ((result nil))
    (dolist (element list1 result)
      (when (%member-under element list2 test test-not key)
        (setq result (cons element result))))))

(defun nintersection (list1 list2 &key test test-not key)
  (intersection list1 list2 :test test :test-not test-not :key key))

(defun set-difference (list1 list2 &key test test-not key)
  (let ((result nil))
    (dolist (element list1 result)
      (unless (%member-under element list2 test test-not key)
        (setq result (cons element result))))))

(defun nset-difference (list1 list2 &key test test-not key)
  (set-difference list1 list2 :test test :test-not test-not :key key))

(defun set-exclusive-or (list1 list2 &key test test-not key)
  (append (set-difference list1 list2 :test test :test-not test-not :key key)
          (set-difference list2 list1 :test test :test-not test-not :key key)))

(defun nset-exclusive-or (list1 list2 &key test test-not key)
  (set-exclusive-or list1 list2 :test test :test-not test-not :key key))

(defun subsetp (list1 list2 &key test test-not key)
  (dolist (element list1 t)
    (unless (%member-under element list2 test test-not key)
      (return nil))))

(defun maplist (function list &rest more-lists)
  (let ((result nil)
        (walks (cons list more-lists)))
    (tagbody
       next
       (when (%some-atom walks) (go done))
       (setq result (cons (apply function walks) result))
       (setq walks (mapcar #'cdr walks))
       (go next)
       done)
    (nreverse result)))

(defun mapl (function list &rest more-lists)
  (apply #'maplist function list more-lists)
  list)

(defun mapcon (function list &rest more-lists)
  (apply #'nconc (apply #'maplist function list more-lists)))

(defun %some-atom (lists)
  (dolist (list lists nil)
    (when (atom list) (return t))))

(defun tree-equal (tree1 tree2 &key test test-not)
  (if (or (consp tree1) (consp tree2))
      (and (consp tree1)
           (consp tree2)
           (tree-equal (car tree1) (car tree2) :test test :test-not test-not)
           (tree-equal (cdr tree1) (cdr tree2) :test test :test-not test-not))
      (%test-satisfied tree1 tree2 test test-not nil)))

(defun subst (new old tree &key test test-not key)
  (cond ((%test-satisfied old tree test test-not key) new)
        ((consp tree)
         (cons (subst new old (car tree) :test test :test-not test-not :key key)
               (subst new old (cdr tree) :test test :test-not test-not :key key)))
        (t tree)))

(defun nsubst (new old tree &key test test-not key)
  (subst new old tree :test test :test-not test-not :key key))

(defun subst-if (new predicate tree &key key)
  (cond ((funcall predicate (%key-of key tree)) new)
        ((consp tree)
         (cons (subst-if new predicate (car tree) :key key)
               (subst-if new predicate (cdr tree) :key key)))
        (t tree)))

(defun subst-if-not (new predicate tree &key key)
  (subst-if new (lambda (element) (not (funcall predicate element))) tree :key key))

(defun %sublis-hit (alist value test test-not)
  (dolist (entry alist nil)
    (when (and (consp entry)
               (if test-not
                   (not (funcall test-not (car entry) value))
                   (funcall (or test #'eql) (car entry) value)))
      (return entry))))

(defun sublis (alist tree &key test test-not key)
  (let ((hit (%sublis-hit alist (%key-of key tree) test test-not)))
    (cond (hit (cdr hit))
          ((consp tree)
           (cons (sublis alist (car tree) :test test :test-not test-not :key key)
                 (sublis alist (cdr tree) :test test :test-not test-not :key key)))
          (t tree))))

(defun nsublis (alist tree &key test test-not key)
  (sublis alist tree :test test :test-not test-not :key key))

(defun %as-list (sequence)
  (if (listp sequence) sequence (coerce sequence 'list)))

(defun some (predicate sequence &rest more-sequences)
  (let ((walks (mapcar #'%as-list (cons sequence more-sequences)))
        (result nil))
    (tagbody
       next
       (when (%some-atom walks) (go done))
       (setq result (apply predicate (mapcar #'car walks)))
       (when result (go done))
       (setq walks (mapcar #'cdr walks))
       (go next)
       done)
    result))

(defun every (predicate sequence &rest more-sequences)
  (not (apply #'some
              (lambda (&rest arguments) (not (apply predicate arguments)))
              sequence more-sequences)))

(defun notany (predicate sequence &rest more-sequences)
  (not (apply #'some predicate sequence more-sequences)))

(defun notevery (predicate sequence &rest more-sequences)
  (not (apply #'every predicate sequence more-sequences)))

(defun remove-duplicates (sequence &key test test-not key from-end (start 0) end)
  (let ((elements (%as-list (subseq sequence start end)))
        (kept nil))
    (do ((walk elements (cdr walk)))
        ((endp walk))
      (unless (%member-under (car walk) (if from-end kept (cdr walk))
                             test test-not key)
        (setq kept (cons (car walk) kept))))
    (let ((result (append (%as-list (subseq sequence 0 start))
                          (nreverse kept)
                          (if end (%as-list (subseq sequence end)) nil))))
      (cond ((listp sequence) result)
            ((stringp sequence) (coerce result 'string))
            (t (coerce result 'vector))))))

(defun delete-duplicates (sequence &key test test-not key from-end (start 0) end)
  (remove-duplicates sequence :test test :test-not test-not :key key
                     :from-end from-end :start start :end end))

(export '(rest copy-list copy-tree copy-alist list-length last butlast nbutlast
          make-list nconc revappend nreconc ldiff tailp getf get-properties remf
          acons pairlis member-if member-if-not assoc-if assoc-if-not
          rassoc rassoc-if rassoc-if-not adjoin
          union nunion intersection nintersection set-difference nset-difference
          set-exclusive-or nset-exclusive-or subsetp
          maplist mapl mapcon tree-equal subst nsubst subst-if subst-if-not
          sublis nsublis some every notany notevery
          remove-duplicates delete-duplicates))

(in-package "COMMON-LISP-USER")
