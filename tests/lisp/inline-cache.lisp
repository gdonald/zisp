;; Every form here must evaluate to T.
;;
;; Each call site in compiled code caches the functions it has called:
;; one while monomorphic, up to four while polymorphic, and past that it
;; is megamorphic and looks its callee up in a table the whole machine
;; shares. `%call-site-counters` reports each site of a function, in the
;; order the sites come in its code.

(progn
  (defun inline-cache-one (x) x)
  (defun inline-cache-hot () (dotimes (i 1000000) (inline-cache-one i)))
  (defun inline-cache-a (x) (+ x 1))
  (defun inline-cache-b (x) (+ x 2))
  (defun inline-cache-c (x) (+ x 3))
  (defun inline-cache-d (x) (+ x 4))
  (defun inline-cache-e (x) (+ x 5))
  (defun inline-cache-apply (f x) (funcall f x))
  (defun inline-cache-spread (f x) (funcall f x))
  (defun inline-cache-site (function key)
    (getf (car (%call-site-counters function)) key))
  (dolist (name '(inline-cache-one inline-cache-hot inline-cache-a inline-cache-b
                  inline-cache-c inline-cache-d inline-cache-e
                  inline-cache-apply inline-cache-spread))
    (compile name))
  t)

;; A hot loop with one callee takes the monomorphic path on every call
;; but the first.
(progn
  (inline-cache-hot)
  (let* ((site (car (%call-site-counters #'inline-cache-hot)))
         (hits (getf site :monomorphic))
         (calls (+ hits (getf site :polymorphic) (getf site :megamorphic) (getf site :misses))))
    (and (eq (getf site :state) :monomorphic)
         (>= calls 1000000)
         (>= (* 100 hits) (* 99 calls)))))

;; A site with three callees takes the polymorphic path on every call
;; once each of them has been seen.
(progn
  (inline-cache-apply #'inline-cache-a 0)
  (inline-cache-apply #'inline-cache-b 0)
  (inline-cache-apply #'inline-cache-c 0)
  (let ((polymorphic (inline-cache-site #'inline-cache-apply :polymorphic))
        (misses (inline-cache-site #'inline-cache-apply :misses))
        (megamorphic (inline-cache-site #'inline-cache-apply :megamorphic)))
    (dotimes (i 300)
      (inline-cache-apply (case (mod i 3)
                            (0 #'inline-cache-a)
                            (1 #'inline-cache-b)
                            (t #'inline-cache-c))
                          i))
    (and (eq (inline-cache-site #'inline-cache-apply :state) :polymorphic)
         (= (- (inline-cache-site #'inline-cache-apply :polymorphic) polymorphic) 300)
         (= (inline-cache-site #'inline-cache-apply :misses) misses)
         (= (inline-cache-site #'inline-cache-apply :megamorphic) megamorphic))))

;; The fifth distinct callee turns the site megamorphic.
(progn
  (inline-cache-spread #'inline-cache-a 0)
  (inline-cache-spread #'inline-cache-b 0)
  (inline-cache-spread #'inline-cache-c 0)
  (inline-cache-spread #'inline-cache-d 0)
  (let ((before (inline-cache-site #'inline-cache-spread :to-megamorphic))
        (state (inline-cache-site #'inline-cache-spread :state)))
    (and (eql before 0)
         (eq state :polymorphic)
         (eql (inline-cache-spread #'inline-cache-e 10) 15)
         (eql (inline-cache-site #'inline-cache-spread :to-megamorphic) 1)
         (eq (inline-cache-site #'inline-cache-spread :state) :megamorphic)
         (eql (inline-cache-spread #'inline-cache-a 10) 11)
         (eql (inline-cache-site #'inline-cache-spread :megamorphic) 1))))

;; Redefining the callee empties the caches, so the call reaches the new
;; definition.
(progn
  (defun inline-cache-target () 1)
  (defun inline-cache-caller () (inline-cache-target))
  (compile 'inline-cache-target)
  (compile 'inline-cache-caller)
  (and (eql (inline-cache-caller) 1)
       (eql (inline-cache-caller) 1)
       (eq (inline-cache-site #'inline-cache-caller :state) :monomorphic)
       (progn (defun inline-cache-target () 2) t)
       (eq (inline-cache-site #'inline-cache-caller :state) :empty)
       (eql (inline-cache-caller) 2)
       (progn (setf (symbol-function 'inline-cache-target) (lambda () 3)) t)
       (eql (inline-cache-caller) 3)
       (progn (fmakunbound 'inline-cache-target) t)
       (eq (handler-case (inline-cache-caller) (undefined-function () :gone)) :gone)))
