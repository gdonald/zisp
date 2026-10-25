;; How much faster a loop compiled with (speed 3) runs than the same
;; loop compiled with (speed 0). `zig build optimize-bench` loads this on
;; a ReleaseFast build and fails below *optimize-bench-ratio*.

(defvar *optimize-bench-ratio* 2)
(defvar *optimize-bench-rounds* 5)

(declaim (inline optimize-bench-square))
(defun optimize-bench-square (x) (* x x))

(defun optimize-bench-slow (n)
  (declare (optimize (speed 0)))
  (let ((sum 0))
    (dotimes (i n sum)
      (setq sum (+ sum (optimize-bench-square (1+ i)))))))

(defun optimize-bench-fast (n)
  (declare (optimize (speed 3)))
  (let ((sum 0))
    (dotimes (i n sum)
      (setq sum (+ sum (optimize-bench-square (1+ i)))))))

(compile 'optimize-bench-slow)
(compile 'optimize-bench-fast)

(defun optimize-bench-time (function)
  (let ((best nil))
    (dotimes (round *optimize-bench-rounds* best)
      (let ((start (get-internal-run-time)))
        (unless (eql (funcall function 1000000) 333333833333500000)
          (error "the benchmark loop summed to the wrong total"))
        (let ((spent (- (get-internal-run-time) start)))
          (when (or (null best) (< spent best))
            (setq best spent)))))))

(let* ((slow (optimize-bench-time #'optimize-bench-slow))
       (fast (max 1 (optimize-bench-time #'optimize-bench-fast)))
       (ratio (/ slow fast)))
  (format t "OPTIMIZE-BENCH speed 0 ~,1f ms, speed 3 ~,1f ms, ~,1fx~%"
          (/ (* 1000.0 slow) internal-time-units-per-second)
          (/ (* 1000.0 fast) internal-time-units-per-second)
          ratio)
  (when (< ratio *optimize-bench-ratio*)
    (error "(speed 3) is ~,1f times as fast as (speed 0), below ~a" ratio *optimize-bench-ratio*)))
