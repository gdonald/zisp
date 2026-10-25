;; TAK compiled to bytecode, timed the way `tests/codegen/tak.c` times
;; its C renderings, so the two can be put side by side.

(defun codegen-tak (x y z)
  (if (not (< y x))
      z
      (codegen-tak (codegen-tak (1- x) y z)
                   (codegen-tak (1- y) z x)
                   (codegen-tak (1- z) x y))))

(compile 'codegen-tak)

(let ((start (get-internal-run-time)))
  (let ((result (codegen-tak 24 16 8)))
    (format t "TAK-BYTECODE ~d ~,1f ms~%" result
            (/ (* 1000.0 (- (get-internal-run-time) start)) internal-time-units-per-second))))
