;; Logical pathnames.
;;
;; A logical pathname names a host before a colon and separates its
;; directories with semicolons. Its host must have translations before the
;; syntax means anything, and `translate-logical-pathname` applies them
;; until the result is physical.
;;
;; Each top-level form is self-checking and evaluates to T.

(progn
  (setf (logical-pathname-translations "SYS")
        (list (list "SYS:SRC;**;*.*.*" "/usr/src/**/*.*")
              (list "SYS:DOC;*.*.*" "/usr/doc/*.*")))
  (setf (logical-pathname-translations "HOME")
        (list (list "HOME:**;*.*.*" "/home/me/**/*.*")))
  t)

;; A namestring with a defined host reads as a logical pathname.
(let ((p (logical-pathname "SYS:SRC;CODE;EVAL.LISP")))
  (and (pathnamep p)
       (string= (pathname-host p) "SYS")
       (equal (pathname-directory p) '(:absolute "SRC" "CODE"))
       (string= (pathname-name p) "EVAL")
       (string= (pathname-type p) "LISP")))

;; A leading semicolon marks a relative directory, the reverse of the
;; physical syntax.
(equal (pathname-directory (logical-pathname "SYS:;SRC;A.B")) '(:relative "SRC"))

;; The version follows the type, and reads as an integer or :newest.
(and (eql (pathname-version (logical-pathname "SYS:A.B.3")) 3)
     (eq (pathname-version (logical-pathname "SYS:A.B.NEWEST")) :newest)
     (eq (pathname-version (logical-pathname "SYS:A.B.*")) :wild)
     (null (pathname-version (logical-pathname "SYS:A.B"))))

;; A logical namestring round-trips.
(string= (namestring (logical-pathname "SYS:SRC;CODE;EVAL.LISP"))
         "SYS:SRC;CODE;EVAL.LISP")

;; An undefined host is not a logical host, so the text is a physical
;; namestring instead.
(null (ignore-errors (logical-pathname "NOSUCHHOST:A;B.C")))

;; logical-pathname refuses a physical pathname.
(null (ignore-errors (logical-pathname (pathname "/a/b.c"))))

;; --- translation ---

;; :wild-inferiors carries a whole run of directories across.
(string= (namestring (translate-logical-pathname "SYS:SRC;CODE;EVAL.LISP"))
         "/usr/src/CODE/EVAL.LISP")

;; A run of no directories at all still matches.
(string= (namestring (translate-logical-pathname "SYS:SRC;EVAL.LISP"))
         "/usr/src/EVAL.LISP")

;; Several directories carry across in order.
(string= (namestring (translate-logical-pathname "SYS:SRC;A;B;C;EVAL.LISP"))
         "/usr/src/A/B/C/EVAL.LISP")

;; The first rule that matches is the one that applies.
(string= (namestring (translate-logical-pathname "SYS:DOC;MANUAL.TXT"))
         "/usr/doc/MANUAL.TXT")

;; A second host has its own translations.
(string= (namestring (translate-logical-pathname "HOME:NOTES;TODO.TXT"))
         "/home/me/NOTES/TODO.TXT")

;; Translating something already physical leaves it alone.
(string= (namestring (translate-logical-pathname "/etc/passwd")) "/etc/passwd")

;; A logical pathname with no matching rule cannot be translated.
(null (ignore-errors (translate-logical-pathname "SYS:OTHER;X.Y")))

;; --- translate-pathname on its own ---

(string= (namestring (translate-pathname "/a/b/c.lisp" "/a/**/*.*" "/z/**/*.*"))
         "/z/b/c.lisp")

(string= (namestring (translate-pathname "/a/c.lisp" "/a/*.*" "/z/*.*"))
         "/z/c.lisp")

;; A literal component in the pattern has to match exactly.
(null (ignore-errors (translate-pathname "/a/c.lisp" "/b/*.*" "/z/*.*")))

;; A literal component in the replacement overrides what was matched.
(string= (namestring (translate-pathname "/a/c.lisp" "/a/*.*" "/z/fixed.*"))
         "/z/fixed.lisp")

;; --- the translation list ---

;; The translations read back as they were set.
(equal (logical-pathname-translations "HOME")
       '(("HOME:**;*.*.*" "/home/me/**/*.*")))

;; The host name is case-insensitive.
(equal (logical-pathname-translations "home")
       (logical-pathname-translations "HOME"))

;; An undefined host has no translations to read.
(null (ignore-errors (logical-pathname-translations "NOSUCHHOST")))

;; load-logical-pathname-translations says nothing to do for a host that
;; is already defined.
(null (load-logical-pathname-translations "SYS"))

;; It signals when it cannot find a definition for an unknown host.
(null (ignore-errors (load-logical-pathname-translations "NOSUCHHOST")))
