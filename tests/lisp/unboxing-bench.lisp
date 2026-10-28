;; How much faster typed loops run compiled than interpreted.
;;
;; `zig build unboxing-bench` loads this on a ReleaseFast build. Each
;; benchmark is one lambda, run interpreted and compiled. Each side's
;; time is the best of several rounds, and the run fails when a compiled
;; one is not *unboxing-bench-ratio* times as fast.

(defvar *unboxing-bench-ratio* 10)
(defvar *unboxing-bench-rounds* 3)

(defvar *unboxing-bench-failures* 0)

(defun unboxing-bench-time (function args expected)
  (let ((best nil))
    (dotimes (round *unboxing-bench-rounds* best)
      (let ((start (get-internal-run-time)))
        (unless (eql (apply function args) expected)
          (error "the benchmark gave ~s, not ~s" (apply function args) expected))
        (let ((spent (- (get-internal-run-time) start)))
          (when (or (null best) (< spent best))
            (setq best spent)))))))

(defun unboxing-bench (name lambda args expected)
  (let* ((interpreted (unboxing-bench-time (eval lambda) args expected))
         (compiled (max 1 (unboxing-bench-time (compile nil lambda) args expected)))
         (ratio (/ interpreted compiled)))
    (format t "UNBOXING-BENCH ~a interpreted ~,1f ms, compiled ~,1f ms, ~,1fx~%"
            name
            (/ (* 1000.0 interpreted) internal-time-units-per-second)
            (/ (* 1000.0 compiled) internal-time-units-per-second)
            ratio)
    (when (< ratio *unboxing-bench-ratio*)
      (incf *unboxing-bench-failures*))))

(unboxing-bench "fixnum-sum"
                '(lambda () (loop for i fixnum from 0 to 1000000 sum i fixnum))
                '()
                500000500000)

(defparameter *unboxing-bench-vector*
  (let ((v (make-array 1000000)))
    (dotimes (i 1000000 v) (setf (svref v i) (if (evenp i) 0.5 0.25)))))

(unboxing-bench "dot-product"
                '(lambda (a b)
                  (declare (simple-vector a b))
                  (let ((sum 0.0))
                    (declare (single-float sum))
                    (dotimes (i (length a) sum)
                      (declare (fixnum i))
                      (setq sum (+ sum (* (the single-float (svref a i))
                                          (the single-float (svref b i))))))))
                (list *unboxing-bench-vector* *unboxing-bench-vector*)
                156250.0)

(unboxing-bench "factorial"
                '(lambda (n times)
                  (declare (type (integer 0 19) n) (fixnum times))
                  (let ((result 0))
                    (dotimes (k times result)
                      (declare (fixnum k))
                      (setq result
                            (do ((i 1 (1+ i))
                                 (acc 1 (* acc i)))
                                ((> i n) acc)
                              (declare (type (integer 1 20) i) (fixnum acc)))))))
                '(19 20000)
                121645100408832000)

(unboxing-bench "mandelbrot"
                '(lambda (size limit)
                  (declare (fixnum size limit))
                  (let ((inside 0))
                    (declare (fixnum inside))
                    (dotimes (y size inside)
                      (declare (fixnum y))
                      (dotimes (x size)
                        (declare (fixnum x))
                        (let ((cr (- (* 3.0 (/ (float x) size)) 2.0))
                              (ci (- (* 2.0 (/ (float y) size)) 1.0))
                              (zr 0.0)
                              (zi 0.0)
                              (escaped nil))
                          (declare (single-float cr ci zr zi))
                          (dotimes (k limit)
                            (declare (fixnum k))
                            (let ((zr2 (* zr zr))
                                  (zi2 (* zi zi)))
                              (when (> (+ zr2 zi2) 4.0)
                                (setq escaped t)
                                (return))
                              (setq zi (+ (* 2.0 zr zi) ci)
                                    zr (+ (- zr2 zi2) cr))))
                          (unless escaped (setq inside (1+ inside))))))))
                '(64 200)
                1057)

(when (plusp *unboxing-bench-failures*)
  (error "~d compiled benchmarks are below ~a times as fast" *unboxing-bench-failures* *unboxing-bench-ratio*))
