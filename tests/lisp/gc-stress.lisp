;; A form that runs for millions of cells and keeps every so many of
;; them. What the loop drops is reclaimed while the form is still
;; running, and what it keeps is promoted at the next top-level form, so
;; the tenured space ends up sized by the retained cells rather than by
;; how long the loop ran.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

;; `zig build gc-stress` sets this to a hundred million before loading.
;; `defvar` leaves that value alone.
(defvar *gc-stress-iterations* 500000)
(defvar *gc-stress-retain-every* 200)

(defun room-get (key plist)
  (if (null plist)
      nil
      (if (eq (car plist) key)
          (car (cdr plist))
          (room-get key (cdr (cdr plist))))))

(defun room-value (key) (room-get key (room)))

(defvar *retained* 0)

(defun churn (limit every)
  (let ((kept nil))
    (setq *retained* 0)
    (loop for i below limit
          for cell = (cons nil nil)
          do (when (zerop (mod i every))
               (setq *retained* (1+ *retained*))
               (setq kept (cons cell kept))))
    kept))

(defvar *baseline* 0)
(defvar *kept-small* nil)
(defvar *kept-large* nil)
(defvar *small-bytes* 0)
(defvar *large-bytes* 0)
(defvar *small-count* 0)
(defvar *large-count* 0)

(gc)

(setq *baseline* (room-value :live-bytes))

(setq *kept-small* (churn *gc-stress-iterations* *gc-stress-retain-every*))
(setq *small-count* *retained*)

(gc)

(setq *small-bytes* (- (room-value :live-bytes) *baseline*))
(check (= (length *kept-small*) *small-count*))
(check (> *small-bytes* 0))

(setq *kept-large* (churn *gc-stress-iterations*
                          (floor *gc-stress-retain-every* 2)))
(setq *large-count* *retained*)

(gc)

(setq *large-bytes* (- (room-value :live-bytes) *baseline* *small-bytes*))
(check (= (length *kept-large*) *large-count*))
(check (= *large-count* (* 2 *small-count*)))

;; Twice the retained cells take twice the tenured space, give or take
;; what a collection leaves behind.
(check (> (* 10 *large-bytes*) (* 17 *small-bytes*)))
(check (< (* 10 *large-bytes*) (* 23 *small-bytes*)))

;; The heap is sized by what is live rather than by how long the loop
;; ran: the same bound holds whether it made eight megabytes of garbage
;; or sixteen hundred.
(check (< (room-value :region-bytes)
          (+ (* 8 1024 1024) (* 4 (room-value :live-bytes)))))
