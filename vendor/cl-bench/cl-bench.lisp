;;;; cl-bench.lisp

(in-package #:cl-bench)

(defun bench-gc ()
  (trivial-garbage:gc :full t))

#+ (or)
(defun bench-time ()
  (error "use metering"))

(let ((root-dir (asdf:system-source-directory '#:cl-bench)))
  (defparameter *root-dir* root-dir
    "Toplevel directory of the CL-BENCH system.")
  (defparameter *misc-dir* (merge-pathnames "misc/" root-dir)
    "Directory containing auxilliary files.")
  (defparameter *output-dir* (merge-pathnames "output/" root-dir)
    "Directory where the results are stored.")

  ;; don't use logical pathnames (not well supported on all active
  ;; implementations. These would be the translations if everything
  ;; would work as expected).
  #+(or)
  (setf (logical-pathname-translations "bench")
        `(("root;*.*.*"   ,root-dir)
          ("test;*.*.*"   ,(merge-pathnames "files/"  root-dir))
          ("misc;*.*.*"   ,(merge-pathnames "misc/" root-dir))
          ("result;*.*.*" ,(merge-pathnames "output/" root-dir))
          ("**;*.*.*"     ,(merge-pathnames "**/" root-dir)))))

(ensure-directories-exist *output-dir*)


;;; This is disabled after the consultation with the ABCL maintainer
#+(and abcl (or))
(eval-when (:load-toplevel :execute)
  (format *debug-io* "Loading JVM compiler ...~%")
  (load "/opt/src/cvs-armedbear/j/src/org/armedbear/lisp/jvm.lisp")
  (dolist (p '("CL" "SYS" "EXT" "PRECOMPILER"))
    (jvm::jvm-compile-package p))
  (format *debug-io* "Compiling all cl-bench packages ...~%")
  (dolist (p (list-all-packages))
    (when (eql 0 (search "CL-BENCH" (package-name p)))
      (jvm::jvm-compile-package p))))


#+allegro
(progn
  (setq excl:*record-source-file-info* nil)
  (setq excl:*load-source-file-info* nil)
  (setq excl:*record-xref-info* nil)
  (setq excl:*load-xref-info* nil)
  (setq excl:*global-gc-behavior* nil))


#+clisp
(progn
  (setq custom:*warn-on-floating-point-contagion* nil))


#+clozure
(progn
  (ccl:set-lisp-heap-gc-threshold (ash 2 20)))


#+cmu
(progn
  (setq ext:*bytes-consed-between-gcs* 25000000)
  ;; to avoid problems when running the bignum code (the default of
  ;; 40000 is too low for some of the tests)
  (setq ext:*intexp-maximum-exponent* 100000))


#+ecl
(progn
  (require 'cmp)
  (ext:set-limit 'ext:c-stack (* 8 1024 1024))
  #-ecl-bytecmp
  (setq c::*cc-flags* (concatenate 'string "-I. " c::*cc-flags*)))


#+lispworks
(progn
  (setq system:*stack-overflow-behaviour* nil)
  (hcl:toggle-source-debugging nil))


#+sbcl
(progn
  (setf (sb-ext:bytes-consed-between-gcs) 25000000))

 ;; i.e GCL
(eval-when (compile load eval)
  (unless (fboundp 'fdefinition)
    (eval-when (load eval)
      (warn "This is not ANSI conforming Common Lisp. Expect problems."))
    (defun fdefinition (symbol)
      (symbol-function symbol))
    (defsetf fdefinition (name) (new-definition)
      `(setf (symbol-function ,name) ,new-definition))))
