;; A collection copies what the nursery still holds into the tenured
;; space. Each check runs after one, since a collection happens between
;; top-level forms; the values under test are held in globals so they are
;; live across that boundary.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defvar *cells* (loop repeat 100 collect (cons :a :b)))
(gc)
(check (eql (length *cells*) 100))
(check (every (lambda (cell) (and (eq (car cell) :a) (eq (cdr cell) :b))) *cells*))
(check (> (getf (room) :collections) 0))

(defvar *shared* (list 1 2))
(defvar *graph* (list *shared* *shared*))
(gc)
(check (eq (first *graph*) (second *graph*)))
(check (eq (first *graph*) *shared*))

(defvar *inner* (list :deep))
(defvar *outer* (list *inner* (vector *inner*)))
(gc)
(check (eq (first *outer*) (aref (second *outer*) 0)))

(defvar *cyclic* (list 1))
(setf (cdr *cyclic*) *cyclic*)
(gc)
(check (eql (car *cyclic*) 1))
(check (eq (cdr *cyclic*) *cyclic*))

(defvar *deep* (loop for i from 1 to 500 collect i))
(gc)
(check (equal *deep* (loop for i from 1 to 500 collect i)))

(defvar *string* "copied")
(defvar *vector* (vector 1 2))
(defvar *table* (make-hash-table))
(setf (gethash :k *table*) :v)
(gc)
(check (string= *string* "copied"))
(check (equalp *vector* #(1 2)))
(check (eq (gethash :k *table*) :v))

(defvar *eq-table* (make-hash-table :test #'eq))
(defvar *key* (list :key))
(setf (gethash *key* *eq-table*) :found)
(gc)
(check (eq (gethash *key* *eq-table*) :found))

(defvar *equal-table* (make-hash-table :test #'equal))
(setf (gethash (list 1 2) *equal-table*) :found)
(gc)
(check (eq (gethash (list 1 2) *equal-table*) :found))

(defvar *closure* (let ((captured (list :inside))) (lambda () captured)))
(gc)
(check (equal (funcall *closure*) '(:inside)))

(defstruct copied-point x y)
(defvar *point* (make-copied-point :x (list 1) :y 2))
(gc)
(check (equal (copied-point-x *point*) '(1)))
(check (eql (copied-point-y *point*) 2))

(defvar *base* (make-array 4 :element-type 'character :initial-contents "abcd"))
(defvar *window* (make-array 2 :element-type 'character
                             :displaced-to *base* :displaced-index-offset 1))
(gc)
(check (string= *window* "bc"))
(check (progn (setf (char *window* 0) #\Z) (string= *base* "aZcd")))

(defvar *ratio* (/ 3 7))
(defvar *big* (* most-positive-fixnum 4))
(defvar *complex* (complex 1 2))
(defvar *path* (make-pathname :name "moved" :type "lsp"))
(gc)
(check (eql *ratio* 3/7))
(check (eql *big* (* most-positive-fixnum 4)))
(check (eql *complex* (complex 1 2)))
(check (string= (pathname-name *path*) "moved"))

(defvar *symbol-plist-holder* (make-symbol "HOLDER"))
(setf (get *symbol-plist-holder* :held) (list :plist))
(gc)
(check (equal (get *symbol-plist-holder* :held) '(:plist)))

(defvar *nursery-empty-after-collection* nil)
(gc)
(check (< (getf (room) :nursery-bytes) 4096))

;; An object that survived one collection points at one made after it,
;; which is the case a card table will narrow the walk down to.
(defvar *old-cons* (list :placeholder))
(defvar *old-vector* (vector :placeholder))
(defvar *old-table* (make-hash-table))
(defvar *old-structure* (make-copied-point :x :placeholder :y :placeholder))
(gc)
(setf (car *old-cons*) (list :young))
(setf (aref *old-vector* 0) (list :young))
(setf (gethash :k *old-table*) (list :young))
(setf (copied-point-x *old-structure*) (list :young))
(gc)
(check (equal (car *old-cons*) '(:young)))
(check (equal (aref *old-vector* 0) '(:young)))
(check (equal (gethash :k *old-table*) '(:young)))
(check (equal (copied-point-x *old-structure*) '(:young)))
