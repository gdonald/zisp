;; Every form here must evaluate to T.
;;
;; A function declared inline is expanded where it is called, so the
;; caller's code holds no call to it, and no reference to its name.

(progn
  (defun inline-calls-p (caller callee)
    "Whether the compiled code of CALLER refers to CALLEE."
    (not (null (member callee (%function-constants (%compile-function (fdefinition caller)))))))
  (defun count-substring (part whole)
    (do ((start 0 (1+ found))
         (found (search part whole) (search part whole :start2 (1+ found)))
         (count 0 (1+ count)))
        ((null found) count)))
  (declaim (inline inline-double inline-quadruple inline-countdown))
  (defun inline-double (x) (+ x x))
  (defun inline-quadruple (x) (inline-double (inline-double x)))
  (defun inline-countdown (n) (if (= n 0) :done (inline-countdown (1- n))))
  t)

;; A call to an inline function is expanded.
(progn
  (defun inline-basic (y) (1+ (inline-double y)))
  (and (not (inline-calls-p 'inline-basic 'inline-double))
       (eql (inline-basic 5) 11)))

;; An inline function that calls another is expanded, and so is the
;; call inside it.
(progn
  (defun inline-transitive (y) (inline-quadruple y))
  (and (not (inline-calls-p 'inline-transitive 'inline-quadruple))
       (not (inline-calls-p 'inline-transitive 'inline-double))
       (eql (inline-transitive 3) 12)))

;; A function proclaimed inline in one file is expanded in another file
;; compiled after it.
(progn
  (load (compile-file "tests/lisp/inline-files/defines.lisp"
                      :output-file ".zig-cache/inline-defines.zfasl"))
  (load (compile-file "tests/lisp/inline-files/uses.lisp"
                      :output-file ".zig-cache/inline-uses.zfasl"))
  (and (not (member 'inline-file-triple (%function-constants #'inline-file-user)))
       (eql (inline-file-user 2) 7)))

;; A recursive inline function is expanded three deep, and the call
;; inside the third expansion is a real call.
(progn
  (defun inline-recursive (n) (inline-countdown n))
  (let ((listing (with-output-to-string (*standard-output*) (disassemble 'inline-recursive))))
    (and (inline-calls-p 'inline-recursive 'inline-countdown)
         (eql (count-substring "CALL_GLOBAL" listing) 1)
         (eq (inline-recursive 10) :done))))

;; A local notinline declaration overrides the proclamation.
(progn
  (defun inline-refused (y) (declare (notinline inline-double)) (inline-double y))
  (and (inline-calls-p 'inline-refused 'inline-double)
       (eql (inline-refused 4) 8)))

;; A local inline declaration expands a function proclaimed notinline.
(progn
  (declaim (notinline inline-double))
  (defun inline-asked (y) (declare (inline inline-double)) (inline-double y))
  (defun inline-not-asked (y) (inline-double y))
  (compile 'inline-asked)
  (compile 'inline-not-asked)
  (declaim (inline inline-double))
  (and (not (inline-calls-p 'inline-asked 'inline-double))
       (inline-calls-p 'inline-not-asked 'inline-double)))
