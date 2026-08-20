;; Package symbol movement and conflict resolution, per CLHS 11.1.1.2.5.
;;
;; Two different symbols of the same name must never be visible in one
;; package at once. Every operation that could make that happen either
;; signals or is resolved by a shadowing symbol.
;;
;; Each top-level form is self-checking and evaluates to T. Every result
;; below matches SBCL 2.x.

(progn
  (defun fresh (name)
    "A package by that name with nothing in it and nothing used."
    (when (find-package name) (delete-package name))
    (make-package name :use nil))

  (defun exporting (name symbol-name)
    "A package exporting one symbol of its own."
    (let ((p (fresh name)))
      (export (list (intern symbol-name p)) p)
      p))

  (defun signals-package-error (thunk)
    (if (nth-value 1 (ignore-errors (funcall thunk))) t nil))
  t)

;; 1. export makes an internal symbol external.
(let ((p (fresh "T1")))
  (let ((s (intern "X" p)))
    (and (eq (nth-value 1 (find-symbol "X" p)) :internal)
         (export (list s) p)
         (eq (nth-value 1 (find-symbol "X" p)) :external))))

;; 2. An exported symbol becomes visible to a package that uses this one.
(let ((source (exporting "T2A" "X")))
  (let ((user (fresh "T2B")))
    (use-package source user)
    (and (eq (nth-value 1 (find-symbol "X" user)) :inherited)
         (eq (find-symbol "X" user) (find-symbol "X" source)))))

;; 3. Exporting a symbol a user package already has a different one for
;;    is a conflict.
(let ((source (fresh "T3A"))
      (user (fresh "T3B")))
  (intern "X" source)
  (intern "X" user)
  (use-package source user)
  (signals-package-error
    (lambda () (export (list (find-symbol "X" source)) source))))

;; 4. import brings a symbol in as internal.
(let ((source (exporting "T4A" "X"))
      (target (fresh "T4B")))
  (import (list (find-symbol "X" source)) target)
  (and (eq (nth-value 1 (find-symbol "X" target)) :internal)
       (eq (find-symbol "X" target) (find-symbol "X" source))))

;; 5. Importing the same symbol twice does nothing the second time.
(let ((source (exporting "T5A" "X"))
      (target (fresh "T5B")))
  (import (list (find-symbol "X" source)) target)
  (import (list (find-symbol "X" source)) target)
  (eq (nth-value 1 (find-symbol "X" target)) :internal))

;; 6. Importing over a different symbol of the same name is a conflict.
(let ((source (exporting "T6A" "X"))
      (target (fresh "T6B")))
  (intern "X" target)
  (signals-package-error
    (lambda () (import (list (find-symbol "X" source)) target))))

;; 7. The conflict holds whether the resident symbol is internal or
;;    external.
(let ((source (exporting "T7A" "X"))
      (target (fresh "T7B")))
  (export (list (intern "X" target)) target)
  (signals-package-error
    (lambda () (import (list (find-symbol "X" source)) target))))

;; 8. Importing a symbol the package already inherits under that name is
;;    also a conflict.
(let ((source (exporting "T8A" "X"))
      (other (exporting "T8B" "X"))
      (target (fresh "T8C")))
  (use-package other target)
  (signals-package-error
    (lambda () (import (list (find-symbol "X" source)) target))))

;; 9. unintern removes a symbol from a package.
(let ((p (fresh "T9")))
  (let ((s (intern "X" p)))
    (and (unintern s p)
         (null (find-symbol "X" p)))))

;; 10. unintern of a symbol that is not there reports nothing removed.
(let ((p (fresh "T10"))
      (other (fresh "T10B")))
  (null (unintern (intern "X" other) p)))

;; 11. uninterning a shadowing symbol that was holding two inherited
;;     symbols apart is a conflict.
(let ((a (exporting "T11A" "X"))
      (b (exporting "T11B" "X"))
      (target (fresh "T11C")))
  (shadow "X" target)
  (use-package a target)
  (use-package b target)
  (signals-package-error
    (lambda () (unintern (find-symbol "X" target) target))))

