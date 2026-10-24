;; The LOOP facility (CLHS 6.1).
;;
;; The expander reads the clauses left to right. Variable clauses add
;; bindings, the forms that set their variables before the first pass,
;; and the forms that step them before each later one. Main clauses add
;; forms to the body. The expansion is one block holding the bindings,
;; nested in clause order, around a tagbody:
;;
;;   initially forms, first steps, NEXT body, steps, (go NEXT),
;;   END finally forms, (return-from name result)
;;
;; A variable clause tests for the end before it sets its variable, so a
;; variable keeps the last value it had when the loop runs out.

(in-package "COMMON-LISP")

(defvar *%loop-tokens* nil)
(defvar *%loop-name* nil)
(defvar *%loop-end* nil)
;; Binding groups, innermost first: each is (parallel-p bindings).
(defvar *%loop-groups* nil)
(defvar *%loop-variables* nil)
(defvar *%loop-prologue* nil)
(defvar *%loop-first* nil)
(defvar *%loop-steps* nil)
(defvar *%loop-body* nil)
(defvar *%loop-epilogue* nil)
;; Accumulation targets: (variable category tail flag), the anonymous one
;; under the name nil.
(defvar *%loop-accumulators* nil)
(defvar *%loop-accumulator-bindings* nil)
(defvar *%loop-anonymous* nil)
(defvar *%loop-boolean-result* nil)

