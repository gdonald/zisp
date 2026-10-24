;; Every form here must evaluate to T.
;;
;; Each compiled function carries its own constant pool. Inside one
;; function, constants that are equal share an entry; two functions
;; never share one.

(progn
  (defun const-pool-first () '(1 2 3))
  (defun const-pool-second () '(1 2 3))
  (defun const-pool-twice () (list '(1 2 3) '(1 2 3)))
  (compile 'const-pool-first)
  (compile 'const-pool-second)
  (compile 'const-pool-twice)
  t)

(let ((listing (with-output-to-string (*standard-output*) (disassemble 'const-pool-first))))
  (and (search "Constants:" listing)
       (search "(1 2 3)" listing :start2 (search "Constants:" listing))
       t))

(let ((first-pool (%function-constants #'const-pool-first))
      (second-pool (%function-constants #'const-pool-second)))
  (and (equal first-pool '((1 2 3)))
       (equal second-pool '((1 2 3)))
       (not (eq (car first-pool) (car second-pool)))))

(equal (%function-constants #'const-pool-twice) '((1 2 3) list))

(let ((made (const-pool-twice)))
  (eq (first made) (second made)))

(let ((listing (with-output-to-string (*standard-output*) (disassemble 'const-pool-twice))))
  (let ((pool (subseq listing (search "Constants:" listing))))
    (and (search "(1 2 3)" pool)
         (null (search "(1 2 3)" pool :start2 (1+ (search "(1 2 3)" pool)))))))

(let ((result t))
  (with-output-to-string (*standard-output*)
    (setq result (disassemble '(lambda (x) (* x x)))))
  (null result))
