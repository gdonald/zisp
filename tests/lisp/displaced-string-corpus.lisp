;; Every form here must evaluate to T.

(let* ((base (make-array 5 :element-type 'character :initial-contents "abcde"))
       (window (make-array 3 :element-type 'character
                           :displaced-to base :displaced-index-offset 1)))
  (string= window "bcd"))
(let* ((base (make-array 5 :element-type 'character :initial-contents "abcde"))
       (window (make-array 3 :element-type 'character
                           :displaced-to base :displaced-index-offset 1)))
  (stringp window))
(let* ((base (make-array 5 :element-type 'character :initial-contents "abcde"))
       (window (make-array 3 :element-type 'character
                           :displaced-to base :displaced-index-offset 1)))
  (setf (char window 0) #\Z)
  (string= base "aZcde"))
(let* ((base (make-array 5 :element-type 'character :initial-contents "abcde"))
       (window (make-array 3 :element-type 'character
                           :displaced-to base :displaced-index-offset 1)))
  (setf (char base 2) #\Y)
  (string= window "bYd"))
(let* ((base (make-array 5 :element-type 'character :initial-contents "abcde"))
       (window (make-array 2 :element-type 'character
                           :displaced-to base :displaced-index-offset 3)))
  (equal (multiple-value-list (array-displacement window)) (list base 3)))
(let ((plain (make-string 3)))
  (equal (multiple-value-list (array-displacement plain)) (list nil 0)))
(let ((base (make-array 4 :element-type 'character :initial-contents "abcd")))
  (eq :too-big
      (handler-case (make-array 9 :element-type 'character :displaced-to base)
        (error () :too-big))))
(let* ((base (make-array 4 :element-type 'character :initial-contents "abcd"))
       (window (make-array 2 :element-type 'character
                           :displaced-to base :displaced-index-offset 1)))
  (eql (length window) 2))
