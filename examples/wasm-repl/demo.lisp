;; Lisp in the page calling JavaScript through js:call.

(js:call "console.log" "hello")

(defparameter *started* (js:call "Date.now"))

(defun fib (n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(fib 18)

(defparameter *elapsed* (- (js:call "Date.now") *started*))

(js:call "console.log" (format nil "fib 18 took ~d ms" *elapsed*))

(js:call "Math.max" 3 9 4)

(js:call "JSON.parse" "{\"name\": \"zisp\", \"tags\": [\"lisp\", \"zig\"]}")

(handler-case (js:call "JSON.parse" "{") (error (e) (princ-to-string e)))
