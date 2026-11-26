;;;; Reading and writing whole sequences.

(in-package "COMMON-LISP")

(defun %character-stream-p (stream)
  (subtypep (stream-element-type stream) 'character))

(defun read-sequence (sequence stream &key (start 0) end)
  (let ((end (or end (length sequence)))
        (characters (%character-stream-p stream)))
    (do ((index start (1+ index)))
        ((>= index end) index)
      (let ((item (if characters (read-char stream nil :eof) (read-byte stream nil :eof))))
        (when (eq item :eof) (return index))
        (setf (elt sequence index) item)))))

(defun write-sequence (sequence stream &key (start 0) end)
  (let ((items (subseq sequence start end)))
    (if (%character-stream-p stream)
        (map nil (lambda (c) (write-char c stream)) items)
        (map nil (lambda (b) (write-byte b stream)) items))
    sequence))

(export '(read-sequence write-sequence))

(in-package "COMMON-LISP-USER")
