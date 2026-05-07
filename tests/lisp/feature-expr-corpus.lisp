;; tests/lisp/feature-expr-corpus.lisp
;; ROADMAP 1.2.10 acceptance corpus.
;;
;; Each non-comment line: <expected> <features-csv> <expr>
;;   <expected>      — TRUE or FALSE, the value of the expression
;;   <features-csv>  — comma-separated keyword names (always begin with `:`)
;;                     interned in the reader's feature list verbatim
;;   <expr>          — one feature expression per CLHS 24.1.2.1.1
;;
;; All 30 entries below evaluate identically to SBCL when *features* is
;; bound to the same set. Lines beginning with `;` are comments. Blank
;; lines are skipped.
;;
;; Coverage:
;;   - >=10 entries with nesting depth >=4 (markers labeled "depth4")
;;   - >=5 entries mix at least two of `and` / `or` / `not` (markers labeled "mixed")

;; ----- atoms / 1-level ------------------------------------------------
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL sbcl
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL ccl
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL unix
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL aix
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or sbcl ccl)
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and sbcl ccl)
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (not ccl)
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (not sbcl)
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and)
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or)
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and sbcl unix)
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or aix (not unix))

;; ----- mixed and/or/not (5 required) ----------------------------------
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and sbcl (not ccl))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or ccl (and sbcl unix))
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and (not sbcl) (or unix x86-64))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or (and ccl unix) (not aix))
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and ccl (or unix windows) (not aix))

;; ----- depth >=4 (10 required) ----------------------------------------
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (not (or windows (and darwin (or aix mips))))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or sbcl (and unix (or x86-64 (not aix))))
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and (or sbcl ccl) (or (and (not unix) x86-64) windows))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and sbcl (and unix (and (or x86-64 arm) (not aix))))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or windows (or aix (and (not ccl) (and unix sbcl))))
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and (not (or sbcl (and ccl ansi-cl))) (and unix x86-64))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or (and ccl windows) (and sbcl (and unix (not aix))))
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (not (and sbcl (or unix (or windows aix))))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and ansi-cl (or sbcl (and ccl (not (or aix windows)))))
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and (or sbcl (and ccl (not aix))) unix little-endian)
FALSE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and unix (and (not sbcl) (or x86-64 (and ccl ansi-cl))))

;; ----- a couple more well-mixed mid-depth cases -----------------------
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (or sbcl windows)
TRUE :SBCL,:UNIX,:LITTLE-ENDIAN,:X86-64,:ANSI-CL (and (or sbcl ccl) (not (and aix windows)))
