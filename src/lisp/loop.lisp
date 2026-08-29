;; The LOOP facility. The expander parses clauses left to right into six
;; buckets — variable bindings, prologue, per-iteration body, stepping,
;; epilogue and result form — then emits one block / tagbody.

(in-package "COMMON-LISP")

(defvar *loop-into-tails* nil)

(defvar %loop-keywords
  '("NAMED" "WITH" "FOR" "AS" "REPEAT" "WHILE" "UNTIL" "ALWAYS" "NEVER" "THEREIS"
    "DO" "DOING" "COLLECT" "COLLECTING" "APPEND" "APPENDING" "NCONC" "NCONCING"
    "COUNT" "COUNTING" "SUM" "SUMMING" "MAXIMIZE" "MAXIMIZING"
    "MINIMIZE" "MINIMIZING" "INITIALLY" "FINALLY" "RETURN" "IF" "WHEN" "UNLESS"
    "ELSE" "END" "AND" "INTO" "FROM" "UPFROM" "DOWNFROM" "TO" "UPTO" "DOWNTO"
    "BELOW" "ABOVE" "BY" "IN" "ON" "ACROSS" "BEING" "OF-TYPE" "="))

(defun %kw (form name)
  (and form (symbolp form) (string= (symbol-name form) name)))

(defun %kw-in (form names)
  (dolist (name names nil) (when (%kw form name) (return t))))

(defun %loop-keyword-p (form)
  (%kw-in form %loop-keywords))

(defun %lp (binds prologue main steps epilogue result)
  (list binds prologue main steps epilogue result))

(defun %lp-empty () (%lp nil nil nil nil nil nil))

(defun %lp-merge (a b)
  (%lp (append (nth 0 a) (nth 0 b))
       (append (nth 1 a) (nth 1 b))
       (append (nth 2 a) (nth 2 b))
       (append (nth 3 a) (nth 3 b))
       (append (nth 4 a) (nth 4 b))
       (or (nth 5 a) (nth 5 b))))

(defun %st-list (state) (nth 0 state))
(defun %st-tail (state) (nth 1 state))
(defun %st-count (state) (nth 2 state))
(defun %st-extreme (state) (nth 3 state))
(defun %st-done (state) (nth 4 state))

(defun %loop-tail-for (var)
  (let ((hit (assoc var *loop-into-tails*)))
    (if hit
        (cdr hit)
        (let ((tail (gensym "TAIL")))
          (setq *loop-into-tails* (cons (cons var tail) *loop-into-tails*))
          tail))))

(defun %loop-vars (pattern)
  (cond ((null pattern) nil)
        ((symbolp pattern) (list pattern))
        ((consp pattern) (append (%loop-vars (car pattern)) (%loop-vars (cdr pattern))))
        (t nil)))

