;; A macro expansion is held by the cache the evaluator keeps and by
;; nothing else, so a collection while the expansion is still running has
;; to leave it where it is. The loop below allocates enough to collect
;; several times over from inside the expansion.
;;
;; Every check must hold, and the count at the end says how many ran.

(defvar *checks* 0)

(defmacro check (form)
  `(if ,form
       (setq *checks* (1+ *checks*))
       (error "macro cache check failed: ~s" ',form)))

(defmacro counting-conses (n)
  `(let ((made 0))
     (dotimes (i ,n)
       (cons nil nil)
       (setq made (1+ made)))
     made))

(defun churn () (counting-conses 200000))

(defvar *collections-before* (getf (room) :collections))
(defvar *made* (churn))
(defvar *collections* (- (getf (room) :collections) *collections-before*))

(check (= 200000 *made*))
(check (> *collections* 0))

;; The same call form again, which is the one the cache is keyed on: its
;; expansion has to have come through those collections intact.
(check (= 200000 (churn)))

;; A macro redefined between calls is expanded again rather than served
;; from what the cache held.
(defmacro answer () 41)
(defun ask () (answer))

(check (= 41 (ask)))

(defmacro answer () 42)

(check (= 42 (ask)))
