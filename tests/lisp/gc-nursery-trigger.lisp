;; A form that allocates for a long time gets its collections while it
;; runs rather than waiting for the next top-level form: the nursery is
;; reclaimed in place once it has been handed out, so the loop below
;; keeps reusing the same megabyte instead of spilling into the tenured
;; space.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defvar *capacity* (getf (room) :nursery-capacity))
(defvar *peak* 0)
(defvar *collections-before* 0)
(defvar *collections-during* 0)

(let ((before (getf (room) :collections)))
  (loop for i below 200000
        do (cons nil nil)
           (when (zerop (mod i 1000))
             (let ((used (getf (room) :nursery-bytes)))
               (when (> used *peak*) (setq *peak* used)))))
  (setq *collections-before* before)
  (setq *collections-during* (- (getf (room) :collections) before)))

(check (> *collections-during* 0))
(check (<= *peak* (floor (* *capacity* 105) 100)))

;; Each of those collections was timed and counted.
(check (= (apply #'+ (getf (room) :gc-pauses)) (getf (room) :collections)))

;; The clock those timings come from counts in the units it advertises
;; and only ever moves forward.
(defvar *clock-reading* (get-internal-real-time))

(check (= internal-time-units-per-second 1000000))
(check (integerp *clock-reading*))
(check (>= (get-internal-real-time) *clock-reading*))