(defun %loop-setqs (pattern form)
  (cond ((null pattern) nil)
        ((symbolp pattern) (list (list 'setq pattern form)))
        ((consp pattern)
         (append (%loop-setqs (car pattern) (list 'car form))
                 (%loop-setqs (cdr pattern) (list 'cdr form))))
        (t nil)))

(defun %loop-binds (pattern)
  (mapcar (lambda (var) (list var nil)) (%loop-vars pattern)))

(defun %loop-forms-until-keyword (forms)
  (let ((collected nil))
    (tagbody
       next
       (when (or (null forms) (%loop-keyword-p (car forms))) (go done))
       (setq collected (cons (car forms) collected))
       (setq forms (cdr forms))
       (go next)
       done)
    (cons (nreverse collected) forms)))

;; Accumulation. The anonymous accumulators live in the state; INTO names a
;; caller-visible variable instead, and repeated INTO of one name shares a tail.

(defun %loop-into-target (forms state kind)
  (if (%kw (car forms) "INTO")
      (let ((var (cadr forms)))
        (list var
              (if (eq kind :list) (%loop-tail-for var) nil)
              (cddr forms)
              nil))
      (list (cond ((eq kind :list) (%st-list state))
                  ((eq kind :count) (%st-count state))
                  (t (%st-extreme state)))
            (if (eq kind :list) (%st-tail state) nil)
            forms
            t)))

(defun %loop-collect-forms (acc tail value splice)
  (let ((cell (gensym "CELL")))
    (if splice
        `((let ((,cell ,value))
            (when ,cell
              (if ,tail (rplacd ,tail ,cell) (setq ,acc ,cell))
              (setq ,tail (last ,cell)))))
        `((let ((,cell (cons ,value nil)))
            (if ,tail (rplacd ,tail ,cell) (setq ,acc ,cell))
            (setq ,tail ,cell))))))

(defun %loop-accumulate (head forms state)
  (let* ((value (car forms))
         (rest (cdr forms))
         (list-kind (%kw-in head '("COLLECT" "COLLECTING" "APPEND" "APPENDING"
                                   "NCONC" "NCONCING")))
         (count-kind (%kw-in head '("COUNT" "COUNTING" "SUM" "SUMMING")))
         (kind (cond (list-kind :list) (count-kind :count) (t :extreme)))
         (target (%loop-into-target rest state kind))
         (acc (nth 0 target))
         (tail (nth 1 target))
         (remaining (nth 2 target))
         (anonymous (nth 3 target))
         (binds (if anonymous nil (list (list acc nil))))
         (prologue (if (or anonymous (not (eq kind :count))) nil (list `(setq ,acc 0))))
         (main
          (cond (list-kind
                 (%loop-collect-forms
                  acc tail
                  (if (%kw-in head '("APPEND" "APPENDING")) `(copy-list ,value) value)
                  (not (%kw-in head '("COLLECT" "COLLECTING")))))
                ((%kw-in head '("COUNT" "COUNTING"))
                 (list `(when ,value (setq ,acc (1+ ,acc)))))
                ((%kw-in head '("SUM" "SUMMING"))
                 (list `(setq ,acc (+ ,acc ,value))))
                (t
                 (let ((probe (gensym "PROBE"))
                       (better (if (%kw-in head '("MAXIMIZE" "MAXIMIZING")) '> '<)))
                   (list `(let ((,probe ,value))
                            (when (or (null ,acc) (,better ,probe ,acc))
                              (setq ,acc ,probe)))))))))
    (cons (%lp (append binds (if (and (not anonymous) (eq kind :list))
                                 (list (list tail nil))
                                 nil))
               prologue main nil nil
               (if anonymous acc nil))
          remaining)))

;; FOR clauses. Each contributes a prologue that primes the variable, a body
;; test that leaves the loop when the source runs out, and a step.

(defun %loop-for-numeric (pattern forms state)
  (let ((start nil) (limit nil) (step nil) (descending nil) (test nil))
    (tagbody
       next
       (cond ((%kw-in (car forms) '("FROM" "UPFROM"))
              (setq start (cadr forms)) (setq forms (cddr forms)))
             ((%kw (car forms) "DOWNFROM")
              (setq start (cadr forms)) (setq descending t) (setq forms (cddr forms)))
             ((%kw-in (car forms) '("TO" "UPTO"))
              (setq limit (cadr forms)) (setq test '>) (setq forms (cddr forms)))
             ((%kw (car forms) "BELOW")
              (setq limit (cadr forms)) (setq test '>=) (setq forms (cddr forms)))
             ((%kw (car forms) "DOWNTO")
              (setq limit (cadr forms)) (setq test '<) (setq descending t)
              (setq forms (cddr forms)))
             ((%kw (car forms) "ABOVE")
              (setq limit (cadr forms)) (setq test '<=) (setq descending t)
              (setq forms (cddr forms)))
             ((%kw (car forms) "BY")
              (setq step (cadr forms)) (setq forms (cddr forms)))
             (t (go done)))
       (go next)
       done)
    (when (and descending (member test '(> >=)))
      (setq test (if (eq test '>) '< '<=)))
    (let ((limit-var (gensym "LIMIT"))
          (step-var (gensym "STEP"))
          (stepping (list (if descending '- '+))))
      ;; The bindings are sequential, so a variable takes its first value
      ;; where the form giving it is still outside its own scope. That is
      ;; what lets `for i from (if (< i 0) 2 1)` read the `i` it shadows
      ;; while `for j from i` reads the loop variable before it.
      (cons (%lp (if (symbolp pattern)
                     (list (list pattern (or start 0))
                           (list limit-var limit)
                           (list step-var (or step 1)))
                     (append (%loop-binds pattern)
                             (list (list limit-var limit) (list step-var (or step 1)))))
                 (if (symbolp pattern) nil (%loop-setqs pattern (or start 0)))
                 (if test (list `(if (,test ,(car (%loop-vars pattern)) ,limit-var)
                                     (go ,(%st-done state))))
                     nil)
                 (%loop-setqs pattern
                              (append stepping
                                      (list (car (%loop-vars pattern)) step-var)))
                 nil nil)
            forms))))

(defun %loop-for (forms state)
  (let* ((pattern (car forms))
         (rest (cdr forms)))
    (when (%kw (car rest) "OF-TYPE") (setq rest (cddr rest)))
    (when (and (not (%loop-keyword-p (car rest))) (symbolp (car rest)) (car rest))
      (setq rest (cdr rest)))
    (cond
      ((%kw-in (car rest) '("IN" "ON"))
       (let* ((on (%kw (car rest) "ON"))
              (source (cadr rest))
              (after (cddr rest))
              (stepper (if (%kw (car after) "BY") (cadr after) nil))
              (remaining (if stepper (cddr after) after))
              (walk (gensym "WALK")))
         (cons (%lp (append (%loop-binds pattern) (list (list walk nil)))
                    (list `(setq ,walk ,source))
                    (append (list `(if ,(if on `(atom ,walk) `(endp ,walk))
                                       (go ,(%st-done state))))
                            (%loop-setqs pattern (if on walk `(car ,walk))))
                    (list `(setq ,walk ,(if stepper `(funcall ,stepper ,walk) `(cdr ,walk))))
                    nil nil)
               remaining)))
      ((%kw (car rest) "ACROSS")
       (let ((source (cadr rest))
             (vector (gensym "VECTOR"))
             (index (gensym "INDEX")))
         (cons (%lp (append (%loop-binds pattern) (list (list vector nil) (list index nil)))
                    (list `(setq ,vector ,source) `(setq ,index 0))
                    (append (list `(if (>= ,index (length ,vector)) (go ,(%st-done state))))
                            (%loop-setqs pattern `(aref ,vector ,index)))
                    (list `(setq ,index (1+ ,index)))
                    nil nil)
               (cddr rest))))
      ((%kw (car rest) "=")
       (let* ((initial (cadr rest))
              (after (cddr rest))
              (has-then (%kw (car after) "THEN"))
              (then (if has-then (cadr after) nil))
              (remaining (if has-then (cddr after) after)))
         ;; Without THEN the form is evaluated at the top of every
         ;; iteration, after the FOR clauses to its left have stepped, so
         ;; it can read what they just set.
         (cons (if has-then
                   (%lp (%loop-binds pattern)
                        (%loop-setqs pattern initial)
                        nil
                        (%loop-setqs pattern then)
                        nil nil)
                   (%lp (%loop-binds pattern)
                        nil
                        (%loop-setqs pattern initial)
                        nil nil nil))
               remaining)))
      ((%kw (car rest) "BEING")
       (%loop-for-hash pattern rest state))
      (t (%loop-for-numeric pattern rest state)))))

(defun %loop-for-hash (pattern forms state)
  (let* ((rest (cdr forms)))
    (when (%kw-in (car rest) '("THE" "EACH")) (setq rest (cdr rest)))
    (let* ((what (car rest))
           (table (caddr rest))
           (after (cdddr rest))
           (using (if (%kw (car after) "USING") (cadr after) nil))
           (remaining (if using (cddr after) after))
           (keys (%kw-in what '("HASH-KEY" "HASH-KEYS")))
           (entries (gensym "ENTRIES"))
           (entry (gensym "ENTRY"))
           (extra (if using (cadr using) nil)))
      (cons (%lp (append (%loop-binds pattern)
                         (if extra (%loop-binds extra) nil)
                         (list (list entries nil)))
                 (list `(setq ,entries (%hash-table-entries ,table)))
                 (append (list `(if (endp ,entries) (go ,(%st-done state)))
                               `(let ((,entry (car ,entries)))
                                  ,@(%loop-setqs pattern (if keys `(car ,entry) `(cdr ,entry)))
                                  ,@(if extra
                                        (%loop-setqs extra (if keys `(cdr ,entry) `(car ,entry)))
                                        nil)))
                         nil)
                 (list `(setq ,entries (cdr ,entries)))
                 nil nil)
            remaining))))

(defun %loop-with (forms state)
  (let ((binds nil)
        (prologue nil))
    (tagbody
       next
       (let* ((pattern (car forms))
              (rest (cdr forms)))
         (when (and (not (%loop-keyword-p (car rest))) (symbolp (car rest)) (car rest))
           (setq rest (cdr rest)))
         (setq binds (append binds (%loop-binds pattern)))
         (when (%kw (car rest) "=")
           (setq prologue (append prologue (%loop-setqs pattern (cadr rest))))
           (setq rest (cddr rest)))
         (setq forms rest))
       (when (%kw (car forms) "AND")
         (setq forms (cdr forms))
         (go next)))
    (cons (%lp binds prologue nil nil nil nil) forms)))

(defun %loop-conditional (head forms state)
  (let* ((negated (%kw head "UNLESS"))
         (test (car forms))
         (parsed (%loop-clause (cdr forms) state))
         (part (car parsed))
         (rest (cdr parsed))
         (then (nth 2 part))
         (else nil))
    (tagbody
       next
       (when (%kw (car rest) "AND")
         (let* ((more (%loop-clause (cdr rest) state)))
           (setq then (append then (nth 2 (car more))))
           (setq part (%lp-merge part (%lp (nth 0 (car more)) (nth 1 (car more))
                                           nil (nth 3 (car more)) (nth 4 (car more))
                                           (nth 5 (car more)))))
           (setq rest (cdr more))
           (go next))))
    (when (%kw (car rest) "ELSE")
      (let ((parsed-else (%loop-clause (cdr rest) state)))
        (setq else (nth 2 (car parsed-else)))
        (setq part (%lp-merge part (%lp (nth 0 (car parsed-else)) (nth 1 (car parsed-else))
                                        nil (nth 3 (car parsed-else))
                                        (nth 4 (car parsed-else))
                                        (nth 5 (car parsed-else)))))
        (setq rest (cdr parsed-else))))
    (when (%kw (car rest) "END") (setq rest (cdr rest)))
    (cons (%lp (nth 0 part) (nth 1 part)
               (list (if negated
                         `(if ,test (progn ,@else) (progn ,@then))
                         `(if ,test (progn ,@then) (progn ,@else))))
               (nth 3 part) (nth 4 part) (nth 5 part))
          rest)))

(defun %loop-clause (forms state)
  (let ((head (car forms))
        (rest (cdr forms)))
    (cond
      ((%kw-in head '("FOR" "AS")) (%loop-for rest state))
      ((%kw head "WITH") (%loop-with rest state))
      ((%kw head "REPEAT")
       (let ((counter (gensym "COUNTER")))
         (cons (%lp (list (list counter nil))
                    (list `(setq ,counter ,(car rest)))
                    (list `(if (<= ,counter 0) (go ,(%st-done state))))
                    (list `(setq ,counter (1- ,counter)))
                    nil nil)
               (cdr rest))))
      ((%kw head "WHILE")
       (cons (%lp nil nil (list `(if (not ,(car rest)) (go ,(%st-done state)))) nil nil nil)
             (cdr rest)))
      ((%kw head "UNTIL")
       (cons (%lp nil nil (list `(if ,(car rest) (go ,(%st-done state)))) nil nil nil)
             (cdr rest)))
      ((%kw head "ALWAYS")
       (cons (%lp nil nil (list `(if (not ,(car rest)) (return nil))) nil nil t)
             (cdr rest)))
      ((%kw head "NEVER")
       (cons (%lp nil nil (list `(if ,(car rest) (return nil))) nil nil t)
             (cdr rest)))
      ((%kw head "THEREIS")
       (let ((probe (gensym "PROBE")))
         (cons (%lp nil nil
                    (list `(let ((,probe ,(car rest))) (if ,probe (return ,probe))))
                    nil nil nil)
               (cdr rest))))
      ((%kw head "RETURN")
       (cons (%lp nil nil (list `(return ,(car rest))) nil nil nil) (cdr rest)))
      ((%kw-in head '("DO" "DOING"))
       (let ((split (%loop-forms-until-keyword rest)))
         (cons (%lp nil nil (car split) nil nil nil) (cdr split))))
      ((%kw head "INITIALLY")
       (let ((split (%loop-forms-until-keyword rest)))
         (cons (%lp nil (car split) nil nil nil nil) (cdr split))))
      ((%kw head "FINALLY")
       (let ((split (%loop-forms-until-keyword rest)))
         (cons (%lp nil nil nil nil (car split) nil) (cdr split))))
      ((%kw-in head '("IF" "WHEN" "UNLESS")) (%loop-conditional head rest state))
      ((%loop-keyword-p head) (%loop-accumulate head rest state))
      (t (error "Unknown LOOP clause: ~s" head)))))

(defun %loop-parse (forms state)
  (let ((part (%lp-empty)))
    (tagbody
       next
       (when (null forms) (go done))
       (let ((parsed (%loop-clause forms state)))
         (setq part (%lp-merge part (car parsed)))
         (setq forms (cdr parsed)))
       (go next)
       done)
    part))

(defun %loop-dedupe-binds (binds)
  (let ((seen nil)
        (result nil))
    (dolist (bind binds (nreverse result))
      (unless (member (car bind) seen)
        (setq seen (cons (car bind) seen))
        (setq result (cons bind result))))))

;; `loop-finish` leaves the loop through its epilogue, so it comes to a
;; jump to the tag the termination tests use. The substitution happens
;; before anything is expanded, which is what keeps a nested `loop` from
;; taking the outer loop's tag: it rewrites its own when it expands.
(defun %loop-substitute-finish (form tag)
  (if (atom form)
      form
      (if (eq (car form) 'quote)
          form
          (if (eq (car form) 'loop)
              form
              (if (and (eq (car form) 'loop-finish) (null (cdr form)))
                  (list 'go tag)
                  (cons (%loop-substitute-finish (car form) tag)
                        (%loop-substitute-finish (cdr form) tag)))))))

(defmacro loop-finish ()
  (error "LOOP-FINISH is only meaningful inside LOOP."))

(defun %loop-expand (forms)
  (let ((*loop-into-tails* nil)
        (name nil))
    (when (%kw (car forms) "NAMED")
      (setq name (cadr forms))
      (setq forms (cddr forms)))
    (let* ((state (list (gensym "ITEMS") (gensym "TAIL") (gensym "COUNT")
                        (gensym "EXTREME") (gensym "DONE")))
           (part (%loop-parse forms state))
           (top (gensym "TOP"))
           (tails (mapcar (lambda (entry) (list (cdr entry) nil)) *loop-into-tails*))
           (result (nth 5 part)))
      (%loop-substitute-finish
       `(block ,name
          (let* ((,(%st-list state) nil) (,(%st-tail state) nil)
                 (,(%st-count state) 0) (,(%st-extreme state) nil)
                 ,@(%loop-dedupe-binds (append (nth 0 part) tails)))
            (tagbody
               ,@(nth 1 part)
               ,top
               ,@(nth 2 part)
               ,@(nth 3 part)
               (go ,top)
               ,(%st-done state))
            ,@(nth 4 part)
            ,(if (eq result t) t result)))
       (%st-done state)))))

(defmacro loop (&rest forms)
  (if (or (null forms) (consp (car forms)))
      (let ((top (gensym "TOP")))
        `(block nil (tagbody ,top (progn ,@forms) (go ,top))))
      (%loop-expand forms)))

(export '(loop loop-finish))

(in-package "COMMON-LISP-USER")
