;; Processor time the bytecode VM takes over cl-bench's Gabriel
;; benchmarks, compiled. `tests/run-dispatch-bench.sh` loads the
;; benchmarks with `ext:*evaluator-mode*` set to `:compile` ahead of
;; this file, once for each way of building the VM's dispatch loop.
;;
;; Each benchmark's figure is the best of three rounds, and the last
;; line is their total in milliseconds.

(defvar *dispatch-bench-rounds* 3)

(defparameter *dispatch-benchmarks*
  '(cl-bench.gabriel::run-tak cl-bench.gabriel::run-stak cl-bench.gabriel::run-takl
    cl-bench.gabriel::run-ctak cl-bench.gabriel::boyer cl-bench.gabriel::deriv-run
    cl-bench.gabriel::dderiv-run cl-bench.gabriel::run-destructive
    cl-bench.gabriel::run-div2-test1 cl-bench.gabriel::run-div2-test2
    cl-bench.gabriel::run-traverse cl-bench.gabriel::run-puzzle
    cl-bench.gabriel::run-triangle cl-bench.gabriel::browse))

(defun dispatch-bench-time (name)
  (let ((best nil))
    (dotimes (round *dispatch-bench-rounds* best)
      (let ((start (get-internal-run-time)))
        (funcall name)
        (let ((spent (- (get-internal-run-time) start)))
          (when (or (null best) (< spent best))
            (setq best spent)))))))

(let ((total 0))
  (dolist (name *dispatch-benchmarks*)
    (let ((spent (dispatch-bench-time name)))
      (setq total (+ total spent))
      (format t "DISPATCH-BENCH ~a ~,1f~%" (string-downcase (symbol-name name))
              (/ (* 1000.0 spent) internal-time-units-per-second))))
  (format t "DISPATCH-BENCH total ~,1f~%" (/ (* 1000.0 total) internal-time-units-per-second)))
