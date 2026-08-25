;;; support.lisp --- performance benchmarks for Common Lisp implementations
;;
;; Author: Eric Marsden  <emarsden@laas.fr>
;; Maintainer: Daniel Kochmański <daniel@turtleware.eu>
;;
;; Time-stamp: <2016-05-16 15:39:14 jack>
;;
;;
;; The benchmarks consist of
;;
;;   - the Gabriel benchmarks
;;   - some mathematical operations (factorial, fibonnaci, CRC)
;;   - some bignum-intensive operations
;;   - hashtable and READ-LINE tests
;;   - CLOS tests
;;   - array, string and bitvector exercises
;;

(in-package :cl-bench)

(defvar *version* "20160513")

(defvar *benchmarks* '())
(defvar *benchmark-results* '())

(defvar +implementation+
  (concatenate 'string
               (lisp-implementation-type) " "
               (lisp-implementation-version)))


(defclass benchmark ()
    ((name   :accessor benchmark-name
             :initarg :name)
     (short  :accessor benchmark-short
             :initarg :short
             :type string)
     (long   :accessor benchmark-long
             :initarg :long
             :initform ""
             :type string)
     (group  :accessor benchmark-group
             :initarg :group)
     (runs   :accessor benchmark-runs
             :initarg :runs
             :initform 1
             :type integer)
     (disabled-for :accessor benchmark-disabled-for
                   :initarg :disabled-for
                   :initform nil)
     (setup    :initarg :setup
               :initform nil)
     (function :initarg :function
               :accessor benchmark-function)))

(defmethod print-object ((self benchmark) stream)
  (print-unreadable-object (self stream :type nil)
     (format stream "benchmark ~a for ~d runs"
             (benchmark-short self)
             (benchmark-runs self))))

(defmethod initialize-instance :after ((self benchmark)
                                       &rest initargs
                                       &key &allow-other-keys)
   (declare (ignore initargs))
   (unless (slot-boundp self 'short)
     (setf (benchmark-short self) (string (benchmark-name self))))
   self)

;;    (setf (benchmark-function self)
;;          (compile nil `(lambda ()
;;                         (dotimes (i ,(benchmark-runs self))
;;                           `(funcall ',(benchmark-function ,self))))))


(defmacro defbench (fun &rest args)
  `(push (make-instance 'benchmark :name ',fun ,@args)
         *benchmarks*))



(defvar *benchmark-output*)
(defvar *current-test*)


(defmacro with-bench-output (&body body)
  `(with-open-file (f (benchmark-report-file)
                    :direction :output
                    :if-exists :supersede)
    (let ((*benchmark-output* f)
          (*load-verbose* nil)
          (*print-length* nil)
          (*compile-verbose* nil)
          (*compile-print* nil))
      (bench-report-header)
      (progn ,@body)
      (bench-report-footer))))

(defun bench-run-1 (benchmark &key force)
  (multiple-value-bind (real user sys consed)
      (if (and (not force)
               (some #'(lambda (bench)
                         (member bench *features*))
                     (benchmark-disabled-for benchmark)))
          (progn
            (format t "~&=== skipping disabled ~a~%" benchmark))
          (progn
            (bench-gc)
            (with-slots (setup function runs) benchmark
              (when setup (funcall setup))
              (format t "~&=== running ~a~%" benchmark)
              (bench-time function runs))))
    (push (list (slot-value benchmark 'short) real user sys consed)
          *benchmark-results*)))

(defun bench-run ()
  (with-open-file (f (benchmark-report-file)
                     :direction :output
                     :if-exists :supersede)
     (let ((*benchmark-output* f)
           (*print-length*)
           (*load-verbose* nil)
           (*compile-verbose* nil)
           (*compile-print* nil))
       (bench-report-header)
       (dolist (b (reverse *benchmarks*))
         (bench-run-1 b)
         (bench-report (car *benchmark-results*)))
       (bench-report-footer))))

(defun benchmark-report-file ()
  (multiple-value-bind (second minute hour date month year)
      (get-decoded-time)
    (declare (ignore second))
    (format nil "~aCL-benchmark-~d~2,'0d~2,'0dT~2,'0d~2,'0d"
            (namestring *output-dir*)
            year month date hour minute)))

(defun bench-report-header ()
  (format *benchmark-output*
          ";; -*- lisp -*-  ~a~%;;~%#| Implementation *features*: ~s |#~%;;~%"
          +implementation+ *features*)
  (format *benchmark-output*
          ";; Function                      real     user     sys       consed~%")
  (format *benchmark-output*
          ";; ----------------------------------------------------------------~%"))

(defun bench-report-footer ()
  (format *benchmark-output* "~%~s~%"
          (cons +implementation+ *benchmark-results*)))

;; generate a report to *benchmark-output* on the benchmark result
(defun bench-report (bench-result)
  (destructuring-bind (name real user sys consed) bench-result
    (format *benchmark-output*
            ";; ~25a ~8,2f ~8,2f ~8,2f ~12d"
            name real user sys consed)
    (terpri *benchmark-output*)
    (force-output *benchmark-output*)))

;; a generic timing function, that depends on GET-INTERNAL-RUN-TIME
;; and GET-INTERNAL-REAL-TIME returning sensible results. If a version
;; was defined in sysdep/setup-<impl>, we use that instead
(defun generic-bench-time (fun times)
  (let (before-real after-real before-user after-user)
    (setq before-user (get-internal-run-time))
    (setq before-real (get-internal-real-time))
    (dotimes (i times)
      (funcall fun))
    (setq after-user (get-internal-run-time))
    (setq after-real (get-internal-real-time))
    ;; return real user sys consed
    (values (coerce (/ (- after-real before-real) internal-time-units-per-second) 'float)
            (coerce (/ (- after-user before-user) internal-time-units-per-second) 'float)
            nil nil)))

(eval-when (:load-toplevel :execute)
  (unless (fboundp 'bench-time)
    (setf (fdefinition 'bench-time) #'generic-bench-time)))

;; EOF
