;; Every form here must evaluate to T.
;;
;; What each `optimize` quality changes in compiled code, read off
;; `disassemble`'s listing. `docs/optimize-levels.md` says what each
;; level does.

(progn
  (defun optimize-listing (function)
    (with-output-to-string (*standard-output*) (disassemble function)))
  (defun optimize-instructions (function)
    "How many instructions the listing of FUNCTION has."
    (let ((listing (optimize-listing function))
          (count 0))
      (with-input-from-string (in (subseq listing 0 (search "Constants:" listing)))
        (loop for line = (read-line in nil)
              while line
              when (and (> (length line) 5) (digit-char-p (char line 4)))
                do (incf count)))
      count))
  (defun optimize-mentions (function text)
    (let ((listing (optimize-listing function)))
      (not (null (search text listing :end2 (search "Constants:" listing))))))
  (declaim (inline optimize-double))
  (defun optimize-double (x) (+ x x))
  t)

;;; safety

;; (safety 0) drops the check `the` makes, so the code is smaller.
(progn
  (defun optimize-the-safe (x) (declare (optimize (safety 3))) (car (the cons x)))
  (defun optimize-the-unsafe (x) (declare (optimize (safety 0))) (car (the cons x)))
  (and (optimize-mentions 'optimize-the-safe "CHECK_TYPE")
       (not (optimize-mentions 'optimize-the-unsafe "CHECK_TYPE"))
       (< (optimize-instructions 'optimize-the-unsafe) (optimize-instructions 'optimize-the-safe))))

;; (safety 3) checks a declared type where a value is bound.
(progn
  (defun optimize-declared-safe (x) (declare (fixnum x) (optimize (safety 3))) x)
  (defun optimize-declared-unsafe (x) (declare (fixnum x) (optimize (safety 0))) x)
  (compile 'optimize-declared-safe)
  (compile 'optimize-declared-unsafe)
  (and (eq (handler-case (optimize-declared-safe 'a) (type-error () :checked)) :checked)
       (< (optimize-instructions 'optimize-declared-unsafe) (optimize-instructions 'optimize-declared-safe))))

;; (safety 0) does not check how many arguments a call passed.
(progn
  (defun optimize-count-safe (x) (declare (optimize (safety 3))) x)
  (defun optimize-count-unsafe (x) (declare (optimize (safety 0))) x)
  (compile 'optimize-count-safe)
  (compile 'optimize-count-unsafe)
  (and (eq (handler-case (funcall 'optimize-count-safe 1 2) (program-error () :checked)) :checked)
       (eql (funcall 'optimize-count-unsafe 1 2) 1)))

;;; speed

;; (speed 0) calls `+` where (speed 1) adds in place.
(progn
  (defun optimize-add-slow (x) (declare (optimize (speed 0))) (+ x 1))
  (defun optimize-add-fast (x) (declare (optimize (speed 1))) (+ x 1))
  (and (optimize-mentions 'optimize-add-slow "CALL_GLOBAL")
       (optimize-mentions 'optimize-add-fast "ADD")
       (not (optimize-mentions 'optimize-add-fast "CALL_GLOBAL"))))

;; (speed 3) expands an inline function where (speed 0) calls it.
(progn
  (defun optimize-inline-slow (y) (declare (optimize (speed 0))) (optimize-double y))
  (defun optimize-inline-fast (y) (declare (optimize (speed 3))) (optimize-double y))
  (and (optimize-mentions 'optimize-inline-slow "CALL_GLOBAL")
       (not (optimize-mentions 'optimize-inline-fast "CALL_GLOBAL"))
       (eql (optimize-inline-fast 7) 14)))

;; A (speed 3) loop makes no calls at all where the (speed 0) one makes
;; one call each time round for every operation.
(progn
  (defun optimize-loop-slow (n)
    (declare (optimize (speed 0)))
    (let ((sum 0)) (dotimes (i n sum) (setq sum (+ sum (optimize-double i))))))
  (defun optimize-loop-fast (n)
    (declare (optimize (speed 3)))
    (let ((sum 0)) (dotimes (i n sum) (setq sum (+ sum (optimize-double i))))))
  (compile 'optimize-loop-slow)
  (compile 'optimize-loop-fast)
  (and (eql (optimize-loop-slow 1000) (optimize-loop-fast 1000))
       (>= (reduce #'+ (mapcar (lambda (site) (+ (getf site :monomorphic) (getf site :misses)))
                               (%call-site-counters #'optimize-loop-slow)))
           2000)
       (null (%call-site-counters #'optimize-loop-fast))))

;;; debug

;; (debug 0) keeps no variable names for the listing to show.
(progn
  (defun optimize-names-kept (apple) (declare (optimize (debug 1))) (list apple))
  (defun optimize-names-dropped (apple) (declare (optimize (debug 0))) (list apple))
  (and (optimize-mentions 'optimize-names-kept "APPLE")
       (not (optimize-mentions 'optimize-names-dropped "APPLE"))))

;; (debug 3) keeps the line each call was written on.
(progn
  (load "tests/lisp/optimize-debug-source.lisp")
  (and (optimize-mentions 'optimize-debug-positions "line 5")
       (optimize-mentions 'optimize-debug-positions "line 6")
       (search "Source: optimize-debug-source.lisp" (optimize-listing 'optimize-debug-positions))
       t))

;; (debug 3) keeps a call in tail position from replacing its caller's
;; frame, so a backtrace shows it.
(progn
  (defun optimize-tail-replaced (x) (declare (optimize (debug 1))) (list x))
  (defun optimize-tail-kept (x) (declare (optimize (debug 3))) (list x))
  (and (optimize-mentions 'optimize-tail-replaced "tail")
       (not (optimize-mentions 'optimize-tail-kept "tail"))))

;;; space

;; (space 3) calls an inline function rather than expanding it, so the
;; code is smaller.
(progn
  (defun optimize-space-large (y) (declare (optimize (space 0))) (+ (optimize-double y) (optimize-double (1+ y))))
  (defun optimize-space-small (y) (declare (optimize (space 3))) (+ (optimize-double y) (optimize-double (1+ y))))
  (< (optimize-instructions 'optimize-space-small) (optimize-instructions 'optimize-space-large)))

;; Under (space 0) the inline function's name is nowhere in the code.
(progn
  (defun optimize-space-expanded (y) (declare (optimize (space 0))) (optimize-double y))
  (defun optimize-space-called (y) (declare (optimize (space 3))) (optimize-double y))
  (and (not (member 'optimize-double (%function-constants (%compile-function #'optimize-space-expanded))))
       (member 'optimize-double (%function-constants (%compile-function #'optimize-space-called)))
       (eql (optimize-space-expanded 3) (optimize-space-called 3))))

;; (speed 3) expands an inline function even under (space 3).
(progn
  (defun optimize-space-overruled (y) (declare (optimize (space 3) (speed 3))) (optimize-double y))
  (not (optimize-mentions 'optimize-space-overruled "CALL_GLOBAL")))
