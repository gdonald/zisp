;;; graph-report.lisp
;;
;; Author: Johannes Grrdem <johs@copyleft.no>
;; Time-stamp: <2016-05-13 12:25:11 jack>
;;
;;
;; When loaded into CMUCL, this should generate a report comparing the
;; performance of the different CL implementations which have been
;; tested. Reads the output/CL-benchmark* files to obtain data from
;; previous runs.

(in-package #:cl-bench)

(defparameter *screen-width* 80)

(defun print-bar (scale)
  (if (< scale 0)
      (princ "n/a")
      (let ((chars (* (- *screen-width* 18)
		      scale)))
	(if (< chars 1)
	    (princ #\%)
	    (dotimes (i (round chars))
	      (princ #\#))))))

(defun bench-analysis-graph ()
  (let (data implementations benchmarks impl-scores)
    (dolist (f (directory (merge-pathnames "CL-benchmark*.*" *output-dir*)))
       (with-open-file (f f :direction :input)
         (let ((*read-eval* nil))
           (push (read f) data))))
    (setf implementations (mapcar #'car data))
    (setf impl-scores (make-list (length implementations)
				 :initial-element 0))
    (setf benchmarks (reverse (mapcar #'first (cdr (first data)))))
    (dolist (b benchmarks)
      (format t "=== ~a~%" b)
      (let* ((results
	      (loop :for i in implementations
		    :collect (let* ((id (cdr (assoc i data :test #'string=)))
				    (ir (third (assoc b id :test #'string=))))
			       (if (numberp ir)
				   ir
				   -1))))
	     (ref (apply #'max results))
	     (min (apply #'min (remove -1 results))))
	(loop :for res in results
	      :for cnt from 0
	      :do (let ((i (elt implementations cnt)))
		    (format t "~&~a~5a (~6,2,0,'XF): "
			    (if (= res min)
				(progn
				  (incf (elt impl-scores cnt))
				  #\>)
			        #\Space)
			    (subseq i 0 (min (length i) 5))
			    res)
		    (print-bar (/ res ref)))))
      (terpri)
      (terpri))

    (format t "~&--- Total wins: ---------------------------------------------------------------~%")
    (loop :for impl in implementations
	  :for score in impl-scores
	  :do (progn
		(format t "~a~5a (~2d): "
			(if (= score (apply #'max impl-scores))
			    #\>
			    #\Space)
			(subseq impl 0 (min (length impl) 5))
			score)
		(dotimes (i score)
		  (princ #\#))
		(terpri)))

    (format t "~&~%===============================================================================~%")
    (dolist (impl implementations)
      (format t "~&Impl ~a: ~a~%"
	      (subseq impl 0 (min (length impl) 5))
	      impl))

    (force-output)))

;; (bench-analysis)
;; (quit)

;; EOF
