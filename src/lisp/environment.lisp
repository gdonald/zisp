;; The standard functions about the running image and the world outside
;; it: time, the machine, the site, symbols by name, and asking the user.

(in-package "COMMON-LISP")

;;; --- universal time ---

;; Universal time counts seconds from 1900-01-01 00:00 in UTC, seventy
;; years before the Unix epoch. No time zone is known here, so local time
;; is taken as UTC with no daylight saving.
(defconstant %unix-epoch-universal-time 2208988800)

(defun get-universal-time ()
  (+ (%unix-time) %unix-epoch-universal-time))

;; Days from 1970-01-01 to a civil date, and back, as Howard Hinnant's
;; days_from_civil and civil_from_days give them.
(defun %days-from-civil (year month day)
  (let* ((y (if (<= month 2) (- year 1) year))
         (era (floor y 400))
         (yoe (- y (* era 400)))
         (doy (+ (floor (+ (* 153 (+ month (if (> month 2) -3 9))) 2) 5) (- day 1)))
         (doe (+ (* yoe 365) (floor yoe 4) (- (floor yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(defun %civil-from-days (days)
  (let* ((z (+ days 719468))
         (era (floor z 146097))
         (doe (- z (* era 146097)))
         (yoe (floor (- doe (floor doe 1460) (- (floor doe 36524)) (floor doe 146096)) 365))
         (y (+ yoe (* era 400)))
         (doy (- doe (- (+ (* 365 yoe) (floor yoe 4)) (floor yoe 100))))
         (mp (floor (+ (* 5 doy) 2) 153))
         (d (+ (- doy (floor (+ (* 153 mp) 2) 5)) 1))
         (m (if (< mp 10) (+ mp 3) (- mp 9))))
    (values (if (<= m 2) (+ y 1) y) m d)))

(defun %check-time-zone (time-zone)
  (unless (and (rationalp time-zone) (<= -24 time-zone 24) (integerp (* time-zone 3600)))
    (error 'type-error :datum time-zone :expected-type '(rational -24 24))))

(defun decode-universal-time (universal-time &optional time-zone)
  (unless (and (integerp universal-time) (>= universal-time 0))
    (error 'type-error :datum universal-time :expected-type 'unsigned-byte))
  (when time-zone (%check-time-zone time-zone))
  (let ((zone (or time-zone 0)))
    (multiple-value-bind (days seconds)
        (floor (- universal-time (* zone 3600)) 86400)
      (multiple-value-bind (year month date)
          (%civil-from-days (- days 25567))
        (multiple-value-bind (hour rest) (floor seconds 3600)
          (multiple-value-bind (minute second) (floor rest 60)
            (values second minute hour date month year
                    ;; 1900-01-01 was a Monday, which is day 0.
                    (mod days 7)
                    nil
                    zone)))))))

(defun %full-year (year)
  "A year below 100 is the one within fifty years of now that ends in it."
  (if (>= year 100)
      year
      (let* ((now (nth-value 5 (decode-universal-time (get-universal-time))))
             (century (* 100 (floor now 100)))
             (candidate (+ century year)))
        (cond ((> (- candidate now) 50) (- candidate 100))
              ((> (- now candidate) 50) (+ candidate 100))
              (t candidate)))))

(defun encode-universal-time (second minute hour date month year &optional time-zone)
  (when time-zone (%check-time-zone time-zone))
  (let ((days (+ (%days-from-civil (%full-year year) month date) 25567)))
    (+ (* days 86400) (* hour 3600) (* minute 60) second
       (* (or time-zone 0) 3600))))

(defun get-decoded-time ()
  (decode-universal-time (get-universal-time)))

;;; --- the machine and the site ---

(defun lisp-implementation-type () "zisp")
(defun machine-type () (%machine-type))
(defun machine-version () nil)
(defun machine-instance () nil)
(defun software-type () (%software-type))
(defun software-version () nil)
(defun short-site-name () nil)
(defun long-site-name () nil)

;;; --- symbols by name ---

(defun apropos-list (string &optional package)
  "The symbols whose names hold STRING, ignoring case: those accessible
in PACKAGE when it is given, and those in any package otherwise."
  (let ((text (string string))
        (found nil))
    (flet ((consider (symbol)
             (when (search text (symbol-name symbol) :test #'char-equal)
               (pushnew symbol found))))
      (if package
          (do-symbols (symbol package) (consider symbol))
          (do-all-symbols (symbol) (consider symbol))))
    found))

(defun apropos (string &optional package)
  (dolist (symbol (apropos-list string package))
    (fresh-line)
    (prin1 symbol)
    (when (boundp symbol) (write-string " (bound)"))
    (when (fboundp symbol) (write-string " (fbound)")))
  (terpri)
  (values))

;;; --- characters and integers from text ---

(defun character (character)
  "The character a character designator names: itself, or the one
character of a string or symbol name of length one."
  (cond ((characterp character) character)
        ((and (stringp character) (= (length character) 1)) (char character 0))
        ((and (symbolp character) (= (length (symbol-name character)) 1))
         (char (symbol-name character) 0))
        (t (error 'type-error :datum character :expected-type 'character))))

(defun %whitespace-char-p (char)
  (member char '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed)))

(defun parse-integer (string &key (start 0) end (radix 10) junk-allowed)
  "The integer STRING spells in RADIX between START and END, with blanks
around it, and the index where reading stopped."
  (let* ((end (or end (length string)))
         (index start)
         (sign 1)
         (value 0)
         (digits 0))
    (loop while (and (< index end) (%whitespace-char-p (char string index)))
          do (incf index))
    (when (and (< index end) (member (char string index) '(#\+ #\-)))
      (when (char= (char string index) #\-) (setq sign -1))
      (incf index))
    (loop while (< index end)
          do (let ((weight (digit-char-p (char string index) radix)))
               (unless weight (return))
               (setq value (+ (* value radix) weight))
               (incf digits)
               (incf index)))
    (cond (junk-allowed
           (values (and (> digits 0) (* sign value)) index))
          (t
           (loop while (and (< index end) (%whitespace-char-p (char string index)))
                 do (incf index))
           (when (or (= digits 0) (< index end))
             (error 'parse-error))
           (values (* sign value) index)))))

;;; --- talking to the user ---

(defun %ask (control arguments)
  (when control
    (fresh-line *query-io*)
    (apply #'format *query-io* control arguments)
    (write-char #\Space *query-io*)
    (force-output *query-io*))
  (string-trim " " (or (read-line *query-io* nil "") "")))

(defun y-or-n-p (&optional control &rest arguments)
  (loop
    (let ((answer (%ask control arguments)))
      (cond ((string-equal answer "y") (return t))
            ((string-equal answer "n") (return nil))
            ((string= answer "") (return nil))
            (t (format *query-io* "~&Please answer y or n. "))))))

(defun yes-or-no-p (&optional control &rest arguments)
  (loop
    (let ((answer (%ask control arguments)))
      (cond ((string-equal answer "yes") (return t))
            ((string-equal answer "no") (return nil))
            ((string= answer "") (return nil))
            (t (format *query-io* "~&Please answer yes or no. "))))))

;;; --- looking at objects ---

(defun inspect (object)
  (describe object)
  (values))

;; There is no transcript to keep, so dribble only says so.
(defun dribble (&optional pathname)
  (declare (ignore pathname))
  nil)

(defun function-lambda-expression (function)
  "NIL for the lambda expression and the name, which are not kept, and T
for whether FUNCTION may be a closure."
  (unless (functionp function)
    (error 'type-error :datum function :expected-type 'function))
  (values nil t nil))

(defun copy-structure (structure)
  (unless (%structure-p structure)
    (error 'type-error :datum structure :expected-type 'structure-object))
  (%copy-structure structure))

;;; --- modules ---

(defun provide (module-name)
  (pushnew (string module-name) *modules* :test #'string=)
  t)

(defun require (module-name &optional pathname-list)
  (let ((name (string module-name)))
    (unless (member name *modules* :test #'string=)
      (unless pathname-list
        (error "There is no way to load the module ~A." name))
      (dolist (pathname (if (listp pathname-list) pathname-list (list pathname-list)))
        (load pathname))))
  nil)

(in-package "COMMON-LISP-USER")
