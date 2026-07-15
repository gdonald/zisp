;; define-setf-expander corpus: five expanders exercising the 5-value
;; protocol per CLHS 5.1.1.2.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; 1. Side-effect ordering: place subforms evaluate before the value form,
;;    left to right, exactly once.
(progn
  (setq ordering-log nil)
  (defun ordering-tick (tag val)
    (push tag ordering-log)
    val)
  (setq ordering-cell (cons 1 2))
  (define-setf-expander ordered-cell (c)
    (let ((cell-temp (gensym))
          (store (gensym)))
      (values (list cell-temp) (list c) (list store)
              `(progn (rplaca ,cell-temp ,store) ,store)
              `(car ,cell-temp))))
  (setf (ordered-cell (ordering-tick 'place ordering-cell))
        (ordering-tick 'value 5))
  (and (equal ordering-log '(value place))
       (equal (car ordering-cell) 5)))

;; 2. Multiple store variables: the value form's two values land in two
;;    stores, written to the car and cdr together.
(progn
  (setq both-pair (cons 1 2))
  (define-setf-expander both-halves (p)
    (let ((pair-temp (gensym))
          (store-a (gensym))
          (store-b (gensym)))
      (values (list pair-temp) (list p) (list store-a store-b)
              `(progn (rplaca ,pair-temp ,store-a)
                      (rplacd ,pair-temp ,store-b)
                      (values ,store-a ,store-b))
              `(values (car ,pair-temp) (cdr ,pair-temp)))))
  (setf (both-halves both-pair) (values 10 20))
  (and (equal (car both-pair) 10)
       (equal (cdr both-pair) 20)))

;; 3. Environment capture: the expander macroexpands its subform in the
;;    passed environment to find the real place.
(progn
  (defmacro cell-alias () 'aliased-cell)
  (setq aliased-cell (cons 1 2))
  (define-setf-expander through-alias (form &environment env)
    (let ((expanded (macroexpand form env))
          (store (gensym)))
      (values nil nil (list store)
              `(progn (rplaca ,expanded ,store) ,store)
              `(car ,expanded))))
  (setf (through-alias (cell-alias)) 77)
  (equal (car aliased-cell) 77))

;; 4. Read and write share a computed temporary: the index side effect runs
;;    once even though incf both reads and stores.
(progn
  (setq index-calls 0)
  (setq shared-list (list 10 20 30))
  (define-setf-expander counted-second (l)
    (let ((list-temp (gensym))
          (index-temp (gensym))
          (store (gensym)))
      (values (list list-temp index-temp)
              (list l '(progn (setq index-calls (+ index-calls 1)) 1))
              (list store)
              `(progn (rplaca (nthcdr ,index-temp ,list-temp) ,store) ,store)
              `(nth ,index-temp ,list-temp))))
  (incf (counted-second shared-list) 5)
  (and (equal (nth 1 shared-list) 25)
       (equal index-calls 1)))

;; 5. Generic-function-style place: access and update both go through
;;    ordinary functions.
(progn
  (setq field-store (list 0 0))
  (defun field-ref (obj i) (nth i obj))
  (defun field-set (obj i v)
    (rplaca (nthcdr i obj) v)
    v)
  (define-setf-expander field-ref (obj i)
    (let ((obj-temp (gensym))
          (index-temp (gensym))
          (store (gensym)))
      (values (list obj-temp index-temp) (list obj i) (list store)
              `(field-set ,obj-temp ,index-temp ,store)
              `(field-ref ,obj-temp ,index-temp))))
  (setf (field-ref field-store 1) 9)
  (and (equal (field-ref field-store 1) 9)
       (equal (incf (field-ref field-store 0) 3) 3)
       (equal field-store '(3 9))))
