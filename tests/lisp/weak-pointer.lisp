;; A reference that does not keep what it refers to alive.
;;
;; `ext:make-weak-pointer` hands back a pointer the collector does not
;; follow. While something else still refers to the object the pointer
;; reads back as it was, and once nothing does the collection that
;; reclaims the object leaves the pointer broken.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defvar *held* nil)
(defvar *to-held* nil)
(defvar *to-dropped* nil)
(defvar *seen* nil)

(setq *held* (list :held))
(setq *to-held* (ext:make-weak-pointer *held*))
(setq *to-dropped* (ext:make-weak-pointer (list :dropped)))

(check (ext:weak-pointerp *to-held*))
(check (not (ext:weak-pointerp *held*)))

;; Before anything is collected both read back what they were given.
(check (equal (multiple-value-list (ext:weak-pointer-value *to-held*))
              '((:held) t)))
(check (equal (multiple-value-list (ext:weak-pointer-value *to-dropped*))
              '((:dropped) t)))

;; Two collections: the first copies the young objects out of the
;; nursery, and the second is where a tenured object nothing refers to is
;; reclaimed.
(gc)

(gc)

;; The one still held reads back as itself, at whatever address the copy
;; put it.
(check (equal (multiple-value-list (ext:weak-pointer-value *to-held*)) '((:held) t)))
(check (eq (ext:weak-pointer-value *to-held*) *held*))

;; The one nothing else refers to is broken, and says so with a second
;; value rather than by handing back nil.
(check (equal (multiple-value-list (ext:weak-pointer-value *to-dropped*)) '(nil nil)))

;; What is held comes through ten collections in a row.
(dotimes (i 10) (gc) (setq *seen* (ext:weak-pointer-value *to-held*)))

(gc)

(check (eq *seen* *held*))
(check (equal (multiple-value-list (ext:weak-pointer-value *to-held*)) '((:held) t)))

;; Dropping the last reference is what breaks it.
(setq *held* nil)
(setq *seen* nil)

(gc)

(gc)

(check (equal (multiple-value-list (ext:weak-pointer-value *to-held*)) '(nil nil)))