(defun %loop-keyword-p (token &rest names)
  (and (symbolp token) token
       (member (symbol-name token) names :test #'string=)
       t))

(defun %loop-error (control &rest arguments)
  (error '%simple-program-error :format-control control :format-arguments arguments))

(defun %loop-peek () (car *%loop-tokens*))

(defun %loop-pop ()
  (if (null *%loop-tokens*)
      (%loop-error "The LOOP form ends where a form was expected.")
      (pop *%loop-tokens*)))

(defun %loop-next-is (&rest names)
  (apply #'%loop-keyword-p (%loop-peek) names))

;;; --- variables ---

(defun %loop-pattern-variables (pattern)
  (cond ((null pattern) nil)
        ((symbolp pattern) (list pattern))
        ((consp pattern) (append (%loop-pattern-variables (car pattern))
                                 (%loop-pattern-variables (cdr pattern))))
        (t (%loop-error "~S cannot be a LOOP variable." pattern))))

(defun %loop-declare (pattern)
  "Record the variables PATTERN binds, rejecting one bound already."
  (dolist (variable (%loop-pattern-variables pattern))
    (when (or (member variable *%loop-variables*)
              (assoc variable *%loop-accumulators*))
      (%loop-error "The LOOP variable ~S is bound more than once." variable))
    (push variable *%loop-variables*)))

(defun %loop-destructure (pattern form)
  "Forms that set the variables of PATTERN from the value of FORM."
  (cond ((null pattern) nil)
        ((symbolp pattern) (list `(setq ,pattern ,form)))
        (t (let ((value (gensym "VALUE")))
             (list `(let ((,value ,form))
                      ,@(%loop-destructure (car pattern) `(car ,value))
                      ,@(%loop-destructure (cdr pattern) `(cdr ,value))))))))

(defun %loop-type-default (type)
  (cond ((member type '(fixnum integer number real rational bit)) 0)
        ((member type '(float single-float double-float short-float long-float)) (coerce 0 type))
        ((and (consp type) (member (car type) '(integer mod unsigned-byte signed-byte))) 0)
        (t nil)))

(defun %loop-optional-type (variable)
  "The type a variable is declared with, read off the tokens, or nil."
  (let ((token (%loop-peek)))
    (cond ((%loop-keyword-p token "OF-TYPE") (%loop-pop) (%loop-pop))
          ((and (symbolp token) (member token '(fixnum float t nil))) (%loop-pop))
          ((and (consp variable) (consp token)
                (or (null (cdr *%loop-tokens*))
                    (and (symbolp (cadr *%loop-tokens*)) (cadr *%loop-tokens*))))
           (%loop-pop)
           nil)
          (t nil))))

(defun %loop-compound-type-p (type)
  (and (consp type)
       (member (car type) '(integer mod unsigned-byte signed-byte float single-float
                            double-float real rational or and not member satisfies))))

(defun %loop-bindings-for (pattern type &optional type-tree)
  "A binding for each variable of PATTERN, to the default for its type.
TYPE is one type for them all, or a tree of types shaped like PATTERN."
  (cond ((null pattern) nil)
        ((symbolp pattern)
         (list (list pattern (%loop-type-default type))))
        ((and (consp type) (or type-tree (not (%loop-compound-type-p type))))
         (append (%loop-bindings-for (car pattern) (car type) t)
                 (%loop-bindings-for (cdr pattern) (cdr type) t)))
        (t (append (%loop-bindings-for (car pattern) type)
                   (%loop-bindings-for (cdr pattern) type)))))

(defun %loop-add-group (parallel bindings)
  (when bindings (push (list parallel bindings) *%loop-groups*)))

;;; --- with ---

(defun %loop-with ()
  (let ((bindings nil) (parallel nil))
    (tagbody
     next
      (let* ((pattern (%loop-pop))
             (type (%loop-optional-type pattern)))
        (%loop-declare pattern)
        (if (%loop-next-is "=")
            (progn
              (%loop-pop)
              (let ((form (%loop-pop)))
                (if (and pattern (symbolp pattern))
                    (push (list pattern form) bindings)
                    (let ((value (gensym "WITH")))
                      (push (list value form) bindings)
                      (dolist (binding (%loop-bindings-for pattern type))
                        (push binding bindings))
                      (push (list (gensym "IGNORED")
                                  `(progn ,@(%loop-destructure pattern value) nil))
                            bindings)))))
            (dolist (binding (%loop-bindings-for pattern type))
              (push binding bindings))))
      (when (%loop-next-is "AND")
        (%loop-pop)
        (setq parallel t)
        (go next)))
    ;; A destructuring binding refers to the one before it, so a group
    ;; holding one is bound in sequence.
    (%loop-add-group (and parallel (every (lambda (b) (symbol-package (car b))) bindings))
                     (nreverse bindings))))

;;; --- for and as ---

;; A variable clause comes to bindings, what runs before the first pass,
;; and what runs before each later one. Each of the two is a list of
;; forms to run, tests that end the loop, and (pattern form) settings.
(defun %loop-spec (bindings first-forms first-tests first-sets step-forms step-tests step-sets)
  (list bindings (list first-forms first-tests first-sets) (list step-forms step-tests step-sets)))

(defun %loop-for-arithmetic (variable)
  (let ((start nil) (start-p nil) (end nil) (end-kind nil) (step nil) (down nil)
        (bindings nil) (counter (gensym "COUNTER")))
    (block prepositions
      (tagbody
       next
         (let ((token (%loop-peek)))
           (cond ((%loop-keyword-p token "FROM" "UPFROM" "DOWNFROM")
                  (when start-p (%loop-error "LOOP: ~S starts twice." variable))
                  (when (%loop-keyword-p token "DOWNFROM") (setq down t))
                  (%loop-pop)
                  (setq start-p t)
                  (push (list counter (%loop-pop)) bindings)
                  (setq start counter))
                 ((%loop-keyword-p token "TO" "UPTO" "BELOW" "DOWNTO" "ABOVE")
                  (when end-kind (%loop-error "LOOP: ~S ends twice." variable))
                  (setq end-kind (intern (symbol-name token) "KEYWORD"))
                  (when (member end-kind '(:downto :above)) (setq down t))
                  (%loop-pop)
                  (setq end (gensym "END"))
                  (push (list end (%loop-pop)) bindings))
                 ((%loop-keyword-p token "BY")
                  (when step (%loop-error "LOOP: ~S has two steps." variable))
                  (%loop-pop)
                  (setq step (gensym "STEP"))
                  (push (list step (%loop-pop)) bindings))
                 (t (return-from prepositions))))
         (go next)))
    (unless start-p (push (list counter 0) bindings))
    (let* ((by (or step 1))
           (test (case end-kind
                   ((:to :upto) (if down `(< ,counter ,end) `(> ,counter ,end)))
                   (:below `(>= ,counter ,end))
                   (:downto `(< ,counter ,end))
                   (:above `(<= ,counter ,end))
                   (t nil)))
           (tests (if test (list test) nil))
           (sets (if variable (list (list variable counter)) nil)))
      (%loop-spec (nreverse bindings) nil tests sets
                  (list `(setq ,counter ,(if down `(- ,counter ,by) `(+ ,counter ,by))))
                  tests sets))))

(defun %loop-step-function (form)
  "How a `by` form advances a list: called by name where it is a quoted or
#' function name, and through a variable otherwise."
  (if (and (consp form) (member (car form) '(function quote)) (symbolp (cadr form)))
      (values (cadr form) nil)
      (let ((fn (gensym "STEP")))
        (values fn (list (list fn form))))))

(defun %loop-advance (fn-name fn-binding tail)
  (if fn-binding `(funcall ,fn-name ,tail) `(,fn-name ,tail)))

(defun %loop-for-in-on (variable on)
  (%loop-pop)
  (let ((tail (gensym "TAIL"))
        (list-form (%loop-pop))
        (fn 'cdr) (fn-binding nil))
    (when (%loop-next-is "BY")
      (%loop-pop)
      (multiple-value-setq (fn fn-binding) (%loop-step-function (%loop-pop))))
    (let ((test (if on `(atom ,tail) `(endp ,tail)))
          (sets (if variable (list (list variable (if on tail `(car ,tail)))) nil)))
      (%loop-spec (append (list (list tail list-form)) fn-binding)
                  nil (list test) sets
                  (list `(setq ,tail ,(%loop-advance fn fn-binding tail)))
                  (list test) sets))))

(defun %loop-for-equals (variable)
  (%loop-pop)
  (let ((first (%loop-pop)))
    (if (%loop-next-is "THEN")
        (progn
          (%loop-pop)
          (let ((then (%loop-pop)))
            (%loop-spec nil nil nil (list (list variable first)) nil nil (list (list variable then)))))
        (%loop-spec nil nil nil (list (list variable first)) nil nil (list (list variable first))))))

(defun %loop-for-across (variable)
  (%loop-pop)
  (let* ((vector (gensym "VECTOR"))
         (index (gensym "INDEX"))
         (test `(>= ,index (length ,vector)))
         (sets (if variable (list (list variable `(aref ,vector ,index))) nil)))
    (%loop-spec (list (list vector (%loop-pop)) (list index 0))
                nil (list test) sets
                (list `(setq ,index (1+ ,index))) (list test) sets)))

(defun %loop-hash-entries (table)
  (let ((entries nil))
    (maphash (lambda (key value) (push (cons key value) entries)) table)
    (nreverse entries)))

(defun %loop-package-symbols (which designator)
  (let ((package (if (packagep designator) designator (find-package designator)))
        (found nil))
    (unless package
      (error 'package-error :package designator))
    (case which
      (:external (do-external-symbols (symbol package) (pushnew symbol found)))
      (:present (do-symbols (symbol package)
                  (when (member (nth-value 1 (find-symbol (symbol-name symbol) package))
                                '(:internal :external))
                    (pushnew symbol found))))
      (t (do-symbols (symbol package) (pushnew symbol found))))
    found))

(defun %loop-for-being (variable)
  (%loop-pop)
  (unless (%loop-next-is "THE" "EACH")
    (%loop-error "LOOP: BEING has to be followed by THE or EACH."))
  (%loop-pop)
  (let ((kind (%loop-pop))
        (tail (gensym "ENTRIES")))
    (cond
      ((%loop-keyword-p kind "HASH-KEY" "HASH-KEYS" "HASH-VALUE" "HASH-VALUES")
       (unless (%loop-next-is "OF" "IN") (%loop-error "LOOP: ~S needs OF or IN." kind))
       (%loop-pop)
       (let* ((table (%loop-pop))
              (keys (%loop-keyword-p kind "HASH-KEY" "HASH-KEYS"))
              (other nil))
         (when (%loop-next-is "USING")
           (%loop-pop)
           (let ((using (%loop-pop)))
             (unless (and (consp using)
                          (%loop-keyword-p (car using) (if keys "HASH-VALUE" "HASH-KEY")))
               (%loop-error "LOOP: ~S is not a USING clause for ~S." using kind))
             (setq other (cadr using))
             (%loop-declare other)))
         (let ((sets (append (if variable
                                 (list (list variable (if keys `(caar ,tail) `(cdar ,tail))))
                                 nil)
                             (if other
                                 (list (list other (if keys `(cdar ,tail) `(caar ,tail))))
                                 nil))))
           (%loop-spec (append (list (list tail `(%loop-hash-entries ,table)))
                               (%loop-bindings-for other nil))
                       nil (list `(endp ,tail)) sets
                       (list `(setq ,tail (cdr ,tail))) (list `(endp ,tail)) sets))))
      ((%loop-keyword-p kind "SYMBOL" "SYMBOLS" "PRESENT-SYMBOL" "PRESENT-SYMBOLS"
                        "EXTERNAL-SYMBOL" "EXTERNAL-SYMBOLS")
       (let ((which (cond ((%loop-keyword-p kind "PRESENT-SYMBOL" "PRESENT-SYMBOLS") :present)
                          ((%loop-keyword-p kind "EXTERNAL-SYMBOL" "EXTERNAL-SYMBOLS") :external)
                          (t :symbols)))
             (package '*package*))
         (when (%loop-next-is "OF" "IN")
           (%loop-pop)
           (setq package (%loop-pop)))
         (let ((sets (if variable (list (list variable `(car ,tail))) nil)))
           (%loop-spec (list (list tail `(%loop-package-symbols ,which ,package)))
                       nil (list `(endp ,tail)) sets
                       (list `(setq ,tail (cdr ,tail))) (list `(endp ,tail)) sets))))
      (t (%loop-error "LOOP: ~S is not something to iterate BEING over." kind)))))

(defun %loop-for-one ()
  (let* ((pattern (%loop-pop))
         (type (%loop-optional-type pattern)))
    (%loop-declare pattern)
    (let ((spec (cond ((%loop-next-is "IN") (%loop-for-in-on pattern nil))
                      ((%loop-next-is "ON") (%loop-for-in-on pattern t))
                      ((%loop-next-is "=") (%loop-for-equals pattern))
                      ((%loop-next-is "ACROSS") (%loop-for-across pattern))
                      ((%loop-next-is "BEING") (%loop-for-being pattern))
                      ((%loop-next-is "FROM" "UPFROM" "DOWNFROM" "TO" "UPTO" "BELOW"
                                      "DOWNTO" "ABOVE" "BY")
                       (when (consp pattern)
                         (%loop-error "LOOP: an arithmetic FOR needs a variable, given ~S." pattern))
                       (%loop-for-arithmetic pattern))
                      (t (%loop-error "LOOP: ~S is not how a FOR clause goes on." (%loop-peek))))))
      ;; The variable's own binding comes after the hidden ones, which
      ;; hold what the clause's forms evaluate to.
      (list (append (car spec) (%loop-bindings-for pattern type))
            (cadr spec) (caddr spec)))))

(defun %loop-emit-phase (specs which)
  "The forms of one phase of a group of FOR clauses: each clause's own
forms and end tests in turn, then the settings, made in parallel when
the clauses were joined by AND."
  (let ((forms nil) (sets nil))
    (dolist (spec specs)
      (destructuring-bind (own tests settings) (nth which spec)
        (dolist (form own) (push form forms))
        (dolist (test tests) (push `(when ,test (go ,*%loop-end*)) forms))
        (dolist (setting settings) (push setting sets))))
    (setq sets (nreverse sets))
    (cond ((null sets))
          ((null (cdr sets))
           (dolist (form (%loop-destructure (caar sets) (cadar sets))) (push form forms)))
          (t (let ((temps (mapcar (lambda (setting) (declare (ignore setting)) (gensym "NEW")) sets)))
               (push `(let ,(mapcar (lambda (temp setting) (list temp (cadr setting))) temps sets)
                        ,@(mapcan (lambda (temp setting) (%loop-destructure (car setting) temp))
                                  temps sets))
                     forms))))
    (nreverse forms)))

(defun %loop-for ()
  (let ((specs (list (%loop-for-one))))
    (tagbody
     next
       (when (%loop-next-is "AND")
         (%loop-pop)
         (push (%loop-for-one) specs)
         (go next)))
    (setq specs (nreverse specs))
    (%loop-add-group (cdr specs) (mapcan (lambda (spec) (copy-list (car spec))) specs))
    (setq *%loop-first* (append (reverse (%loop-emit-phase specs 1)) *%loop-first*))
    (setq *%loop-steps* (append (reverse (%loop-emit-phase specs 2)) *%loop-steps*))))

(defun %loop-repeat ()
  (let ((counter (gensym "REPEAT")))
    (%loop-add-group nil (list (list counter (%loop-pop))))
    (push `(when (<= ,counter 0) (go ,*%loop-end*)) *%loop-first*)
    (push `(setq ,counter (1- ,counter)) *%loop-steps*)
    (push `(when (<= ,counter 0) (go ,*%loop-end*)) *%loop-steps*)))

;;; --- accumulation ---

(defun %loop-category (keyword)
  (cond ((%loop-keyword-p keyword "COLLECT" "COLLECTING" "APPEND" "APPENDING" "NCONC" "NCONCING")
         :list)
        ((%loop-keyword-p keyword "COUNT" "COUNTING" "SUM" "SUMMING") :number)
        (t :extreme)))

(defun %loop-accumulator (name category type)
  "The (variable category tail flag) entry NAME accumulates into, made
the first time. NAME is nil for the loop's own result."
  (let ((entry (assoc name *%loop-accumulators*)))
    (cond (entry
           (unless (eq (cadr entry) category)
             (%loop-error "LOOP: ~S accumulates two kinds of value." (or name "The result")))
           entry)
          (t
           (when (and name (member name *%loop-variables*))
             (%loop-error "The LOOP variable ~S is bound more than once." name))
           (when (and (null name) *%loop-boolean-result*)
             (%loop-error "LOOP cannot both accumulate a result and test with ~A."
                          *%loop-boolean-result*))
           (let* ((variable (or name (gensym "RESULT")))
                  (tail (if (eq category :list) (gensym "TAIL") nil))
                  (flag (if (eq category :extreme) (gensym "SEEN") nil))
                  (initial (if (eq category :number) (or (%loop-type-default type) 0) nil))
                  (made (list name category tail flag variable)))
             (push (list variable initial) *%loop-accumulator-bindings*)
             (when tail (push (list tail nil) *%loop-accumulator-bindings*))
             (when flag (push (list flag nil) *%loop-accumulator-bindings*))
             (push made *%loop-accumulators*)
             (unless name (setq *%loop-anonymous* variable))
             made)))))

(defun %loop-accumulation (keyword it)
  (let* ((form (%loop-form it))
         (name (when (%loop-next-is "INTO") (%loop-pop) (%loop-pop)))
         (type (%loop-accumulation-type))
         (entry (%loop-accumulator name (%loop-category keyword) type))
         (variable (nth 4 entry))
         (tail (nth 2 entry))
         (flag (nth 3 entry))
         (value (gensym "VALUE")))
    (cond ((%loop-keyword-p keyword "COLLECT" "COLLECTING")
           `(let ((,value (list ,form)))
              (if ,tail (setf (cdr ,tail) ,value) (setq ,variable ,value))
              (setq ,tail ,value)))
          ((%loop-keyword-p keyword "APPEND" "APPENDING" "NCONC" "NCONCING")
           `(let ((,value ,(if (%loop-keyword-p keyword "APPEND" "APPENDING")
                               `(copy-list ,form)
                               form)))
              (when ,value
                (if ,tail (setf (cdr ,tail) ,value) (setq ,variable ,value))
                (setq ,tail (last ,value)))))
          ((%loop-keyword-p keyword "COUNT" "COUNTING")
           `(when ,form (setq ,variable (1+ ,variable))))
          ((%loop-keyword-p keyword "SUM" "SUMMING")
           `(setq ,variable (+ ,variable ,form)))
          (t
           (let ((compare (if (%loop-keyword-p keyword "MAXIMIZE" "MAXIMIZING") '> '<)))
             `(let ((,value ,form))
                (when (or (not ,flag) (,compare ,value ,variable))
                  (setq ,variable ,value ,flag t))))))))

(defun %loop-accumulation-type ()
  (let ((token (%loop-peek)))
    (cond ((%loop-keyword-p token "OF-TYPE") (%loop-pop) (%loop-pop))
          ((and (symbolp token) token (not (keywordp token))
                (member token '(fixnum float t nil integer number real rational)))
           (%loop-pop))
          (t nil))))

(defun %loop-form (it)
  "The next form, with `it` standing for the value of the enclosing
conditional's test where there is one."
  (let ((form (%loop-pop)))
    (if (and it (%loop-keyword-p form "IT")) it form)))

;;; --- main clauses ---

(defun %loop-compound-forms ()
  (let ((forms nil))
    (tagbody
     next
       (when (and *%loop-tokens* (consp (%loop-peek)))
         (push (%loop-pop) forms)
         (go next)))
    (nreverse forms)))

(defun %loop-boolean (kind)
  (when (assoc nil *%loop-accumulators*)
    (%loop-error "LOOP cannot both accumulate a result and test with ~A." kind))
  (setq *%loop-boolean-result* kind))

(defun %loop-selectable (it)
  "One clause a conditional can hold, as a form."
  (let ((keyword (%loop-pop)))
    (cond ((%loop-keyword-p keyword "DO" "DOING")
           (let ((forms (%loop-compound-forms)))
             (unless forms (%loop-error "LOOP: DO needs at least one form."))
             `(progn ,@forms)))
          ((%loop-keyword-p keyword "RETURN")
           `(return-from ,*%loop-name* ,(%loop-form it)))
          ((%loop-keyword-p keyword "COLLECT" "COLLECTING" "APPEND" "APPENDING" "NCONC"
                            "NCONCING" "COUNT" "COUNTING" "SUM" "SUMMING" "MAXIMIZE"
                            "MAXIMIZING" "MINIMIZE" "MINIMIZING")
           (%loop-accumulation keyword it))
          ((%loop-keyword-p keyword "IF" "WHEN" "UNLESS")
           (%loop-conditional keyword))
          (t (%loop-error "LOOP: ~S cannot follow a conditional." keyword)))))

(defun %loop-selectables (it)
  (let ((forms (list (%loop-selectable it))))
    (tagbody
     next
       (when (%loop-next-is "AND")
         (%loop-pop)
         (push (%loop-selectable nil) forms)
         (go next)))
    (nreverse forms)))

(defun %loop-conditional (keyword)
  (let* ((test (%loop-pop))
         (it (gensym "IT"))
         (then (%loop-selectables it))
         (else (when (%loop-next-is "ELSE")
                 (%loop-pop)
                 (%loop-selectables it))))
    (when (%loop-next-is "END") (%loop-pop))
    `(let ((,it ,test))
       (if ,(if (%loop-keyword-p keyword "UNLESS") `(not ,it) it)
           (progn ,@then)
           (progn ,@else)))))

(defun %loop-clause ()
  (let ((keyword (%loop-peek)))
    (cond ((%loop-keyword-p keyword "WITH") (%loop-pop) (%loop-with))
          ((%loop-keyword-p keyword "FOR" "AS") (%loop-pop) (%loop-for))
          ((%loop-keyword-p keyword "REPEAT") (%loop-pop) (%loop-repeat))
          ((%loop-keyword-p keyword "INITIALLY")
           (%loop-pop)
           (setq *%loop-prologue* (append (reverse (%loop-compound-forms)) *%loop-prologue*)))
          ((%loop-keyword-p keyword "FINALLY")
           (%loop-pop)
           (setq *%loop-epilogue* (append (reverse (%loop-compound-forms)) *%loop-epilogue*)))
          ((%loop-keyword-p keyword "WHILE")
           (%loop-pop)
           (push `(unless ,(%loop-pop) (go ,*%loop-end*)) *%loop-body*))
          ((%loop-keyword-p keyword "UNTIL")
           (%loop-pop)
           (push `(when ,(%loop-pop) (go ,*%loop-end*)) *%loop-body*))
          ((%loop-keyword-p keyword "ALWAYS")
           (%loop-pop)
           (%loop-boolean "ALWAYS")
           (push `(unless ,(%loop-pop) (return-from ,*%loop-name* nil)) *%loop-body*))
          ((%loop-keyword-p keyword "NEVER")
           (%loop-pop)
           (%loop-boolean "NEVER")
           (push `(when ,(%loop-pop) (return-from ,*%loop-name* nil)) *%loop-body*))
          ((%loop-keyword-p keyword "THEREIS")
           (%loop-pop)
           (%loop-boolean "THEREIS")
           (let ((value (gensym "VALUE")))
             (push `(let ((,value ,(%loop-pop)))
                      (when ,value (return-from ,*%loop-name* ,value)))
                   *%loop-body*)))
          ((%loop-keyword-p keyword "DO" "DOING" "RETURN" "COLLECT" "COLLECTING" "APPEND"
                            "APPENDING" "NCONC" "NCONCING" "COUNT" "COUNTING" "SUM"
                            "SUMMING" "MAXIMIZE" "MAXIMIZING" "MINIMIZE" "MINIMIZING"
                            "IF" "WHEN" "UNLESS")
           (push (%loop-selectable nil) *%loop-body*))
          (t (%loop-error "~S is not a LOOP clause." keyword)))))

;;; --- the expansion ---

(defun %loop-wrap-groups (groups form)
  "FORM inside the binding groups, outermost first."
  (if (null groups)
      form
      (destructuring-bind (parallel bindings) (car groups)
        `(,(if parallel 'let 'let*) ,bindings
          ,(%loop-wrap-groups (cdr groups) form)))))

(defun %loop-result ()
  (cond (*%loop-anonymous* *%loop-anonymous*)
        ((member *%loop-boolean-result* '("ALWAYS" "NEVER") :test #'equal) t)
        (t nil)))

(defun %loop-expand (forms)
  (let ((*%loop-tokens* forms)
        (*%loop-name* nil)
        (*%loop-end* (gensym "END"))
        (*%loop-groups* nil)
        (*%loop-variables* nil)
        (*%loop-prologue* nil)
        (*%loop-first* nil)
        (*%loop-steps* nil)
        (*%loop-body* nil)
        (*%loop-epilogue* nil)
        (*%loop-accumulators* nil)
        (*%loop-accumulator-bindings* nil)
        (*%loop-anonymous* nil)
        (*%loop-boolean-result* nil)
        (next (gensym "NEXT")))
    (when (%loop-next-is "NAMED")
      (%loop-pop)
      (setq *%loop-name* (%loop-pop)))
    (tagbody
     again
       (when *%loop-tokens*
         (%loop-clause)
         (go again)))
    `(block ,*%loop-name*
       ,(%loop-wrap-groups
         (cons (list nil (reverse *%loop-accumulator-bindings*)) (reverse *%loop-groups*))
         `(macrolet ((loop-finish () '(go ,*%loop-end*)))
            (tagbody
               ,@(reverse *%loop-prologue*)
               ,@(reverse *%loop-first*)
               ,next
               ,@(reverse *%loop-body*)
               ,@(reverse *%loop-steps*)
               (go ,next)
               ,*%loop-end*
               ,@(reverse *%loop-epilogue*)
               (return-from ,*%loop-name* ,(%loop-result))))))))

(defmacro loop (&rest forms)
  (if (or (null forms) (consp (car forms)))
      (let ((top (gensym "TOP")))
        `(block nil (tagbody ,top (progn ,@forms) (go ,top))))
      (%loop-expand forms)))

(defmacro loop-finish ()
  (error "LOOP-FINISH is only meaningful inside a LOOP."))

(export '(loop loop-finish))

(in-package "COMMON-LISP-USER")
