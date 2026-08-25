;; What a program pays for collection while it runs.
;;
;; The loop keeps a working set of a few thousand cells and replaces it
;; over and over, so each collection has both survivors to keep and
;; garbage to reclaim rather than an empty heap to walk. The gate is on
;; the share of the run the collector stopped the program for.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

;; `zig build gc-pause` sets this to sixty before loading. `defvar`
;; leaves that value alone.
(defvar *gc-pause-seconds* 5)
(defvar *gc-pause-working-set* 5000)
(defvar *gc-pause-round* 20000)
;; What share of the time the program got the collector may take.
;; `docs/perf-baseline.md` records where the number stands.
(defvar *gc-pause-limit-percent* 5)

(defun room-get (key plist)
  (if (null plist)
      nil
      (if (eq (car plist) key)
          (car (cdr plist))
          (room-get key (cdr (cdr plist))))))

(defun room-value (key) (room-get key (room)))

(defvar *working-set* nil)

(defun refresh-working-set (size)
  (let ((cells nil))
    (dotimes (i size) (setq cells (cons (cons i i) cells)))
    (setq *working-set* cells)))

(defun churn-until (deadline round size)
  (let ((rounds 0))
    (do ()
        ((>= (get-internal-real-time) deadline) rounds)
      (refresh-working-set size)
      (dotimes (i round) (cons nil nil))
      (setq rounds (1+ rounds)))))

(defvar *rounds* 0)
(defvar *elapsed-us* 0)
(defvar *gc-us* 0)
(defvar *mutator-us* 0)
(defvar *collections* 0)

;; Promote what the prelude built out of the nursery before the clock
;; starts, so the run measures a program at work rather than one still
;; carrying its own definitions around in young space.
(gc)

(let ((start (get-internal-real-time))
      (gc-start (room-value :gc-time-ns))
      (collections-start (room-value :collections)))
  (setq *rounds* (churn-until (+ start (* *gc-pause-seconds*
                                          internal-time-units-per-second))
                              *gc-pause-round*
                              *gc-pause-working-set*))
  (setq *elapsed-us* (- (get-internal-real-time) start))
  (setq *gc-us* (floor (- (room-value :gc-time-ns) gc-start) 1000))
  (setq *mutator-us* (- *elapsed-us* *gc-us*))
  (setq *collections* (- (room-value :collections) collections-start)))

(check (> *rounds* 0))
(check (> *collections* 0))
(check (> *mutator-us* 0))

;; The collector stopped the program for no more than its share of the
;; time the program itself got.
(check (<= (* 100 *gc-us*) (* *gc-pause-limit-percent* *mutator-us*)))

;; Every collection landed in a bucket, so the histogram accounts for
;; all of them.
(check (= (apply #'+ (room-value :gc-pauses)) (room-value :collections)))
