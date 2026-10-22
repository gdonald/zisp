;; `:r NAME` selects a restart by its name. The continue restart takes no
;; arguments; use-value asks for the value to use.
(defun scale-reading (reading)
  (when (minusp reading)
    (cerror "Use the absolute value." "Negative reading ~d." reading)
    (setq reading (- reading)))
  (* reading 2))
(scale-reading -4)
:r continue
(+ unset-offset 5)
:r use-value
(* 6 7)
