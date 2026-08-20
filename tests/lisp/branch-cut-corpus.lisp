;; Complex branch cuts, per CLHS 12.1.5.3.
;;
;; Each function's cut runs along part of an axis, and the function is
;; continuous with one side of it. The value on the cut must agree with the
;; value just off it on that side, and differ from the other side. The
;; sides below are the ones CLHS names.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (setq above (complex 0.0d0 1.0d-14))
  (setq below (complex 0.0d0 -1.0d-14))

  (defun close-enough (a b)
    (< (abs (- a b)) 1.0d-9))
  (defun continuous-from (f point side)
    "F on the cut agrees with F just off it on SIDE and not on the other."
    (and (close-enough (funcall f point) (funcall f (+ point side)))
         (not (close-enough (funcall f point) (funcall f (- point side))))))
  t)

;; sqrt: cut along the negative real axis, continuous with quadrant II, so
;; the square root of a negative real has a positive imaginary part.
(and (= (sqrt -1) (complex 0.0 1.0))
     (close-enough (sqrt (complex -4.0d0 0.0d0)) (complex 0.0d0 2.0d0))
     (continuous-from #'sqrt (complex -4.0d0 0.0d0) above)
     (plusp (imagpart (sqrt -4.0d0))))

;; Below that cut the root is the conjugate of the value on it.
(close-enough (sqrt (complex -4.0d0 -1.0d-14))
              (conjugate (sqrt (complex -4.0d0 1.0d-14))))

;; log: cut along the negative real axis, continuous with quadrant II, so
;; the log of a negative real has imaginary part +pi.
(and (close-enough (log (complex -1.0d0 0.0d0)) (complex 0.0d0 pi))
     (continuous-from #'log (complex -1.0d0 0.0d0) above)
     (plusp (imagpart (log -1.0d0)))
     (minusp (imagpart (log (complex -1.0d0 -1.0d-14)))))

;; A positive real argument keeps log real, and log of zero is an error.
(and (close-enough (log 1.0d0) 0.0d0)
     (close-enough (log 100.0d0 10.0d0) 2.0d0)
     (not (complexp (log 2.0d0))))

;; asin: cuts along the real axis outside [-1, 1]. Past +1 it is
;; continuous with quadrant IV, so the imaginary part there is negative.
(and (close-enough (asin 0.0d0) 0.0d0)
     (not (complexp (asin 0.5d0)))
     (complexp (asin 2.0d0))
     (continuous-from #'asin (complex 2.0d0 0.0d0) below)
     (minusp (imagpart (asin 2.0d0)))
     (plusp (imagpart (asin -2.0d0))))

;; acos: the same cuts, also continuous with quadrant IV past +1.
(and (close-enough (acos 1.0d0) 0.0d0)
     (complexp (acos 2.0d0))
     (continuous-from #'acos (complex 2.0d0 0.0d0) below)
     (close-enough (+ (asin 0.3d0) (acos 0.3d0)) (/ pi 2)))

;; atan: cuts along the imaginary axis outside [-i, i], and it stays real
;; on the whole real line.
(and (close-enough (atan 0.0d0) 0.0d0)
     (close-enough (atan 1.0d0) (/ pi 4))
     (not (complexp (atan 5.0d0)))
     (complexp (atan (complex 0.0d0 2.0d0))))

;; atanh: cuts along the real axis outside [-1, 1], continuous with
;; quadrant IV past +1.
(and (close-enough (atanh 0.0d0) 0.0d0)
     (not (complexp (atanh 0.5d0)))
     (complexp (atanh 2.0d0))
     (continuous-from #'atanh (complex 2.0d0 0.0d0) below)
     (minusp (imagpart (atanh 2.0d0))))

;; phase: +pi on the negative real axis, matching log's cut, and zero on
;; the positive one.
(and (close-enough (phase -1.0d0) pi)
     (close-enough (phase 1.0d0) 0.0d0)
     (close-enough (phase (complex 0.0d0 1.0d0)) (/ pi 2))
     (close-enough (phase (complex -1.0d0 -1.0d-14)) (- pi)))

;; Each inverse undoes its function even where the argument left the reals.
(and (close-enough (sin (asin 2.0d0)) (complex 2.0d0 0.0d0))
     (close-enough (cos (acos 2.0d0)) (complex 2.0d0 0.0d0))
     (close-enough (tanh (atanh 2.0d0)) (complex 2.0d0 0.0d0))
     (close-enough (sinh (asinh 2.0d0)) 2.0d0)
     (close-enough (cosh (acosh 0.5d0)) (complex 0.5d0 0.0d0))
     (close-enough (exp (log -3.0d0)) (complex -3.0d0 0.0d0))
     (close-enough (* (sqrt -3.0d0) (sqrt -3.0d0)) (complex -3.0d0 0.0d0)))
