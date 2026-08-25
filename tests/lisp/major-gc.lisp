;; A collection that walks the whole heap rather than the nursery alone.
;;
;; Most collections are about the nursery: they reach the young objects
;; through the roots and the dirty cards and leave the tenured space
;; where it is. That space is reclaimed by a major collection, which is
;; due once it has grown fourfold since the last one. Retaining more and
;; more inside one form has to bring one on, without anything asking.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defun room-get (key plist)
  (if (null plist)
      nil
      (if (eq (car plist) key)
          (car (cdr plist))
          (room-get key (cdr (cdr plist))))))

(defun room-value (key) (room-get key (room)))

(defvar *kept* nil)
(defvar *dropped* nil)

(defun retain (n)
  (dotimes (i n) (setq *kept* (cons (cons i i) *kept*))))

(defun churn (n)
  (dotimes (i n) (setq *dropped* (cons (cons i i) nil))))

;; A major is not worth running over a heap this small, so the floor
;; comes down to where a few thousand retained cells cross it.
(defparameter *gc-major-floor* 65536)

(defvar *majors-before* 0)
(defvar *majors-first* 0)
(defvar *collections-before* 0)

(gc)

(setq *majors-before* (room-value :major-collections))
(setq *collections-before* (room-value :collections))

;; One form, so every collection inside it is one the collector chose
;; for itself rather than one that was asked for. Enough is retained to
;; carry the tenured space over the floor and then well past fourfold.
(retain 76000)

(setq *majors-first* (room-value :major-collections))
(check (> *majors-first* *majors-before*))

;; What was retained came through whole.
(check (= (length *kept*) 76000))
(check (equal (car *kept*) '(75999 . 75999)))

(defvar *live-peak* 0)
(setq *live-peak* (room-value :live-bytes))
(check (> *live-peak* 2000000))

;; Dropping it and asking for a collection is what the tenured space is
;; reclaimed by: a collection of the nursery alone would leave it all
;; where it is.
(setq *kept* nil)

(gc)

(check (< (room-value :live-bytes) (floor *live-peak* 4)))

;; And what a run of churn drops does not accumulate either.
(churn 20000)

(gc)

(check (< (room-value :region-bytes) (* 32 1024 1024)))
