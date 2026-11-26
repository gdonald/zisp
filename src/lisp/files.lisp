;;;; Files and directories.

(in-package "COMMON-LISP")

(defmacro %signaling-file-error ((pathname) &body body)
  `(handler-case (progn ,@body)
     (file-error () (error 'file-error :pathname ,pathname))))

(defun delete-file (filespec)
  (let ((name (namestring (truename filespec))))
    (%signaling-file-error (filespec) (%delete-file name))))

(defun rename-file (file new-name)
  (let* ((old (truename file))
         (new (merge-pathnames new-name file)))
    (%signaling-file-error (file) (%rename-file (namestring old) (namestring new)))
    (values new old (truename new))))

(defun ensure-directories-exist (pathspec &key verbose)
  (declare (ignore verbose))
  (let ((dir (directory-namestring pathspec)))
    (values pathspec
            (if (string= dir "")
                nil
                (%signaling-file-error (pathspec) (%create-directories dir))))))

;;; `*` in a name stands for any run of characters.
(defun %glob-match-p (pattern text)
  (labels ((walk (p s)
             (cond ((= p (length pattern)) (= s (length text)))
                   ((char= (char pattern p) #\*)
                    (loop for rest from s to (length text)
                            thereis (walk (1+ p) rest)))
                   (t (and (< s (length text))
                           (char= (char pattern p) (char text s))
                           (walk (1+ p) (1+ s)))))))
    (walk 0 0)))

(defun %component-match-p (pattern component)
  (cond ((member pattern '(:wild nil)) (or (eq pattern :wild) (null component)))
        ((and (stringp pattern) (stringp component)) (%glob-match-p pattern component))
        (t (equal pattern component))))

(defun %wild-component-p (component)
  (or (member component '(:wild :wild-inferiors))
      (and (stringp component) (find #\* component))))

(defun %subdirectories (base)
  (loop for entry in (%directory-entries base)
        when (char= (char entry (1- (length entry))) #\/)
          collect (concatenate 'string base entry)))

(defun %all-subdirectories (base)
  (cons base (loop for sub in (%subdirectories base)
                   append (%all-subdirectories sub))))

(defun %expand-directory (segments)
  (let ((bases (list (if (eq (first segments) :absolute) "/" ""))))
    (dolist (segment (rest segments) bases)
      (setf bases
            (loop for base in bases
                  append (cond ((eq segment :wild-inferiors) (%all-subdirectories base))
                               ((%wild-component-p segment)
                                (remove-if-not
                                 (lambda (sub)
                                   (%glob-match-p (if (stringp segment) segment "*")
                                                  (string-right-trim "/" (subseq sub (length base)))))
                                 (%subdirectories base)))
                               ((member segment '(:up :back)) (list (concatenate 'string base "../")))
                               (t (list (concatenate 'string base segment "/")))))))))

(defun directory (pathspec &key)
  (let* ((pattern (pathname pathspec))
         (name (pathname-name pattern))
         (type (pathname-type pattern))
         (found '()))
    (dolist (base (%expand-directory (or (pathname-directory pattern) '(:relative))))
      (cond ((and (null name) (null type))
             (let ((dir (probe-file (if (string= base "") "./" base))))
               (when dir (push dir found))))
            ((or (%wild-component-p name) (%wild-component-p type))
             (dolist (entry (ignore-errors (%directory-entries base)))
               (unless (char= (char entry (1- (length entry))) #\/)
                 (let ((file (pathname entry)))
                   (when (and (%component-match-p name (pathname-name file))
                              (%component-match-p type (pathname-type file)))
                     (push (truename (concatenate 'string base entry)) found))))))
            (t (let ((file (probe-file (concatenate 'string base (file-namestring pattern)))))
                 (when file (push file found))))))
    (sort (remove-duplicates found :test #'equal :key #'namestring) #'string< :key #'namestring)))

(export '(delete-file rename-file ensure-directories-exist directory))

(in-package "COMMON-LISP-USER")
