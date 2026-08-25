;;; all the performance benchmarks
;;;
;;; Time-stamp: <2016-05-13 19:48:31 jack>


(in-package :cl-bench)


(defbench compiler
    :group :misc
    :function 'cl-bench.misc:run-compiler
    :long "Compilation of the Gabriel benchmarks"
    :runs 10
    :disabled-for '(:gcl :armedbear))

(defbench load-fasl
    :group :misc
    :function 'cl-bench.misc:run-fasload
    :runs 20
    :disabled-for '(:gcl :armedbear))

(defbench sum-permutations
    :group :misc
    :long "traversal of a large, linked, self-sharing structure"
    :function 'cl-bench.misc:run-permutations
    :runs 3
    :disabled-for '(:lispworks-personal-edition))

(defbench walk-list/seq
    :group :misc
    :long "Walk a list of 2M fixnums that were sequentially allocated"
    :setup 'cl-bench.misc::setup-walk-list/seq
    :function 'cl-bench.misc:walk-list/seq
    :runs 100
    :disabled-for '(:lispworks-personal-edition :armedbear :allegro-cl-express))

(defbench walk-list/mess
    :group :misc
    :long "Walk a list of 2M fixnums that were mergesorted to spread pointers"
    :setup 'cl-bench.misc::setup-walk-list/mess
    :function 'cl-bench.misc:walk-list/mess
    :runs 10
    :disabled-for '(:lispworks-personal-edition :armedbear :poplog :allegro-cl-express :clasp :ecl-bytecmp :genera :sbcl))

(defbench boyer
  :group :gabriel
  :function 'cl-bench.gabriel:boyer
  :long "CONS-intensive logic-programming code"
  :runs 30)

(defbench browse
  :group :gabriel
  :function 'cl-bench.gabriel:browse
  :runs 10)

(defbench dderiv
  :group :gabriel
  :function 'cl-bench.gabriel:dderiv-run
  :runs 50)

(defbench deriv
  :group :gabriel
  :function 'cl-bench.gabriel:deriv-run
  :runs 60)

(defbench destructive
  :group :gabriel
  :function 'cl-bench.gabriel:run-destructive
  :runs 100)

(defbench div2-test-1
  :group :gabriel
  :function 'cl-bench.gabriel:run-div2-test1
  :runs 200)

(defbench div2-test-2
  :group :gabriel
  :function 'cl-bench.gabriel:run-div2-test2
  :runs 200)

(defbench fft
  :group :gabriel
  :function 'cl-bench.gabriel:run-fft
  :runs 30)

(defbench frpoly/fixnum
  :group :gabriel
  :function 'cl-bench.gabriel:run-frpoly/fixnum
  :runs 100)

(defbench frpoly/bignum
  :group :gabriel
  :function 'cl-bench.gabriel:run-frpoly/bignum
  :runs 30)

(defbench frpoly/float
  :group :gabriel
  :function 'cl-bench.gabriel:run-frpoly/float
  :runs 100)

(defbench puzzle
  :group :gabriel
  :long "Forest Baskett's Puzzle, exercising simple-vectors"
  :function 'cl-bench.gabriel:run-puzzle
  :runs 150)

(defbench tak
  :group :gabriel
  :function 'cl-bench.gabriel:run-tak
  :runs 300)

(defbench ctak
    :group :gabriel
    :long "TAKeuchi function using the catch/throw facility"
    :function 'cl-bench.gabriel:run-ctak
    :runs 300)

(defbench trtak
    :group :gabriel
    :long "TAKeuchi function without tail recursion"
    :function 'cl-bench.gabriel:run-trtak
    :runs 300)

(defbench takl
    :group :gabriel
    :long "TAKeuchi function with lists as counters"
    :function 'cl-bench.gabriel:run-takl
    :runs 100)

(defbench stak
    :group :gabriel
    :long "TAKeuchi function with special variables instead of parameter passing"
    :function 'cl-bench.gabriel:run-stak
    :runs 200)

(defbench fprint/ugly
    :group :gabriel
    :long "Pretty-printer and write operations to file, no *PRINT-PRETTY*"
    :function 'cl-bench.gabriel:fprint/ugly
    :runs 200)

(defbench fprint/pretty
    :group :gabriel
    :long "Pretty-printer and write operations to file, with *PRINT-PRETTY*"
    :function 'cl-bench.gabriel:fprint/pretty
    :runs 100)

(defbench traverse
  :group :gabriel
  :long "Creates and traverses a tree structure"
  :function 'cl-bench.gabriel:run-traverse
  :runs 10)

(defbench triangle
  :group :gabriel
  :long "Puzzle solving (board game) using combinatorial search"
  :function 'cl-bench.gabriel:run-triangle
  :runs 5)

;; end of Gabriel benchmarks

(defbench richards
    :group :misc
    :long "Operating system simulation"
    :function 'cl-bench.richards:richards
    :runs 5)

(defbench factorial
    :group :math
    :function 'cl-bench.math:run-factorial
    :runs 1000)

(defbench fib
    :group :math
    :function 'cl-bench.math:run-fib
    :runs 50)

(defbench fib-ratio
    :group :math
    :function 'cl-bench.math:run-fib-ratio
    :runs 500
    :disabled-for '(:clasp))

(defbench ackermann
    :group :math
    :long "Calculating Ackermann's number (heavy recursion)"
    :function 'cl-bench.math:run-ackermann
    :runs 1
    :disabled-for '(:clisp :genera))

(defbench mandelbrot/complex
    :group :math
    :long "Mandelbrot Set computation using complex numbers"
    :function 'cl-bench.math:run-mandelbrot/complex
    :runs 100
    :disabled-for '(:clasp))

(defbench mandelbrot/dfloat
    :group :math
    :long "Mandelbrot Set computation using double-floats"
    :function 'cl-bench.math:run-mandelbrot/dfloat
    :runs 100)

(defbench mrg32k3a
    :group :math
    :long "multiple recursive random number generator of l'Ecuyer"
    :function 'cl-bench.math:run-mrg32k3a
    :runs 20)

(defbench crc40
    :group :math
    :long "Cyclic redundancy check calculation using 40-bit integers"
    :function 'cl-bench.crc:run-crc40
    :runs 2)

(defbench bignum/elem-100-1000
    :group :bignum
    :function 'cl-bench.bignum:run-elem-100-1000
    :runs 10)

(defbench bignum/elem-1000-100
    :group :bignum
    :function 'cl-bench.bignum:run-elem-1000-100
    :runs 10)

(defbench bignum/elem-10000-1
    :group :bignum
    :function 'cl-bench.bignum:run-elem-10000-1
    :runs 10)

(defbench bignum/pari-100-10
    :group :bignum
    :function 'cl-bench.bignum:run-pari-100-10
    :runs 10)

(defbench bignum/pari-200-5
    :group :bignum
    :function 'cl-bench.bignum:run-pari-200-5
    :runs 10)

;; this one takes ages to run
#+slow-tests
(defbench bignum/pari-1000-1
    :group :bignum
    :short "bignum/pari-1000-1"
    :function 'cl-bench.bignum:run-pari-1000-1
    :runs 1)

(defbench pi-decimal/small
    :group :bignum
    :function 'cl-bench.bignum:run-pi-decimal/small
    :runs 100
    :disabled-for '(:clasp))

(defbench pi-decimal/big
    :group :bignum
    :function 'cl-bench.bignum:run-pi-decimal/big
    :runs 2
    :disabled-for '(:clasp))

(defbench pi-atan
    :group :bignum
    :function 'cl-bench.bignum:run-pi-atan
    :runs 200
    :disabled-for '(:clasp))

(defbench pi-ratios
    :group :bignum
    :function 'cl-bench.ratios:run-pi-ratios
    :runs 2
    :disabled-for '(:clasp))

(defbench hash-strings
    :group :hash
    :function 'cl-bench.hash:hash-strings
    :runs 2)

(defbench hash-integers
    :group :hash
    :function 'cl-bench.hash:hash-integers
    :runs 10)

(defbench slurp-lines
    :group :gc
    :long "Line-by-line read of a large file (mostly testing allocation speed)"
    :function 'cl-bench.hash:run-slurp-lines
    :runs 30)

(defbench boehm-gc
    :group :gc
    :function 'cl-bench.boehm-gc:gc-benchmark
    :runs 1
    :disabled-for '(:lispworks-personal-edition))

(defbench deflate-file
    :group :misc
    :function 'cl-bench.deflate:run-deflate-file
    :runs 100
    :disabled-for '(:clasp))

;; these tests exceed the limited stack size in the trial version of LW
(defbench 1d-arrays
    :group :sequence
    :long "Adding together two vectors"
    :function 'cl-bench.arrays:bench-1d-arrays
    :runs 4
    :disabled-for '(:lispworks-personal-edition))

(defbench 2d-arrays
    :group :sequence
    :long "Adding together two 2-dimensional arrays"
    :function 'cl-bench.arrays:bench-2d-arrays
    :runs 2
    :disabled-for '(:lispworks-personal-edition))

(defbench 3d-arrays
    :group :sequence
    :long "Adding together two 3-dimensional arrays"
    :function 'cl-bench.arrays:bench-3d-arrays
    :runs 1
    :disabled-for '(:lispworks-personal-edition :allegro-cl-express))

;; Poplog seems to have a buggy implementation of bitvectors
(defbench bitvectors
    :group :sequence
    :long "BIT-XOR, BIT-AND on big bitvectors"
    :function 'cl-bench.arrays:bench-bitvectors
    :runs 3
    :disabled-form '(:lispworks-personal-edition :poplog))

(defbench bench-strings
    :group :sequence
    :long "Allocate and fill large strings"
    :function 'cl-bench.arrays:bench-strings
    :runs 3
    :disabled-for '(:lispworks-personal-edition))

(defbench fill-strings/adjust
    :group :sequence
    :short "fill-strings/adjustable"
    :long "Fill an adjustable array with characters"
    :function 'cl-bench.arrays:bench-strings/adjustable
    :runs 1
    :disabled-for '(:lispworks-personal-edition))

;; as of 2002-01-20 this crashes CLISP, both release and CVS versions.
;; It exceeds maximum array size for both Allegro CL and LispWorks.
;; It takes AGES and consumes around 120MB RSS with Poplog
(defbench string-concat
    :group :sequence
    :long "WITH-OUTPUT-TO-STRING and much output"
    :function 'cl-bench.arrays:bench-string-concat
    :runs 1
    :disabled-for '(:allegro :lispworks-personal-edition :poplog :clisp :genera))

(defbench search-sequence
    :group :sequence
    :long "FIND, FIND-IF, POSITION on a simple-vector"
    :function 'cl-bench.arrays:bench-search-sequence
    :runs 2
    :disabled-for '(:lispworks-personal-edition))

(defbench clos-defclass
    :group :clos
    :short "CLOS/defclass"
    :long "Defines a class hierarchy"
    :function 'cl-bench.clos:run-defclass
    :runs 2)

(defbench clos-defmethod
    :group :clos
    :short "CLOS/defmethod"
    :long "Defines methods on the class hierarchy"
    :function 'cl-bench.clos:run-defmethod
    :runs 10)

(defbench clos-instantiate
    :group :clos
    :short "CLOS/instantiate"
    :long "Instantiates a complicated class hierarchy"
    :function 'cl-bench.clos:make-instances
    :runs 4)

(defbench clos-instantiate
    :group :clos
    :short "CLOS/simple-instantiate"
    :long "Instantiates a simple class hierarchy"
    :function 'cl-bench.clos:make-instances/simple
    :runs 100)

(defbench methodcalls
    :group :clos
    :short "CLOS/methodcalls"
    :long "Make method calls against the created instances."
    :function 'cl-bench.clos:methodcalls/simple
    :runs 5)

(defbench methodcalls+after
    :group :clos
    :short "CLOS/method+after"
    :long "Define after methods on our instances, then run some method calls"
    :function 'cl-bench.clos:methodcalls/simple+after
    :disabled-for '(:gcl)
    :runs 5)

(defbench methodcalls/complex
    :group :clos
    :short "CLOS/complex-methods"
    :long "Run methodcalls with and method combination."
    :function 'cl-bench.clos:methodcalls/complex
    :runs 5
    :disabled-for '(:clisp :poplog :gcl))

(defbench eql-specialized-fib
    :group :clos
    :long "Fibonnaci function implemented with EQL specialization"
    :function 'cl-bench.clos:run-eql-fib
    :runs 5
    :disabled-for '(:gcl))

;; EOF
