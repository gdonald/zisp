;;; The default debugger, which `invoke-debugger` runs when there is no
;;; `*debugger-hook*` and the REPL is reading from a person, and `break`.
;;;
;;; The debugger reads from `*debug-io*`, which in the REPL reads on from
;;; where the REPL's own input has got to. An integer invokes the restart
;;; listed under it, `:r NAME` the restart of that name, `:b` prints the
;;; backtrace, and any other
;;; form is evaluated in the lexical environment the condition was
;;; signaled in, with its values printed. The end of the input, or input
;;; that does not read, leaves through the innermost `abort` restart.

(in-package "COMMON-LISP")

(defvar *%debug-level* 0)

;; The condition the last debugger to return was entered on, so the REPL
;; does not enter a second one for it once it unwinds to the top level.
(defvar *%debugged-condition* nil)

;; The functions between the frame that signaled and the debugger. The
;; debugger evaluates forms where the outermost of them was called.
(defparameter *%condition-system-functions*
  '("%DEFAULT-DEBUGGER" "INVOKE-DEBUGGER" "ERROR" "CERROR" "SIGNAL" "WARN"
    "BREAK" "%UNBOUND-VARIABLE" "%DEBUG-TOP-LEVEL-FAILURE"))

(defun %error-site-depth ()
  "How far from the outermost frame the frame is whose call was made where
the condition was signaled. Counting from the outermost keeps the answer
good while the debugger calls further in."
  (let ((site 1))
    ;; Frame 0 is this function's own.
    (loop for index from 1 below (%frame-count)
          while (member (%frame-function-name index) *%condition-system-functions*
                        :test #'equal)
          do (setq site index))
    (- (%frame-count) 1 site)))

;; The functions a condition is signaled through, the first of which a
;; backtrace taken while one is being handled starts past.
(defparameter *%signaling-functions*
  '("ERROR" "CERROR" "SIGNAL" "WARN" "BREAK" "INVOKE-DEBUGGER"))

(defun ext::backtrace ()
  "The closure calls in progress, innermost first, each as `(name
position arguments)`. The name is a string, nil for an anonymous
function, and the position is `(file line column)` for where the call was
written, nil where that was not recorded. Taken while a condition is
being handled, from a debugger hook or the debugger, it starts at the
call that signaled."
  (let* ((count (%frame-count))
         (signaling (loop for index from 1 below count
                          when (member (%frame-function-name index) *%signaling-functions*
                                       :test #'equal)
                            return index))
         (start (if signaling
                    (loop for index from signaling below count
                          while (member (%frame-function-name index)
                                        *%condition-system-functions* :test #'equal)
                          finally (return index))
                    1)))
    (loop for index from start below count
          collect (list (%frame-function-name index)
                        (%frame-position index)
                        (%frame-arguments index)))))

(defun %print-backtrace (stream)
  (let ((index 0))
    (dolist (frame (ext::backtrace))
      (format stream ";;   ~d: (~a~{ ~s~})" index (or (car frame) "LAMBDA") (caddr frame))
      (when (cadr frame)
        (format stream " at ~a:~d:~d" (car (cadr frame)) (cadr (cadr frame)) (caddr (cadr frame))))
      (terpri stream)
      (setq index (1+ index)))))

(defun %print-debugger-banner (condition restarts stream)
  (format stream "~&;; Debugger entered on ~S:~%;;   ~A~%" (type-of condition) condition)
  (if restarts
      (let ((index 0))
        (format stream ";; Restarts:~%")
        (dolist (restart restarts)
          (format stream ";;   ~d: [~a] " index (restart-name restart))
          (%print-restart-report restart stream)
          (terpri stream)
          (setq index (1+ index))))
      (format stream ";; No restarts.~%")))

(defun %debugger-prompt (level stream)
  (if (= level 1)
      (format stream "Debug> ")
      (format stream "Debug[~d]> " level))
  (finish-output stream))

(defun %restart-named (name restarts)
  (find-if (lambda (restart)
             (and (restart-name restart)
                  (string-equal (symbol-name (restart-name restart)) (symbol-name name))))
           restarts))

(defun %debugger-evaluate (form site-depth level stream)
  "Evaluate FORM where the condition was signaled and print its values. A
failure in it enters a debugger one level in, whose `abort` comes back
here."
  (restart-case
      (dolist (result (multiple-value-list
                       (%frame-eval (- (%frame-count) 1 site-depth) form)))
        (format stream "~S~%" result))
    (abort ()
      :report (lambda (report-stream)
                (format report-stream "Return to debug level ~d." level))
      nil)))

(defun %default-debugger (condition)
  (let* ((*%debug-level* (1+ *%debug-level*))
         (level *%debug-level*)
         (stream *debug-io*)
         (site-depth (%error-site-depth))
         (restarts (compute-restarts condition))
         (end (list :end)))
    (%print-debugger-banner condition restarts stream)
    (loop
      (%debugger-prompt level stream)
      (let ((input (handler-case (read stream nil end)
                     (error ()
                       (format stream "~&;; The input does not read.~%")
                       end))))
        (cond ((eq input end)
               (fresh-line stream)
               (let ((abort (find-restart 'abort condition)))
                 (when abort (invoke-restart abort)))
               (setq *%debugged-condition* condition)
               (return nil))
              ((integerp input)
               (if (and (>= input 0) (< input (length restarts)))
                   (invoke-restart-interactively (nth input restarts))
                   (format stream ";; No restart numbered ~d.~%" input)))
              ((eq input :b)
               (%print-backtrace stream))
              ((eq input :r)
               (let* ((name (read stream nil end))
                      (restart (and (symbolp name) (%restart-named name restarts))))
                 (if restart
                     (invoke-restart-interactively restart)
                     (format stream ";; No restart named ~a.~%" name))))
              (t (%debugger-evaluate input site-depth level stream)))))))

(defun %debug-top-level-failure (caught)
  "Enter the debugger for a failure that unwound to the REPL before one
could be: a native's, or a condition re-signaled on the way out. True
unless the debugger was left through `abort`."
  (let ((condition (%coerce-caught caught)))
    (if (eq condition *%debugged-condition*)
        t
        (restart-case (progn (%default-debugger condition) t)
          (abort ()
            :report "Return to the top level."
            nil)))))

(defun break (&optional (format-control "Break") &rest format-arguments)
  "Enter the debugger without signaling, so no handler sees the
condition, and return nil once the `continue` restart is invoked."
  (with-simple-restart (continue "Return from BREAK.")
    (let ((*debugger-hook* nil))
      (invoke-debugger (make-condition 'simple-condition
                                       :format-control format-control
                                       :format-arguments format-arguments))))
  nil)

;; A call that signals keeps the frame that made it, so the place it was
;; signaled from stays in the backtrace even when the call is the last
;; thing a function does.
(dolist (name '(error cerror signal warn break invoke-debugger))
  (%keep-caller-frame (symbol-function name)))

(export '(break))
(export 'ext::backtrace "EXTENSIONS")

(in-package "COMMON-LISP-USER")
