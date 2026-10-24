;; How much faster a compiled loop runs than the same loop interpreted.
;;
;; `zig build bytecode-bench` loads this on a ReleaseFast build. Each
;; side's time is the best of several rounds, and the run fails when the
;; compiled loop is not *bytecode-bench-ratio* times as fast.

(defvar *bytecode-bench-ratio* 3)
(defvar *bytecode-bench-rounds* 5)

(defun bytecode-bench-interpreted ()
  (loop for i from 0 to 1000000 sum i))

(defparameter *bytecode-bench-compiled*
  (compile nil '(lambda () (loop for i from 0 to 1000000 sum i))))

(defun bytecode-bench-time (function)
  (let ((best nil))
    (dotimes (round *bytecode-bench-rounds* best)
      (let ((start (get-internal-run-time)))
        (unless (eql (funcall function) 500000500000)
          (error "the benchmark loop summed to the wrong total"))
        (let ((spent (- (get-internal-run-time) start)))
          (when (or (null best) (< spent best))
            (setq best spent)))))))

(let* ((interpreted (bytecode-bench-time #'bytecode-bench-interpreted))
       (compiled (max 1 (bytecode-bench-time *bytecode-bench-compiled*)))
       (ratio (/ interpreted compiled)))
  (format t "BYTECODE-BENCH interpreted ~,1f ms, compiled ~,1f ms, ~,1fx~%"
          (/ (* 1000.0 interpreted) internal-time-units-per-second)
          (/ (* 1000.0 compiled) internal-time-units-per-second)
          ratio)
  (when (< ratio *bytecode-bench-ratio*)
    (error "the compiled loop is ~,1f times as fast, below ~a" ratio *bytecode-bench-ratio*)))
