;; Float printing corpus.
;;
;; Fifty values covering both float types, both signs, the fixed-point and
;; exponential print forms, and the boundaries between them. Each top-level
;; form is self-checking and evaluates to T.
;;
;; The round-trip check is bitwise: eql on floats compares bit patterns, so
;; 0.0 and -0.0 are distinct and a printed value that reads back to the
;; wrong bits fails.

(progn
  (defun round-trips (x)
    (eql (read-from-string (prin1-to-string x)) x))
  (defun prints-as (x text)
    (string= (prin1-to-string x) text))
  t)

;; Fixed-point form, single-float, which is the default type and so takes
;; no exponent marker.
(and (prints-as 0.0 "0.0")
     (prints-as -0.0 "-0.0")
     (prints-as 1.0 "1.0")
     (prints-as -1.0 "-1.0")
     (prints-as 0.5 "0.5")
     (prints-as 1.5 "1.5")
     (prints-as 100.0 "100.0")
     (prints-as 0.001 "0.001"))

;; Fixed-point form, double-float, which carries its marker and a zero
;; exponent.
(and (prints-as 0.0d0 "0.0d0")
     (prints-as 1.0d0 "1.0d0")
     (prints-as -2.5d0 "-2.5d0")
     (prints-as 0.001d0 "0.001d0"))

;; The boundaries of the fixed-point range from CLHS 22.1.3.1.3.
(and (prints-as 1.0e-3 "0.001")
     (prints-as 1.0e-4 "1.0e-4")
     (prints-as 9999999.0 "9999999.0")
     (prints-as 1.0e7 "1.0e7")
     (prints-as 1.0d7 "1.0d7")
     (prints-as 1.0d-4 "1.0d-4"))

;; Exponential form spells the default type's exponent with e and any
;; other type with its own marker.
(and (prints-as 1.0e23 "1.0e23")
     (prints-as 1.0d23 "1.0d23")
     (prints-as -1.0e23 "-1.0e23")
     (prints-as 1.0d100 "1.0d100"))

;; Every value above reads back to the bits it came from.
(and (round-trips 0.0)
     (round-trips -0.0)
     (round-trips 1.0)
     (round-trips -1.0)
     (round-trips 0.5)
     (round-trips 1.5)
     (round-trips 100.0)
     (round-trips 0.001)
     (round-trips 3.14159)
     (round-trips 2.7182817)
     (round-trips 123456.7)
     (round-trips 1.0e-4)
     (round-trips 1.0e7)
     (round-trips 1.0e23)
     (round-trips -1.0e23)
     (round-trips 1.0e-30)
     (round-trips 3.4028235e38)
     (round-trips 1.1754944e-38))

(and (round-trips 0.0d0)
     (round-trips -0.0d0)
     (round-trips 1.0d0)
     (round-trips -2.5d0)
     (round-trips 0.001d0)
     (round-trips 3.141592653589793d0)
     (round-trips 2.718281828459045d0)
     (round-trips 1.0d-4)
     (round-trips 1.0d7)
     (round-trips 1.0d23)
     (round-trips 1.0d100)
     (round-trips 1.0d-100)
     (round-trips 1.7976931348623157d308)
     (round-trips 2.2250738585072014d-308)
     (round-trips 5.0d-324)
     (round-trips 1.234567890123456d0)
     (round-trips 9.007199254740993d15)
     (round-trips -1.7976931348623157d308))

;; A printed float always shows a decimal point, so it reads back as a
;; float rather than an integer.
(and (not (null (find #\. (prin1-to-string 1.0))))
     (not (null (find #\. (prin1-to-string 1.0d0))))
     (not (null (find #\. (prin1-to-string 1.0e23))))
     (not (null (find #\. (prin1-to-string 1.0d23)))))

;; 0.0 and -0.0 print differently and stay distinct through a round trip.
(and (not (string= (prin1-to-string 0.0) (prin1-to-string -0.0)))
     (not (eql 0.0 -0.0))
     (eql (read-from-string "-0.0") -0.0)
     (eql (read-from-string "0.0") 0.0))
