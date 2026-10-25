;; Every form here must evaluate to T.
;;
;; A call in tail position replaces its caller's frame, so a compiled
;; tail-recursive loop of a million calls ends with the same number of
;; calls in progress, `ext:*tco-frame-counter*`, as its first call saw.
;; Each function returns how many more frames are in progress at its
;; last call than at its first, which is 0 when nothing grew.

(progn
  (defun tco-self (n start)
    (if (= n 0) (- *tco-frame-counter* start) (tco-self (1- n) start)))
  (defun tco-even (n start)
    (if (= n 0) (- *tco-frame-counter* start) (tco-odd (1- n) start)))
  (defun tco-odd (n start)
    (if (= n 0) (- *tco-frame-counter* start) (tco-even (1- n) start)))
  (defun tco-progn (n start)
    (progn (+ n 1) (if (= n 0) (- *tco-frame-counter* start) (tco-progn (1- n) start))))
  (defun tco-let (n start)
    (let ((next (1- n)))
      (if (= n 0) (- *tco-frame-counter* start) (tco-let next start))))
  (defun tco-cond (n start)
    (cond ((= n 0) (- *tco-frame-counter* start))
          ((evenp n) (tco-cond (1- n) start))
          (t (tco-cond (1- n) start))))
  (defun tco-when (n start)
    (when (>= n 0)
      (if (= n 0) (- *tco-frame-counter* start) (tco-when (1- n) start))))
  (defun tco-unless (n start)
    (unless (< n 0)
      (if (= n 0) (- *tco-frame-counter* start) (tco-unless (1- n) start))))
  (defun tco-block (n start)
    (block counting
      (when (= n 0) (return-from counting (- *tco-frame-counter* start)))
      (tco-block (1- n) start)))
  (dolist (name '(tco-self tco-even tco-odd tco-progn tco-let tco-cond tco-when tco-unless tco-block))
    (compile name))
  t)

(eql (funcall 'tco-self 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-even 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-progn 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-let 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-cond 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-when 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-unless 1000000 (1+ *tco-frame-counter*)) 0)
(eql (funcall 'tco-block 1000000 (1+ *tco-frame-counter*)) 0)
