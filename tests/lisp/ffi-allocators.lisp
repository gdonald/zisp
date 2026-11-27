;; Every form here must evaluate to T.
;;
;; Allocators: the C heap, and arenas over another allocator.

(progn (use-package "ZISP-FFI") t)

;; With no allocator bound, foreign memory comes from the C heap.
(and (null *foreign-allocator*)
     (allocatorp (c-allocator))
     (eq (c-allocator) (c-allocator)))

;; The C heap counts the bytes it has handed out until they come back.
(let* ((before (allocator-live-bytes (c-allocator)))
       (pointer (allocator-alloc (c-allocator) 100 16)))
  (setf (mem-aref pointer :int 24) 7)
  (and (eql (- (allocator-live-bytes (c-allocator)) before) 100)
       (zerop (mod (pointer-address pointer) 16))
       (eql (mem-aref pointer :int 24) 7)
       (progn (allocator-free (c-allocator) pointer 100 16)
              (eql (allocator-live-bytes (c-allocator)) before))))

;; An arena takes its memory from its parent and gives all of it back
;; when released.
(let* ((before (allocator-live-bytes (c-allocator)))
       (arena (make-arena-allocator)))
  (dotimes (index 50) (allocator-alloc arena 1000))
  (and (> (allocator-live-bytes (c-allocator)) (+ before 50000))
       (eql (allocator-live-bytes arena) 50000)
       (null (release-allocator arena))
       (eql (allocator-live-bytes (c-allocator)) before)))

;; foreign-alloc takes its memory from *foreign-allocator*, and
;; foreign-free gives it back there.
(let* ((arena (make-arena-allocator))
       (pointer (let ((*foreign-allocator* arena))
                  (foreign-alloc :double :count 4 :initial-element 1.5d0))))
  (prog1 (and (eql (allocator-live-bytes arena) 32)
              (zerop (mod (pointer-address pointer) 8))
              (eql (mem-aref pointer :double 3) 1.5d0)
              (progn (foreign-free pointer)
                     (eql (allocator-live-bytes arena) 0)))
    (release-allocator arena)))

;; with-allocator binds an arena for its body and releases it on the way
;; out, by a throw as well as a return.
(let ((before (allocator-live-bytes (c-allocator)))
      (kept nil))
  (catch 'out
    (with-allocator (arena)
      (setf kept arena)
      (foreign-alloc :int :count 1000)
      (throw 'out nil)))
  (and (allocatorp kept)
       (null *foreign-allocator*)
       (eql (allocator-live-bytes (c-allocator)) before)
       (not (null (search "released" (prin1-to-string kept))))))

;; An arena can sit over another arena.
(with-allocator (outer)
  (with-allocator (inner)
    (foreign-alloc :char :count 10)
    (and (eq *foreign-allocator* inner)
         (eql (allocator-live-bytes inner) 10)
         (> (allocator-live-bytes outer) 10))))

;; The value of with-allocator is its body's.
(eql (with-allocator (arena) (allocator-live-bytes arena) 42) 42)

;; A released arena refuses further use, the C heap cannot be released,
;; and an arena with live arenas over it cannot be released either.
(let ((arena (make-arena-allocator)))
  (release-allocator arena)
  (and (eq :refused (handler-case (allocator-alloc arena 8) (error () :refused)))
       (eq :refused (handler-case (release-allocator arena) (error () :refused)))
       (eq :refused (handler-case (release-allocator (c-allocator)) (error () :refused)))
       (let* ((outer (make-arena-allocator))
              (inner (make-arena-allocator outer)))
         (prog1 (eq :refused (handler-case (release-allocator outer) (error () :refused)))
           (release-allocator inner)
           (release-allocator outer)))))

;; An alignment that is not a power of two, a size that is not a count of
;; bytes, and an object that is not an allocator are type errors.
(and (eq :refused (handler-case (allocator-alloc (c-allocator) 8 3) (type-error () :refused)))
     (eq :refused (handler-case (allocator-alloc (c-allocator) -1) (type-error () :refused)))
     (eq :refused (handler-case (allocator-alloc :heap 8) (type-error () :refused))))

;; A null pointer cannot be freed, and a size past a machine word is a
;; type error.
(and (eq :refused (handler-case (allocator-free (c-allocator) (null-pointer) 8) (type-error () :refused)))
     (eq :refused (handler-case (allocator-alloc (c-allocator) (expt 2 70)) (type-error () :refused))))

;; A request the C heap cannot meet signals storage-condition.
(eq :refused (handler-case (allocator-alloc (c-allocator) (expt 2 62))
               (storage-condition () :refused)))

;; Memory foreign-alloc did not hand out, such as a foreign string, goes
;; back to the C heap through foreign-free.
(let ((pointer (foreign-string-alloc "notes")))
  (and (string= (foreign-string-to-lisp pointer) "notes")
       (null (foreign-free pointer))))

;; The C heap prints as such, and an arena as an arena.
(and (search "C heap" (prin1-to-string (c-allocator)))
     (with-allocator (arena) (not (null (search "arena" (prin1-to-string arena))))))
