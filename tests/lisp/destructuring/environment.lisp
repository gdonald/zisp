;; &environment captures the macroexpansion environment and can be handed
;; to macroexpand-1 / macroexpand inside the macro body.
;;
;; Each top-level form is self-checking and evaluates to T. Every form
;; produces T under SBCL 2.x as well.

;; the captured environment drives a nested macroexpand-1
(progn
  (defmacro dsb-env-inner () ''expanded)
  (defmacro dsb-env-1 (form &environment env)
    (list 'quote (macroexpand-1 form env)))
  (equal (dsb-env-1 (dsb-env-inner)) '(quote expanded)))

;; &environment after the required parameters consumes no positional args
(progn
  (defmacro dsb-env-2 (a b &environment env)
    (list 'quote (list a b (macroexpand-1 'dsb-env-2-not-a-macro env))))
  (equal (dsb-env-2 x y) '(x y dsb-env-2-not-a-macro)))

;; the captured environment drives a full nested macroexpand chain
(progn
  (defmacro dsb-env-chain-1 () ''done)
  (defmacro dsb-env-chain-2 () '(dsb-env-chain-1))
  (defmacro dsb-env-3 (form &environment env)
    (macroexpand form env))
  (equal (dsb-env-3 (dsb-env-chain-2)) 'done))
