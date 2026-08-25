;; What the collector costs a program that does real work.
;;
;; The definitions this drives are cl-bench's Boyer benchmark, a rewrite
;; engine that conses heavily and keeps its lemmas on symbol plists, so
;; the run has both a live set the collector has to walk and a stream of
;; garbage it can reclaim. `tests/run-boyer.sh` loads that source ahead
;; of this file and runs the whole thing twice, once with the nursery
;; and once without, so the two figures can be compared.
;;
;; What this file reports is the time the loop took and what the
;; collector took out of it, on the evaluator's own clock, so process
;; start and loading the benchmark are outside the measurement.

(defvar *boyer-runs* 2)

(defun room-get (key plist)
  (if (null plist)
      nil
      (if (eq (car plist) key)
          (car (cdr plist))
          (room-get key (cdr (cdr plist))))))

(defun room-value (key) (room-get key (room)))

;; Promote what loading the benchmark built out of the nursery before
;; the clock starts, so the run measures the benchmark rather than the
;; reader's leavings.
(gc)

(defvar *gc-before* (room-value :gc-time-ns))
(defvar *collections-before* (room-value :collections))
(defvar *majors-before* (room-value :major-collections))
(defvar *started* (get-internal-real-time))

(dotimes (i *boyer-runs*) (boyer))

(defvar *elapsed-us* (- (get-internal-real-time) *started*))

(format t "BOYER ~d ~d ~d ~d ~d~%"
        *elapsed-us*
        (- (room-value :gc-time-ns) *gc-before*)
        (- (room-value :collections) *collections-before*)
        (- (room-value :major-collections) *majors-before*)
        (room-value :nursery-capacity))
