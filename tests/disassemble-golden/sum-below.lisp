(defun sum-below (limit)
  (declare (type (integer 0 1000000) limit)
           (optimize (safety 0)))
  (let ((sum 0)
        (i 0))
    (declare (type fixnum sum i))
    (tagbody
     next
       (when (>= i limit)
         (return-from sum-below sum))
       (setq sum (+ sum i))
       (setq i (1+ i))
       (go next))))
