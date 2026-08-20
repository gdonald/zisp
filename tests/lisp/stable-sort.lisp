;; Sorting acceptance corpus.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; Stability gate: 1000 (key index) pairs with ten distinct keys, so every
;; key has a hundred equal-key elements whose index order must survive.
(progn
  (defun build-pairs (n acc)
    (if (zerop n)
        acc
        (build-pairs (1- n) (cons (list (mod (1- n) 10) (1- n)) acc))))

  (defun sorted-by-key-then-index (lst)
    (if (null (cdr lst))
        t
        (let ((a (car lst))
              (b (cadr lst)))
          (if (or (< (car a) (car b))
                  (and (= (car a) (car b))
                       (< (cadr a) (cadr b))))
              (sorted-by-key-then-index (cdr lst))
              nil))))

  (setq unsorted-pairs (build-pairs 1000 nil))
  (setq sorted-pairs (stable-sort (copy-seq unsorted-pairs) #'< :key #'car))
  (and (= (length sorted-pairs) 1000)
       (sorted-by-key-then-index sorted-pairs)))

;; The keys really did start out interleaved, so the gate above is not
;; passing on an already-ordered input.
(progn
  (setq first-four (subseq unsorted-pairs 0 4))
  (equal first-four '((0 0) (1 1) (2 2) (3 3))))

;; sort orders a list and a vector with the same predicate.
(and (equal (sort (list 3 1 2) #'<) '(1 2 3))
     (equal (concatenate 'list (sort #(3 1 2) #'<)) '(1 2 3)))

;; :key is honored by sort.
(equal (sort (list '(3 c) '(1 a) '(2 b)) #'< :key #'car)
       '((1 a) (2 b) (3 c)))

;; merge interleaves two ordered sequences.
(and (equal (merge 'list (list 1 3 5) (list 2 4 6) #'<) '(1 2 3 4 5 6))
     (equal (merge 'list nil (list 1 2) #'<) '(1 2))
     (equal (merge 'list (list 1 2) nil #'<) '(1 2))
     (equal (concatenate 'list (merge 'vector #(1 3) #(2 4) #'<)) '(1 2 3 4)))

;; merge is stable: on a tie the element from the first sequence goes first.
(equal (merge 'list
              (list '(1 left) '(2 left))
              (list '(1 right) '(2 right))
              #'<
              :key #'car)
       '((1 left) (1 right) (2 left) (2 right)))
