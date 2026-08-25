;; The collector without generations.
;;
;; `*gc-nursery-bytes*` is what the nursery may hand out. Setting it to
;; zero turns the nursery off: every allocation goes to the tenured
;; space and is reclaimed by marking and sweeping, which is what the
;; generational collector is measured against.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defvar *capacity* (getf (room) :nursery-capacity))

(check (> *capacity* 0))

;; Small enough that the loop below collects several times over.
(defparameter *gc-trigger* 1048576)
(defparameter *gc-nursery-bytes* 0)

(check (= 0 (getf (room) :nursery-capacity)))

(defvar *collections-before* (getf (room) :collections))
(defvar *majors-before* (getf (room) :major-collections))
(defvar *regions-before* (getf (room) :region-bytes))

(loop for i below 200000 do (cons nil nil))

(defvar *collections* (- (getf (room) :collections) *collections-before*))
(defvar *majors* (- (getf (room) :major-collections) *majors-before*))

;; The loop hands out about 3.2 MB of cells. Every collection it takes
;; marks and sweeps, since there is no nursery for a young one to
;; reclaim.
(check (> *collections* 0))
(check (= *collections* *majors*))

;; Those collections are what keeps the tenured space from having to
;; hold every cell the loop made.
(check (< (- (getf (room) :region-bytes) *regions-before*) 3200000))

;; A setting that is not a count of bytes leaves the nursery as it is.
(defparameter *gc-nursery-bytes* -1)

(check (= 0 (getf (room) :nursery-capacity)))

(defparameter *gc-nursery-bytes* :off)

(check (= 0 (getf (room) :nursery-capacity)))

;; Handing the budget back brings the nursery with it.
(defparameter *gc-nursery-bytes* *capacity*)

(dotimes (i 1000) (cons nil nil))

(check (= *capacity* (getf (room) :nursery-capacity)))
(check (> (getf (room) :nursery-bytes) 0))
