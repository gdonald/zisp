;; Sequence operations that work through length / elt / (setf elt), so one
;; definition covers lists, vectors and strings.

(in-package "COMMON-LISP")

(defun %seq-end (sequence end)
  (if end end (length sequence)))

(defun replace (target source &key (start1 0) end1 (start2 0) end2)
  (let* ((count (min (- (%seq-end target end1) start1)
                     (- (%seq-end source end2) start2))))
    (if (and (eq target source) (> start1 start2))
        (do ((index (1- count) (1- index)))
            ((< index 0) target)
          (setf (elt target (+ start1 index)) (elt source (+ start2 index))))
        (do ((index 0 (1+ index)))
            ((>= index count) target)
          (setf (elt target (+ start1 index)) (elt source (+ start2 index)))))))

(defun fill (sequence item &key (start 0) end)
  (do ((index start (1+ index))
       (finish (%seq-end sequence end)))
      ((>= index finish) sequence)
    (setf (elt sequence index) item)))

(defun make-sequence (type size &key initial-element)
  (cond ((member type '(list cons)) (make-list size :initial-element initial-element))
        ((member type '(string simple-string base-string simple-base-string))
         (make-string size :initial-element (or initial-element #\Space)))
        (t (make-array size :initial-element initial-element))))

(defun substitute-if (new predicate sequence &key key (start 0) end count from-end)
  (let ((result (copy-seq sequence))
        (remaining (or count (length sequence))))
    (if from-end
        (do ((index (1- (%seq-end sequence end)) (1- index)))
            ((or (< index start) (<= remaining 0)) result)
          (when (funcall predicate (if key (funcall key (elt sequence index)) (elt sequence index)))
            (setf (elt result index) new)
            (setq remaining (1- remaining))))
        (do ((index start (1+ index))
             (finish (%seq-end sequence end)))
            ((or (>= index finish) (<= remaining 0)) result)
          (when (funcall predicate (if key (funcall key (elt sequence index)) (elt sequence index)))
            (setf (elt result index) new)
            (setq remaining (1- remaining)))))))

(defun substitute-if-not (new predicate sequence &key key (start 0) end count from-end)
  (substitute-if new (lambda (element) (not (funcall predicate element))) sequence
                 :key key :start start :end end :count count :from-end from-end))

(defun nsubstitute-if (new predicate sequence &key key (start 0) end count from-end)
  (replace sequence (substitute-if new predicate sequence
                                   :key key :start start :end end
                                   :count count :from-end from-end)))

(defun nsubstitute-if-not (new predicate sequence &key key (start 0) end count from-end)
  (nsubstitute-if new (lambda (element) (not (funcall predicate element))) sequence
                  :key key :start start :end end :count count :from-end from-end))

(defsetf subseq (sequence start &optional end) (new)
  `(progn (replace ,sequence ,new :start1 ,start :end1 ,end) ,new))

(defun constantly (value)
  (lambda (&rest arguments) (declare (ignore arguments)) value))

(defun complement (predicate)
  (lambda (&rest arguments) (not (apply predicate arguments))))

(defsetf readtable-case %set-readtable-case)

(export '(replace fill make-sequence
          substitute-if substitute-if-not nsubstitute-if nsubstitute-if-not
          constantly complement))

(in-package "COMMON-LISP-USER")
