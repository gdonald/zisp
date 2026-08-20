;; Unicode case mapping.
;;
;; `char-upcase` and `char-downcase` are the one-to-one mappings CLHS
;; defines, and `string-upcase` and friends are built on them. The
;; `unicode-` functions apply the full mappings from SpecialCasing.txt,
;; where one character can produce several and context can matter.
;;
;; Each top-level form is self-checking and evaluates to T.

;; --- the one-to-one mappings across the covered blocks ---

(char= (char-upcase #\a) #\A)
(char= (char-downcase #\Z) #\z)
(char= (char-upcase #\U+00E9) #\U+00C9)
(char= (char-downcase #\U+00C9) #\U+00E9)
(char= (char-upcase #\U+00FF) #\U+0178)
(char= (char-downcase #\U+0178) #\U+00FF)
(char= (char-upcase #\U+0101) #\U+0100)
(char= (char-downcase #\U+0100) #\U+0101)
(char= (char-upcase #\U+013A) #\U+0139)
(char= (char-downcase #\U+0139) #\U+013A)
(char= (char-upcase #\U+03B1) #\U+0391)
(char= (char-downcase #\U+0391) #\U+03B1)
(char= (char-upcase #\U+03C9) #\U+03A9)
(char= (char-upcase #\U+0430) #\U+0410)
(char= (char-downcase #\U+0410) #\U+0430)
(char= (char-upcase #\U+0450) #\U+0400)
(char= (char-downcase #\U+0400) #\U+0450)

;; A character outside the covered blocks is left alone.
(char= (char-upcase #\U+4E00) #\U+4E00)
(char= (char-upcase #\U+1F600) #\U+1F600)

;; --- the Turkish pair ---
;;
;; Dotless i uppercases to plain I, and plain i uppercases to dotted
;; capital I. Those are the pairs Turkish uses, and they are where the
;; default mapping and the Turkish one part company: the default
;; lowercases dotted capital I to i plus a combining dot, not to plain i.

(char= (char-upcase #\U+0131) #\I)
(char= (char-downcase #\U+0130) #\i)
(char= (char-upcase #\i) #\I)
(string= (unicode-downcase (string #\U+0130)) (concatenate 'string (string #\i) (string #\U+0307)))
(= (length (unicode-downcase (string #\U+0130))) 2)
(char= (char-upcase #\U+0131) (char-upcase #\i))

;; --- German sharp s ---

(string= (unicode-upcase "straße") "STRASSE")
(string= (unicode-upcase (string #\U+00DF)) "SS")
(= (length (unicode-upcase (string #\U+00DF))) 2)
(string= (unicode-downcase (unicode-upcase "straße")) "strasse")
;; The one-to-one mapping cannot expand, so the standard function leaves it.
(string= (string-upcase (string #\U+00DF)) (string #\U+00DF))

;; --- Greek final sigma ---

(char= (char (unicode-downcase "ΟΔΟΣ") 3) #\U+03C2)
(char= (char (unicode-downcase "ΣΟΦΟΣ") 0) #\U+03C3)
(char= (char (unicode-downcase "ΣΟΦΟΣ") 4) #\U+03C2)
(char= (char (unicode-downcase "ΟΔΟΣ ΤΙΣ") 3) #\U+03C2)
(char= (char (unicode-downcase "ΟΔΟΣ ΤΙΣ") 7) #\U+03C2)
;; Both sigmas uppercase back to the one capital.
(char= (char-upcase #\U+03C2) #\U+03A3)
(char= (char-upcase #\U+03C3) #\U+03A3)
(string= (unicode-upcase (unicode-downcase "ΟΔΟΣ")) "ΟΔΟΣ")

;; --- ligatures ---

(string= (unicode-upcase (string #\U+FB03)) "FFI")
(string= (unicode-upcase (string #\U+FB00)) "FF")
(string= (unicode-upcase (string #\U+FB01)) "FI")
(string= (unicode-upcase (string #\U+FB02)) "FL")
(string= (unicode-upcase (string #\U+FB04)) "FFL")
(string= (unicode-upcase (string #\U+FB05)) "ST")
(= (length (unicode-upcase (string #\U+FB03))) 3)
(string= (unicode-upcase "ﬁnal") "FINAL")

;; --- other SpecialCasing rows ---

(string= (unicode-upcase (string #\U+0149))
         (concatenate 'string (string #\U+02BC) "N"))
(string= (unicode-upcase (string #\U+01F0))
         (concatenate 'string "J" (string #\U+030C)))
(= (length (unicode-upcase (string #\U+0390))) 3)
(= (length (unicode-upcase (string #\U+03B0))) 3)
(string= (unicode-upcase (string #\U+1E96))
         (concatenate 'string "H" (string #\U+0331)))
(string= (unicode-upcase (string #\U+0587))
         (concatenate 'string (string #\U+0535) (string #\U+0552)))
(string= (unicode-upcase (string #\U+FB13))
         (concatenate 'string (string #\U+0544) (string #\U+0546)))

;; --- combining marks ---
;;
;; There is no normalization, so the composed and decomposed spellings are
;; different strings. Case mapping keeps the mark and the length.

(= (length (concatenate 'string "e" (string #\U+0301))) 2)
(= (length (string #\U+00E9)) 1)
(not (string= (concatenate 'string "e" (string #\U+0301)) (string #\U+00E9)))
(string= (unicode-upcase (concatenate 'string "e" (string #\U+0301)))
         (concatenate 'string "E" (string #\U+0301)))
(= (length (unicode-upcase (concatenate 'string "e" (string #\U+0301)))) 2)
(char= (char (unicode-upcase (concatenate 'string "e" (string #\U+0301))) 1) #\U+0301)

;; --- the BMP boundary and surrogates ---

(char= (code-char 65535) #\U+FFFF)
(= (char-code (char (string (code-char 65535)) 0)) 65535)
(= (char-code (char (string (code-char 65536)) 0)) 65536)
(= (length (string (code-char 65536))) 1)
(null (code-char 55296))
(null (code-char 57343))
(= (char-code (code-char 57344)) 57344)
(= (char-code (code-char 1114111)) 1114111)
(null (code-char 1114112))
(= (length "日本語") 3)
(char= (char "日本語" 1) #\U+672C)
