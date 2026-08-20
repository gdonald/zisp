;; merge-pathnames, per CLHS 19.2.2.4.
;;
;; Each component of the first pathname that is nil is filled in from the
;; defaults. A relative directory is appended to the default's directory
;; rather than replacing it. The version falls back to the third argument
;; when the name came from the first pathname, and to the default's
;; version when the name came from the defaults.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (defun merged (a b)
    (namestring (merge-pathnames a b)))
  t)

;; 1. A missing name and type both come from the defaults.
(string= (merged "/foo/" "/bar/baz.lisp") "/foo/baz.lisp")

;; 2. A missing type comes from the defaults even when the name does not.
(string= (merged "/foo/quux" "/bar/baz.lisp") "/foo/quux.lisp")

;; 3. A supplied type is kept.
(string= (merged "/foo/quux.txt" "/bar/baz.lisp") "/foo/quux.txt")

;; 4. A missing directory comes from the defaults.
(string= (merged "quux.txt" "/bar/baz.lisp") "/bar/quux.txt")

;; 5. A relative directory extends the default's.
(string= (merged "sub/quux.txt" "/bar/baz.lisp") "/bar/sub/quux.txt")

;; 6. An absolute directory replaces the default's.
(string= (merged "/etc/quux.txt" "/bar/baz.lisp") "/etc/quux.txt")

;; 7. A default with no directory leaves the first pathname's alone.
(string= (merged "/etc/a.x" "b.y") "/etc/a.x")

;; 8. Neither has a directory.
(string= (merged "a.x" "b.y") "a.x")

;; 9. The whole of the defaults shows through an empty pathname.
(string= (merged "" "/bar/baz.lisp") "/bar/baz.lisp")

;; 10. A trailing separator means a directory with no name.
(string= (merged "sub/" "/bar/baz.lisp") "/bar/sub/baz.lisp")

;; 11. A parent segment in the first pathname is kept as it is.
(string= (merged "../quux.txt" "/bar/sub/baz.lisp") "/bar/sub/../quux.txt")

;; 12. One argument leaves the pathname alone.
(string= (namestring (merge-pathnames "/a/b.c")) "/a/b.c")

;; 13. Merging a pathname object works like merging its namestring.
(string= (merged (pathname "quux.txt") (pathname "/bar/baz.lisp")) "/bar/quux.txt")

;; 14. A wild name survives the merge.
(eq (pathname-name (merge-pathnames "*.lisp" "/bar/baz.txt")) :wild)

;; 15. A wild type survives the merge.
(eq (pathname-type (merge-pathnames "quux.*" "/bar/baz.txt")) :wild)

;; --- the version component ---

;; 16. With a name of its own, the version comes from the third argument,
;;     which defaults to :newest.
(eq (pathname-version (merge-pathnames "quux.txt" "/bar/baz.lisp")) :newest)

;; 17. The third argument overrides that default.
(eql (pathname-version (merge-pathnames "quux.txt" "/bar/baz.lisp" 7)) 7)

;; 18. With no name of its own, the version comes from the defaults.
(eq (pathname-version
      (merge-pathnames "/foo/" (make-pathname :name "baz" :version :wild)))
    :wild)

;; 19. A version already on the first pathname is kept.
(eql (pathname-version
       (merge-pathnames (make-pathname :name "a" :version 3) "/bar/baz.lisp"))
     3)

;; --- component round-trips ---

;; 20. Every component set by make-pathname reads back.
(let ((p (make-pathname :host "h" :device "d"
                        :directory '(:absolute "a" "b")
                        :name "c" :type "e" :version 9)))
  (and (string= (pathname-host p) "h")
       (string= (pathname-device p) "d")
       (equal (pathname-directory p) '(:absolute "a" "b"))
       (string= (pathname-name p) "c")
       (string= (pathname-type p) "e")
       (eql (pathname-version p) 9)))

;; 21. The three version markers round-trip.
(and (eq (pathname-version (make-pathname :version :newest)) :newest)
     (eq (pathname-version (make-pathname :version :wild)) :wild)
     (eql (pathname-version (make-pathname :version 42)) 42)
     (null (pathname-version (make-pathname :name "a"))))

;; 22. :defaults copies a pathname with one component changed.
(let* ((base (make-pathname :directory '(:absolute "a") :name "b" :type "c"))
       (changed (make-pathname :type "d" :defaults base)))
  (and (string= (namestring changed) "/a/b.d")
       (string= (namestring base) "/a/b.c")))

;; 23. parse-namestring returns the pathname and how much it read.
(let ((text "/a/b.c"))
  (and (string= (namestring (parse-namestring text)) text)
       (= (nth-value 1 (parse-namestring text)) (length text))))

;; 24. A namestring survives a round trip through its components.
(let ((p (parse-namestring "/usr/local/lib/x.tar.gz")))
  (and (string= (namestring p) "/usr/local/lib/x.tar.gz")
       (string= (pathname-name p) "x.tar")
       (string= (pathname-type p) "gz")
       (equal (pathname-directory p) '(:absolute "usr" "local" "lib"))))
