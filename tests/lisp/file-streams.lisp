;; Every form here must evaluate to T.
;;
;; Files written, read, positioned, renamed, listed and deleted, in a
;; directory relative to the current one. The last forms remove it.

(progn
  (defparameter *scratch* "zisp-file-streams/")
  (multiple-value-bind (pathspec created) (ensure-directories-exist "zisp-file-streams/nested/")
    (and (equal pathspec "zisp-file-streams/nested/") created)))
(null (nth-value 1 (ensure-directories-exist "zisp-file-streams/nested/")))

(progn (defun scratch (name) (concatenate (quote string) *scratch* name)) t)

;; Characters out and back, with lines and a non-ASCII character.
(progn
  (with-open-file (out (scratch "notes.txt") :direction :output :if-exists :supersede)
    (write-line "maintenance window moves to 02:00" out)
    (write-string "café" out)
    (terpri out))
  (with-open-file (in (scratch "notes.txt"))
    (and (equal (read-line in) "maintenance window moves to 02:00")
         (equal (read-line in) "café")
         (eq (read-line in nil :eof) :eof))))

;; Appending keeps what was there.
(progn
  (with-open-file (out (scratch "notes.txt") :direction :output :if-exists :append)
    (write-line "third line" out))
  (with-open-file (in (scratch "notes.txt"))
    (equal (loop for line = (read-line in nil) while line collect line)
           '("maintenance window moves to 02:00" "café" "third line"))))

;; Opening an existing file for output with :if-exists :error, or a
;; missing one for input, signals file-error.
(eq (handler-case (open (scratch "notes.txt") :direction :output :if-exists :error)
      (file-error () :signaled))
    :signaled)
(eq (handler-case (open (scratch "missing.txt")) (file-error () :signaled)) :signaled)
(null (open (scratch "missing.txt") :if-does-not-exist nil))

;; Bytes, with file-length and file-position counting elements.
(progn
  (with-open-file (out (scratch "data.bin") :direction :output
                                            :element-type '(unsigned-byte 8)
                                            :if-exists :supersede)
    (write-sequence #(1 2 3 250 251) out)
    (and (eql (file-position out) 5)
         (eql (file-length out) 5))))
(with-open-file (in (scratch "data.bin") :element-type '(unsigned-byte 8))
  (let ((buffer (make-array 3)))
    (and (eql (file-length in) 5)
         (eql (read-sequence buffer in) 3)
         (equalp buffer #(1 2 3))
         (eql (file-position in) 3)
         (file-position in 1)
         (eql (read-byte in) 2)
         (file-position in :end)
         (eq (read-byte in nil :eof) :eof)
         (null (file-position in 6)))))
(with-open-file (in (scratch "data.bin") :element-type '(signed-byte 16))
  (and (eql (file-length in) 2)
       (eql (read-byte in) (+ 1 (* 2 256)))))

;; read-sequence stops at the end of the file and says where.
(with-open-file (in (scratch "data.bin") :element-type '(unsigned-byte 8))
  (let ((buffer (make-list 8 :initial-element 0)))
    (and (eql (read-sequence buffer in :start 2) 7)
         (equal buffer '(0 0 1 2 3 250 251 0)))))

;; Characters through read-sequence and write-sequence.
(progn
  (with-open-file (out (scratch "letters.txt") :direction :output :if-exists :supersede)
    (write-sequence "abcdefgh" out :start 2 :end 6))
  (with-open-file (in (scratch "letters.txt"))
    (let ((text (make-string 6 :initial-element #\-)))
      (and (eql (read-sequence text in :start 1) 5)
           (equal text "-cdef-")))))

;; Overwriting in place from a position.
(progn
  (with-open-file (out (scratch "letters.txt") :direction :output :if-exists :overwrite)
    (file-position out 1)
    (write-char #\X out))
  (with-open-file (in (scratch "letters.txt"))
    (equal (read-line in) "cXef")))

;; listen sees what is left to read.
(with-open-file (in (scratch "letters.txt"))
  (and (listen in)
       (read-line in)
       (not (listen in))))
(with-input-from-string (in "x")
  (and (listen in) (read-char in) (not (listen in))))

;; Files listed by directory, with wild names and types.
(flet ((names (paths) (mapcar #'file-namestring paths)))
  (and (equal (names (directory (scratch "*.txt"))) '("letters.txt" "notes.txt"))
       (equal (names (directory (scratch "*.*"))) '("data.bin" "letters.txt" "notes.txt"))
       (equal (names (directory (scratch "n*.txt"))) '("notes.txt"))
       (equal (names (directory (scratch "data.bin"))) '("data.bin"))
       (null (directory (scratch "*.lisp")))))
(progn
  (with-open-file (out (scratch "nested/inner.txt") :direction :output :if-exists :supersede)
    (write-line "inner" out))
  (and (equal (mapcar #'file-namestring (directory (scratch "*/*.txt"))) '("inner.txt"))
       (equal (mapcar #'file-namestring (directory (scratch "**/*.txt")))
              '("letters.txt" "inner.txt" "notes.txt"))))

;; A file loaded and compiled from the scratch directory.
(progn
  (with-open-file (out (scratch "loaded.lisp") :direction :output :if-exists :supersede)
    (print '(defun loaded-from-scratch (x) (* x 3)) out))
  (and (load (scratch "loaded.lisp"))
       (eql (loaded-from-scratch 14) 42)
       (compile-file (scratch "loaded.lisp"))
       (probe-file (compile-file-pathname (scratch "loaded.lisp")))
       t))

;; Renaming returns the new name and the old and new truenames.
(multiple-value-bind (new old truename) (rename-file (scratch "letters.txt") "renamed.txt")
  (and (equal (file-namestring new) "renamed.txt")
       (equal (file-namestring old) "letters.txt")
       (equal (file-namestring truename) "renamed.txt")
       (null (probe-file (scratch "letters.txt")))
       (probe-file (scratch "renamed.txt"))
       t))

;; Deleting, and deleting what is not there.
(progn
  (dolist (path (directory (scratch "**/*.*")))
    (delete-file path))
  (null (directory (scratch "**/*.*"))))
(eq (handler-case (delete-file (scratch "renamed.txt")) (file-error () :signaled)) :signaled)
(and (ext:delete-directory (scratch "nested/"))
     (ext:delete-directory *scratch*)
     (null (probe-file *scratch*)))
