;; Tail calls run for as long as one likes in constant space. Each loop
;; below calls itself, or its partner, in tail position until
;; *tco-soak-seconds* have passed, and then reports how many calls it
;; made and how many more frames were in progress at the end than at
;; the start. `zig build tco-soak` runs it, and fails when any frame
;; count grew.

(defvar *tco-soak-seconds* 60)

(defmacro define-soak (name (count deadline start) &body body)
  `(defun ,name (,count ,deadline ,start)
     (if (> (get-internal-real-time) ,deadline)
         (list ,count (- *tco-frame-counter* ,start))
         (progn ,@body))))

(define-soak soak-self (n deadline start) (soak-self (1+ n) deadline start))
(define-soak soak-even (n deadline start) (soak-odd (1+ n) deadline start))
(define-soak soak-odd (n deadline start) (soak-even (1+ n) deadline start))
(define-soak soak-if (n deadline start)
  (if (evenp n) (soak-if (1+ n) deadline start) (soak-if (+ n 1) deadline start)))
(define-soak soak-progn (n deadline start) (progn n (soak-progn (1+ n) deadline start)))
(define-soak soak-let (n deadline start) (let ((next (1+ n))) (soak-let next deadline start)))
(define-soak soak-cond (n deadline start)
  (cond ((evenp n) (soak-cond (1+ n) deadline start)) (t (soak-cond (1+ n) deadline start))))
(define-soak soak-when (n deadline start) (when t (soak-when (1+ n) deadline start)))
(define-soak soak-unless (n deadline start) (unless nil (soak-unless (1+ n) deadline start)))
(define-soak soak-block (n deadline start) (block soaking (soak-block (1+ n) deadline start)))

(defparameter *soaks*
  '(soak-self soak-even soak-if soak-progn soak-let soak-cond soak-when soak-unless soak-block))

(dolist (name (cons 'soak-odd *soaks*)) (compile name))

(defun soak-even-odd-to (n)
  (labels ((even (k) (if (= k 0) t (odd (1- k))))
           (odd (k) (if (= k 0) nil (even (1- k)))))
    (even n)))
(compile 'soak-even-odd-to)

(format t "TCO-SOAK even-odd ~a ~a~%" (expt 10 7) (soak-even-odd-to (expt 10 7)))
(dolist (name *soaks*)
  (let* ((deadline (+ (get-internal-real-time) (* *tco-soak-seconds* internal-time-units-per-second)))
         (result (funcall name 0 deadline (1+ *tco-frame-counter*))))
    (format t "TCO-SOAK ~(~a~) ~d calls, ~d frames grown~%" name (first result) (second result))
    (unless (eql (second result) 0)
      (error "~a grew the frames in progress by ~d" name (second result)))))
