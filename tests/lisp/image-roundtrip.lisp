;; Every form here must evaluate to T.
;;
;; `%image-round-trip` writes what is reachable from an object the way a
;; saved image writes it and reads it back as fresh objects, rebuilding
;; every reference from the indices in the file. Shared structure comes
;; back shared, cycles come back as cycles, and nothing is the original.

(let* ((shared (list :a :b))
       (copy (%image-round-trip (list shared shared (vector shared)))))
  (and (equal (subseq copy 0 2) (list shared shared))
       (equal (aref (third copy) 0) shared)
       (eq (first copy) (second copy))
       (eq (first copy) (aref (third copy) 0))
       (not (eq (first copy) shared))))

(let* ((cycle (let ((c (list 1 2 3))) (setf (cdr (last c)) c) c))
       (copy (%image-round-trip cycle)))
  (and (not (eq copy cycle))
       (eql (first copy) 1)
       (eq (cdddr copy) copy)))

(let* ((node (list :node nil))
       (graph (progn (setf (second node) node) (list node node)))
       (copy (%image-round-trip graph)))
  (and (eq (first copy) (second copy))
       (eq (second (first copy)) (first copy))))

(let* ((table (make-hash-table :test 'eq))
       (key (list :key)))
  (setf (gethash key table) key)
  (let ((copy (%image-round-trip (list table key))))
    (eq (gethash (second copy) (first copy)) (second copy))))
