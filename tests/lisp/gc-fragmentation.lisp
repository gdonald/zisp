;; Worst-case fragmentation and coalescing.
;;
;; Ten thousand objects of four different sizes are allocated and every
;; other one is kept, so no two dead objects are neighbours. Once the
;; survivors are dropped as well, every run of dead objects has to come
;; back as a single free block: one per region at most.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defstruct gc-a x)
  (defstruct gc-b x y)
  (defstruct gc-c x y z)
  (defstruct gc-d x y z w)
  t)

(progn
  (defun gc-make (i)
    (if (= (mod i 4) 0)
        (make-gc-a :x i)
        (if (= (mod i 4) 1)
            (make-gc-b :x i :y i)
            (if (= (mod i 4) 2)
                (make-gc-c :x i :y i :z i)
                (make-gc-d :x i :y i :z i :w i)))))
  (defun gc-build (i limit kept)
    (if (< i limit)
        (gc-build (+ i 1)
                  limit
                  (if (= 0 (mod i 2))
                      (cons (gc-make i) kept)
                      (progn (gc-make i) kept)))
        kept))
  t)

(progn
  (defun room-get (key plist)
    (if (null plist)
        nil
        (if (eq (car plist) key)
            (car (cdr plist))
            (room-get key (cdr (cdr plist))))))
  (defun room-value (key) (room-get key (room)))
  t)

(progn
  (defparameter *gc-survivors* (gc-build 0 10000 nil))
  (= (length *gc-survivors*) 5000))

(gc)

;; Every survivor sits between two dead objects, so next to nothing can
;; merge and the free blocks are many.
(> (room-value :free-blocks) 100)

;; The survivors came through whole.
(= (gc-c-x (car *gc-survivors*)) 9998)

(progn (setq *gc-survivors* nil) (gc))

;; With the survivors gone, each region collapses to a single free block.
(<= (room-value :free-blocks) 100)

;; What is left is a handful of large blocks rather than many small
;; ones, which is what merging the runs bought.
(> (room-value :free-bytes) (* 1000 (room-value :free-blocks)))

;; The reclaimed space is handed out again rather than the heap growing.
(progn
  (defparameter *gc-regions-before* (room-value :regions))
  (defparameter *gc-survivors* (gc-build 0 10000 nil))
  (<= (room-value :regions) *gc-regions-before*))
