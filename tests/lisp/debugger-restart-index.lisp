;; An integer selects the restart listed under it. Restart 0 here is the
;; continue restart, so the function carries on past the `cerror`.
(defun reserve-seats (requested available)
  (when (> requested available)
    (cerror "Book the seats that are left." "Only ~d of ~d seats are free." available requested)
    (setq requested available))
  requested)
(reserve-seats 5 3)
0
