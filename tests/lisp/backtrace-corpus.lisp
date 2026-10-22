;; Backtraces taken from a debugger hook, N calls deep into a recursion
;; for N from 1 to 10. Each lists exactly the N calls of DESCEND,
;; innermost first, with the argument each was called with and where each
;; call was written: the recursive call in DESCEND for all but the
;; outermost, and the case's own call for that one.

(progn
  (defmacro backtrace-of (form)
    `(block captured
       (let ((*debugger-hook* (lambda (condition hook)
                                (declare (ignore condition hook))
                                (return-from captured (backtrace)))))
         ,form)))

  (defun descend (n)
    (if (= n 1)
        (error "Reached the bottom.")
        (1+ (descend (1- n)))))

  (defun expected-frames (depth line column)
    "The frames a backtrace DEPTH calls deep lists, when the outermost call
was written at LINE and COLUMN."
    (loop for n from 1 to depth
          collect (list "DESCEND"
                        (if (= n depth)
                            (list "backtrace-corpus.lisp" line column)
                            (list "backtrace-corpus.lisp" 18 13))
                        (list n))))
  t)

(equal (backtrace-of (descend 1)) (expected-frames 1 31 22))
(equal (backtrace-of (descend 2)) (expected-frames 2 32 22))
(equal (backtrace-of (descend 3)) (expected-frames 3 33 22))
(equal (backtrace-of (descend 4)) (expected-frames 4 34 22))
(equal (backtrace-of (descend 5)) (expected-frames 5 35 22))
(equal (backtrace-of (descend 6)) (expected-frames 6 36 22))
(equal (backtrace-of (descend 7)) (expected-frames 7 37 22))
(equal (backtrace-of (descend 8)) (expected-frames 8 38 22))
(equal (backtrace-of (descend 9)) (expected-frames 9 39 22))
(equal (backtrace-of (descend 10)) (expected-frames 10 40 22))
