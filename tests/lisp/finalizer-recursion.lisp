;; What runs once an object has been reclaimed.
;;
;; `ext:finalize` holds the object through a weak pointer, so registering
;; an action is not what keeps the object alive. The collector cannot run
;; the action itself, since a collection is no place to allocate: it puts
;; the action on a queue and whatever was evaluating runs it.
;;
;; The action below allocates, so it can set off a collection of its own
;; while the queue is being run. What that collection finds waits for the
;; next pass rather than being run inside the current one, and nothing is
;; run twice or skipped.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "gc check failed: ~s" ',form)))

(defvar *cycles* 1000)
(defvar *ran* 0)
(defvar *scratch* nil)

;; Named at top level rather than written as a closure: one that captured
;; the object would be what kept it alive.
(defun note ()
  (setq *ran* (1+ *ran*))
  (setq *scratch* (list *ran* *ran* *ran*)))

(defun register (n)
  (dotimes (i n) (ext:finalize (list i i) (function note))))

(defvar *spared* nil)

;; One that is cancelled, and one that is still referred to. Neither has
;; any reason to run.
(setq *spared* (ext:finalize (list :spared) (function note)))
(ext:cancel-finalization (ext:finalize (list :cancelled) (function note)))

(register *cycles*)

(gc)

(gc)

(gc)

;; Every object that was dropped had its action run, exactly once each.
(check (= *ran* *cycles*))

;; Neither of the two that had a reason to stay ran.
(check (equal *spared* '(:spared)))

;; The action allocated on every one of those runs, so collections
;; happened while the queue was being run.
(check (equal *scratch* (list *cycles* *cycles* *cycles*)))

;; Dropping the last reference is what lets the spared one go.
(setq *spared* nil)

(gc)

(gc)

(check (= *ran* (1+ *cycles*)))

;; And the cancelled one never ran at all.
(check (= *ran* (1+ *cycles*)))
