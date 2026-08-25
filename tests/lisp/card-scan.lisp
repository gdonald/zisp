;; A tenured object made to point at a young one.
;;
;; The collection that copies the nursery walks the roots and the cards,
;; and no longer descends into the tenured space. An object promoted by
;; one collection and then pointed at something made after it is reached
;; only through the card the store marked: without that scan the young
;; object is not copied and what refers to it is left dangling.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defstruct card-point x)

(defvar *old-cons* (list :placeholder))
(defvar *old-tail* (list :placeholder))
(defvar *old-vector* (vector :placeholder))
(defvar *old-table* (make-hash-table))
(defvar *old-struct* (make-card-point :x :placeholder))

;; Everything above is copied into the tenured space here.
(gc)

;; Each store below is the only record that a tenured object now refers
;; to something young. Nothing else holds these lists.
(setf (car *old-cons*) (list :car (list :deeper)))
(setf (cdr *old-tail*) (list :cdr))
(setf (aref *old-vector* 0) (list :element))
(setf (gethash :key *old-table*) (list :entry))
(setf (card-point-x *old-struct*) (list :slot))

(gc)

(check (equal (car *old-cons*) '(:car (:deeper))))
(check (equal (cdr *old-tail*) '(:cdr)))
(check (equal (aref *old-vector* 0) '(:element)))
(check (equal (gethash :key *old-table*) '(:entry)))
(check (equal (card-point-x *old-struct*) '(:slot)))

;; A card is read again on the next collection only if something marked
;; it again, so the same reference has to come through a second one.
(gc)

(check (equal (car *old-cons*) '(:car (:deeper))))
(check (equal (gethash :key *old-table*) '(:entry)))

;; A young object reached through two tenured ones in turn.
(defvar *old-outer* (list :placeholder))
(defvar *old-inner* (list :placeholder))

(gc)

(setf (car *old-outer*) *old-inner*)
(setf (car *old-inner*) (list :innermost))

(gc)

(check (equal (car (car *old-outer*)) '(:innermost)))