;; 12. When only one package exports the name, uninterning the shadow is
;;     fine and the inherited symbol shows through.
(let ((a (exporting "T12A" "X"))
      (target (fresh "T12B")))
  (shadow "X" target)
  (use-package a target)
  (unintern (find-symbol "X" target) target)
  (eq (nth-value 1 (find-symbol "X" target)) :inherited))

;; 13. shadow creates a symbol when the package has none.
(let ((p (fresh "T13")))
  (shadow "X" p)
  (and (eq (nth-value 1 (find-symbol "X" p)) :internal)
       (= (length (package-shadowing-symbols p)) 1)))

;; 14. shadow over an existing symbol marks that one rather than making
;;     another.
(let ((p (fresh "T14")))
  (let ((s (intern "X" p)))
    (shadow "X" p)
    (and (eq (find-symbol "X" p) s)
         (= (length (package-shadowing-symbols p)) 1))))

;; 15. A shadowing symbol wins over an inherited one of the same name.
(let ((source (exporting "T15A" "X"))
      (target (fresh "T15B")))
  (shadow "X" target)
  (use-package source target)
  (and (eq (nth-value 1 (find-symbol "X" target)) :internal)
       (not (eq (find-symbol "X" target) (find-symbol "X" source)))))

;; 16. shadowing-import replaces what was visible, silently.
(let ((source (exporting "T16A" "X"))
      (target (fresh "T16B")))
  (intern "X" target)
  (shadowing-import (list (find-symbol "X" source)) target)
  (and (eq (find-symbol "X" target) (find-symbol "X" source))
       (= (length (package-shadowing-symbols target)) 1)))

;; 17. shadowing-import resolves a conflict that plain import would signal.
(let ((a (exporting "T17A" "X"))
      (b (exporting "T17B" "X"))
      (target (fresh "T17C")))
  (use-package a target)
  (shadowing-import (list (find-symbol "X" b)) target)
  (eq (find-symbol "X" target) (find-symbol "X" b)))

;; 18. use-package signals when two used packages export the same name.
(let ((a (exporting "T18A" "X"))
      (b (exporting "T18B" "X"))
      (target (fresh "T18C")))
  (use-package a target)
  (signals-package-error (lambda () (use-package b target))))

;; 19. use-package signals when the incoming name clashes with a symbol
;;     the package already owns.
(let ((a (exporting "T19A" "X"))
      (target (fresh "T19B")))
  (intern "X" target)
  (signals-package-error (lambda () (use-package a target))))

;; 20. A shadowing symbol settles the name, so the same use-package is
;;     then allowed.
(let ((a (exporting "T20A" "X"))
      (target (fresh "T20B")))
  (shadow "X" target)
  (use-package a target)
  (eq (nth-value 1 (find-symbol "X" target)) :internal))

;; 21. Two packages exporting the same symbol are not in conflict.
(let ((source (exporting "T21A" "X"))
      (relay (fresh "T21B"))
      (target (fresh "T21C")))
  (import (list (find-symbol "X" source)) relay)
  (export (list (find-symbol "X" relay)) relay)
  (use-package source target)
  (use-package relay target)
  (eq (nth-value 1 (find-symbol "X" target)) :inherited))

;; 22. Using the same package twice is not a conflict with itself.
(let ((a (exporting "T22A" "X"))
      (target (fresh "T22B")))
  (use-package a target)
  (use-package a target)
  (= (length (package-use-list target)) 1))

;; 23. unuse-package takes the inherited symbols away again.
(let ((a (exporting "T23A" "X"))
      (target (fresh "T23B")))
  (use-package a target)
  (unuse-package a target)
  (null (find-symbol "X" target)))

;; 24. unexport puts an external symbol back to internal.
(let ((p (exporting "T24" "X")))
  (unexport (list (find-symbol "X" p)) p)
  (eq (nth-value 1 (find-symbol "X" p)) :internal))

;; 25. A symbol's home package is where it was first interned.
(let ((p (fresh "T25")))
  (eq (symbol-package (intern "X" p)) p))
