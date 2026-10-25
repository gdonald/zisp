;;; `subtypep`, `find-class`, and the upgraded element and part types.
;;;
;;; A type specifier is parsed into a canonical type: the universe is cut
;;; into disjoint kinds (keyword symbols, other symbols, integers, ratios,
;;; conses, simple character arrays, the direct instances of one condition
;;; class, and so on), and a canonical type says, kind by kind, which part
;;; of that kind it holds. Union, intersection and complement then work
;;; kind by kind, and `A` is a subtype of `B` exactly when `(and A (not B))`
;;; holds nothing.
;;;
;;; A canonical type is `(default . entries)`. `entries` maps a kind to its
;;; refinement, and a kind it does not mention is wholly in the type when
;;; `default` is true and wholly outside it otherwise.
;;;
;;; A kind is a keyword, except for two families. The direct instances of
;;; a class CLOS defined are the kind keyed by the class object, and the
;;; instances of a structure type the kind keyed by its name. The kinds
;;; `:instance-rest` and `:struct-rest` stand for every member of their
;;; family the entries do not name.
;;;
;;; What a specifier cannot be decided for, such as `satisfies`, parses to
;;; a pair of bounds: a canonical type it surely contains and one it surely
;;; lies within. `subtypep` answers with certainty when the bounds settle
;;; the question, or when what they leave open is a short list of objects
;;; `typep` can be asked about one at a time.

(in-package "COMMON-LISP")

;;; --- kinds ---

(defparameter *%real-kinds* '(:integer :ratio :single-float :double-float))

;; Characters are refined by their codes, so `standard-char` is two
;; intervals rather than ninety-six objects.
(defparameter *%interval-kinds* (append *%real-kinds* '(:base-char :extended-char)))

(defparameter *%float-kinds* '(:single-float :double-float))

(defparameter *%complex-kinds* '(:complex-rational :complex-single :complex-double))

(defparameter *%stream-kinds*
  '(:file-stream :string-stream :synonym-stream :broadcast-stream
    :concatenated-stream :two-way-stream :echo-stream :stream))

(defparameter *%function-kinds* '(:compiled-function :interpreted-function))

(defun %discrete-kind-p (kind)
  (member kind '(:integer :base-char :extended-char)))

(defparameter *%array-kinds*
  '(:simple-array-t :array-t
    :simple-array-character :array-character
    :simple-array-bit :array-bit
    :simple-array-ub8 :array-ub8))

(defparameter *%array-element-kinds*
  '((t :simple-array-t :array-t)
    (character :simple-array-character :array-character)
    (bit :simple-array-bit :array-bit)
    ((unsigned-byte 8) :simple-array-ub8 :array-ub8)))

(defun %kind-class (kind)
  (cond ((member kind *%float-kinds*) :float)
        ((member kind *%interval-kinds*) :interval)
        ((eq kind :cons) :cons)
        ((member kind *%function-kinds*) :signature)
        ((member kind *%array-kinds*) :array)
        (t :simple)))

(defun %array-kinds-of (element-type simple)
  "The kinds holding arrays of upgraded ELEMENT-TYPE, or of every element
type when it is `*`. SIMPLE is :simple, :any or :not-simple."
  (let ((result nil))
    (dolist (row *%array-element-kinds*)
      (when (or (eq element-type '*) (equal element-type (car row)))
        (unless (eq simple :not-simple) (push (cadr row) result))
        (unless (eq simple :simple) (push (caddr row) result))))
    result))

;;; --- interval refinements ---
;;;
;;; A refinement of a numeric kind is a sorted list of disjoint intervals
;;; `(low . high)`. A bound is nil where the interval is unbounded, and
;;; otherwise `(value . open)`, the value always a rational. An integer
;;; interval is kept with closed integer bounds.

(defun %lower< (a b)
  "Whether lower bound A starts before lower bound B."
  (cond ((null a) (not (null b)))
        ((null b) nil)
        ((< (car a) (car b)) t)
        ((> (car a) (car b)) nil)
        (t (and (not (cdr a)) (cdr b)))))

(defun %max-lower (a b)
  (cond ((null a) b)
        ((null b) a)
        ((> (car a) (car b)) a)
        ((< (car a) (car b)) b)
        ((cdr a) a)
        (t b)))

(defun %min-upper (a b)
  (cond ((null a) b)
        ((null b) a)
        ((< (car a) (car b)) a)
        ((> (car a) (car b)) b)
        ((cdr a) a)
        (t b)))

(defun %max-upper (a b)
  (cond ((or (null a) (null b)) nil)
        ((> (car a) (car b)) a)
        ((< (car a) (car b)) b)
        ((cdr a) b)
        (t a)))

(defun %integer-interval (interval)
  "INTERVAL with closed integer bounds, or nil where it holds no integer."
  (let* ((low (car interval))
         (high (cdr interval))
         (low-value (and low (if (and (cdr low) (integerp (car low)))
                                 (1+ (car low))
                                 (ceiling (car low)))))
         (high-value (and high (if (and (cdr high) (integerp (car high)))
                                   (1- (car high))
                                   (floor (car high))))))
    (if (and low-value high-value (> low-value high-value))
        nil
        (cons (and low-value (cons low-value nil))
              (and high-value (cons high-value nil))))))

(defun %interval-empty-p (kind interval)
  (let ((low (car interval))
        (high (cdr interval)))
    (and low high
         (or (> (car low) (car high))
             (and (= (car low) (car high))
                  (or (cdr low) (cdr high)
                      (and (eq kind :ratio) (integerp (car low)))))))))

(defun %interval-normal (kind interval)
  "INTERVAL as KIND keeps it, or nil where KIND has nothing in it."
  (cond ((member kind '(:base-char :extended-char))
         (let ((domain (car (%full-refinement kind))))
           (%integer-interval (cons (%max-lower (car interval) (car domain))
                                    (%min-upper (cdr interval) (cdr domain))))))
        ((eq kind :integer) (%integer-interval interval))
        ((%interval-empty-p kind interval) nil)
        (t interval)))

(defun %intervals-touch-p (kind high next-low)
  (cond ((or (null high) (null next-low)) t)
        ((%discrete-kind-p kind) (<= (car next-low) (1+ (car high))))
        ((< (car next-low) (car high)) t)
        ((> (car next-low) (car high)) nil)
        (t (not (and (cdr high) (cdr next-low))))))

(defun %intervals-normalize (kind intervals)
  (let ((kept nil))
    (dolist (interval intervals)
      (let ((normal (%interval-normal kind interval)))
        (when normal (push normal kept))))
    (setq kept (sort kept #'%lower< :key #'car))
    (let ((result nil))
      (dolist (interval kept)
        (if (and result (%intervals-touch-p kind (cdr (car result)) (car interval)))
            (setf (car result)
                  (cons (car (car result))
                        (%max-upper (cdr (car result)) (cdr interval))))
            (push interval result)))
      (nreverse result))))

(defun %intervals-or (kind a b)
  (%intervals-normalize kind (append a b)))

(defun %intervals-and (kind a b)
  (let ((result nil))
    (dolist (x a)
      (dolist (y b)
        (push (cons (%max-lower (car x) (car y)) (%min-upper (cdr x) (cdr y)))
              result)))
    (%intervals-normalize kind result)))

(defun %flip-bound (bound)
  (cons (car bound) (not (cdr bound))))

(defun %intervals-not (kind intervals)
  (let ((result nil)
        (start nil)
        (in-gap t))
    (dolist (interval intervals)
      (when (and in-gap (car interval))
        (push (cons start (%flip-bound (car interval))) result))
      (if (cdr interval)
          (setq start (%flip-bound (cdr interval))
                in-gap t)
          (setq in-gap nil)))
    (when in-gap
      (push (cons start nil) result))
    (%intervals-normalize kind result)))

(defun %interval-contains-p (interval number)
  (let ((low (car interval))
        (high (cdr interval)))
    (and (or (null low)
             (> number (car low))
             (and (= number (car low)) (not (cdr low))))
         (or (null high)
             (< number (car high))
             (and (= number (car high)) (not (cdr high)))))))

;;; --- wrapped refinements ---
;;;
;;; Every other kind is refined by `(core added removed)`: the objects the
;;; core describes, plus the objects in `added`, less those in `removed`.
;;; That is what lets `(member ...)` name a particular cons or array next
;;; to a description such as `(cons symbol)`. `added` holds only objects
;;; outside the core and `removed` only objects inside it.
;;;
;;; The core of a plain kind is t or nil. The core of the cons kind is a
;;; list of rectangles `(car-type . cdr-type)`, each side a nonempty
;;; canonical type. The core of an array kind is a list of clauses
;;; `(dimensions . excluded)`: the arrays whose dimensions match the first
;;; and none of the second. The core of a function kind is a list of
;;; clauses `(signatures . excluded)`: the functions of every signature in
;;; the first and of none in the second.

(defun %core-full (class)
  (case class
    (:cons (list (cons (%ct-t) (%ct-t))))
    (:array (list (list :any)))
    (:signature (list (cons nil nil)))
    (t t)))

(defun %core-empty-p (core)
  (null core))

;; Rectangles.

(defun %rect-and (a b)
  (let ((car-type (%ct-and (car a) (car b))))
    (if (%ct-empty-p car-type)
        nil
        (let ((cdr-type (%ct-and (cdr a) (cdr b))))
          (if (%ct-empty-p cdr-type) nil (cons car-type cdr-type))))))

(defun %rects-and (a b)
  (let ((result nil))
    (dolist (x a)
      (dolist (y b)
        (let ((both (%rect-and x y)))
          (when both (push both result)))))
    (nreverse result)))

(defun %rect-not (rect)
  "The complement of one rectangle among conses, as two disjoint ones."
  (let ((result nil)
        (not-car (%ct-not (car rect)))
        (not-cdr (%ct-not (cdr rect))))
    (unless (%ct-empty-p not-car) (push (cons not-car (%ct-t)) result))
    (unless (%ct-empty-p not-cdr) (push (cons (car rect) not-cdr) result))
    result))

(defun %rects-not (rects)
  (let ((result (%core-full :cons)))
    (dolist (rect rects)
      (setq result (%rects-and result (%rect-not rect))))
    result))

(defun %rects-contain-p (rects object)
  (some (lambda (rect)
          (and (%ct-contains-p (car rect) (car object))
               (%ct-contains-p (cdr rect) (cdr object))))
        rects))

;; Dimension clauses.

(defun %dims-and (a b)
  "The dimension specs both A and B allow, or :none."
  (cond ((eq a :any) b)
        ((eq b :any) a)
        ((/= (length a) (length b)) :none)
        (t (let ((result nil))
             (loop for x in a
                   for y in b
                   do (cond ((eq x '*) (push y result))
                            ((or (eq y '*) (eql x y)) (push x result))
                            (t (return-from %dims-and :none))))
             (nreverse result)))))

(defun %dims-cover-p (outer inner)
  (cond ((eq outer :any) t)
        ((eq inner :any) nil)
        ((/= (length outer) (length inner)) nil)
        (t (every (lambda (x y) (or (eq x '*) (eql x y))) outer inner))))

(defun %dims-match-p (dims actual)
  (or (eq dims :any)
      (and (= (length dims) (length actual))
           (every (lambda (x y) (or (eq x '*) (eql x y))) dims actual))))

(defun %clause-empty-p (clause)
  (some (lambda (excluded) (%dims-cover-p excluded (car clause))) (cdr clause)))

(defun %clauses-prune (clauses)
  (remove-if #'%clause-empty-p clauses))

(defun %clauses-and (a b)
  (let ((result nil))
    (dolist (x a)
      (dolist (y b)
        (let ((dims (%dims-and (car x) (car y))))
          (unless (eq dims :none)
            (push (cons dims (append (cdr x) (cdr y))) result)))))
    (%clauses-prune (nreverse result))))

(defun %clauses-not (clauses)
  (let ((result (%core-full :array)))
    (dolist (clause clauses)
      (setq result
            (%clauses-and result
                          (cons (list :any (car clause))
                                (mapcar #'list (cdr clause))))))
    result))

(defun %clauses-contain-p (clauses object)
  (let ((actual (array-dimensions object)))
    (some (lambda (clause)
            (and (%dims-match-p (car clause) actual)
                 (notany (lambda (excluded) (%dims-match-p excluded actual))
                         (cdr clause))))
          clauses)))

;; Signature clauses. A signature is `(arguments . values)` as a compound
;; `function` type gives them.

(defun %lambda-keyword-p (x)
  (member x lambda-list-keywords))

(defun %subtype-certainly-p (type-1 type-2)
  (multiple-value-bind (subtype-p certain-p) (subtypep type-1 type-2)
    (and subtype-p certain-p)))

(defun %arguments-cover-p (outer inner)
  "Whether every function taking INNER arguments takes OUTER ones: each
required argument OUTER allows, INNER allows too."
  (cond ((%wild-p outer) t)
        ((%wild-p inner) nil)
        ((or (some #'%lambda-keyword-p outer) (some #'%lambda-keyword-p inner))
         (equal outer inner))
        ((/= (length outer) (length inner)) nil)
        (t (every #'%subtype-certainly-p outer inner))))

(defun %values-cover-p (outer inner)
  (cond ((%wild-p outer) t)
        ((%wild-p inner) nil)
        ((or (and (consp outer) (eq (car outer) 'values))
             (and (consp inner) (eq (car inner) 'values)))
         (equal outer inner))
        (t (%subtype-certainly-p inner outer))))

(defun %signature-covers-p (outer inner)
  (and (%arguments-cover-p (car outer) (car inner))
       (%values-cover-p (cdr outer) (cdr inner))))

(defun %signature-clause-empty-p (clause)
  (let ((required (or (car clause) (list (cons '* '*)))))
    (some (lambda (excluded)
            (some (lambda (signature) (%signature-covers-p excluded signature)) required))
          (cdr clause))))

(defun %signature-clauses-and (a b)
  (let ((result nil))
    (dolist (x a)
      (dolist (y b)
        (let ((clause (cons (append (car x) (car y)) (append (cdr x) (cdr y)))))
          (unless (%signature-clause-empty-p clause)
            (push clause result)))))
    (nreverse result)))

(defun %signature-clauses-not (clauses)
  (let ((result (%core-full :signature)))
    (dolist (clause clauses)
      (setq result
            (%signature-clauses-and
             result
             (append (mapcar (lambda (signature) (cons nil (list signature))) (car clause))
                     (mapcar (lambda (signature) (cons (list signature) nil)) (cdr clause))))))
    result))

(defun %signature-clauses-contain-p (clauses)
  "Whether a function object is in CLAUSES. No signature is known for
one, so it is in a clause that asks for no signature, whatever the clause
excludes."
  (some (lambda (clause) (null (car clause))) clauses))

;; The core operations, by class.

(defun %core-or (class a b)
  (case class
    (:simple (or a b))
    (t (append a b))))

(defun %core-and (class a b)
  (case class
    (:simple (and a b))
    (:cons (%rects-and a b))
    (:signature (%signature-clauses-and a b))
    (t (%clauses-and a b))))

(defun %core-not (class core)
  (case class
    (:simple (not core))
    (:cons (%rects-not core))
    (:signature (%signature-clauses-not core))
    (t (%clauses-not core))))

(defun %core-contains-p (class core object)
  (case class
    (:simple core)
    (:cons (%rects-contain-p core object))
    (:signature (%signature-clauses-contain-p core))
    (t (%clauses-contain-p core object))))

;; Wrapped refinement operations.

(defun %wrapped-contains-p (class refinement object)
  (or (member object (cadr refinement) :test #'eql)
      (and (%core-contains-p class (car refinement) object)
           (not (member object (caddr refinement) :test #'eql)))))

(defun %wrapped-or (class a b)
  (let* ((core (%core-or class (car a) (car b)))
         (added (remove-if (lambda (object) (%core-contains-p class core object))
                           (union (cadr a) (cadr b))))
         (removed (remove-if-not
                   (lambda (object) (%core-contains-p class core object))
                   (union (remove-if (lambda (object) (%wrapped-contains-p class b object))
                                     (caddr a))
                          (remove-if (lambda (object) (%wrapped-contains-p class a object))
                                     (caddr b))))))
    (list core added removed)))

(defun %wrapped-not (class refinement)
  (list (%core-not class (car refinement)) (caddr refinement) (cadr refinement)))

(defun %wrapped-and (class a b)
  (%wrapped-not class (%wrapped-or class (%wrapped-not class a) (%wrapped-not class b))))

(defun %wrapped-empty-p (refinement)
  (and (%core-empty-p (car refinement)) (null (cadr refinement))))

;;; --- float refinements ---
;;;
;;; A float kind is refined by `(intervals negative-zero positive-zero)`.
;;; The intervals say which nonzero floats are in, and the two flags say
;;; whether -0.0 and 0.0 are, since `(member 0.0)` holds one and not the
;;; other where an interval reaching zero holds both.

(defun %float-range (low high)
  (let* ((intervals (%intervals-normalize :float (list (cons low high))))
         (zero (some (lambda (interval) (%interval-contains-p interval 0)) intervals)))
    (list intervals zero zero)))

(defun %float-empty-p (refinement)
  (and (not (cadr refinement))
       (not (caddr refinement))
       (every (lambda (interval)
                (and (car interval) (cdr interval)
                     (= 0 (car (car interval)) (car (cdr interval)))))
              (car refinement))))

(defun %float-contains-p (refinement object)
  (if (zerop object)
      (if (minusp (float-sign object)) (cadr refinement) (caddr refinement))
      (let ((number (rational object)))
        (some (lambda (interval) (%interval-contains-p interval number))
              (car refinement)))))

;;; --- refinements of any kind ---

(defun %full-refinement (kind)
  (let ((class (%kind-class kind)))
    (cond ((eq class :float) (list (list (cons nil nil)) t t))
          ((eq kind :base-char) (list (cons (cons 0 nil) (cons 255 nil))))
          ((eq kind :extended-char) (list (cons (cons 256 nil) (cons (1- char-code-limit) nil))))
          ((eq class :interval) (list (cons nil nil)))
          (t (list (%core-full class) nil nil)))))

(defun %empty-refinement (kind)
  (case (%kind-class kind)
    (:interval nil)
    (t (list nil nil nil))))

(defun %refinement-or (kind a b)
  (case (%kind-class kind)
    (:interval (%intervals-or kind a b))
    (:float (list (%intervals-or :float (car a) (car b))
                  (or (cadr a) (cadr b))
                  (or (caddr a) (caddr b))))
    (t (%wrapped-or (%kind-class kind) a b))))

(defun %refinement-and (kind a b)
  (case (%kind-class kind)
    (:interval (%intervals-and kind a b))
    (:float (list (%intervals-and :float (car a) (car b))
                  (and (cadr a) (cadr b))
                  (and (caddr a) (caddr b))))
    (t (%wrapped-and (%kind-class kind) a b))))

(defun %refinement-not (kind refinement)
  (case (%kind-class kind)
    (:interval (%intervals-not kind refinement))
    (:float (list (%intervals-not :float (car refinement))
                  (not (cadr refinement))
                  (not (caddr refinement))))
    (t (%wrapped-not (%kind-class kind) refinement))))

(defun %refinement-empty-p (kind refinement)
  (case (%kind-class kind)
    (:interval (null refinement))
    (:float (%float-empty-p refinement))
    (t (%wrapped-empty-p refinement))))

(defun %refinement-contains-p (kind refinement object)
  (case (%kind-class kind)
    (:interval
     (let ((number (if (characterp object) (char-code object) (rational object))))
       (some (lambda (interval) (%interval-contains-p interval number)) refinement)))
    (:float (%float-contains-p refinement object))
    (t (%wrapped-contains-p (%kind-class kind) refinement object))))

;;; --- canonical types ---

(defun %ct-t () (list t))
(defun %ct-nil () (list nil))

(defun %ct-of (kind refinement)
  (list nil (cons kind refinement)))

(defun %ct-full-kinds (kinds)
  (cons nil (mapcar (lambda (kind) (cons kind (%full-refinement kind))) kinds)))

(defun %family-rest (kind)
  (cond ((keywordp kind) nil)
        ((symbolp kind) :struct-rest)
        (t :instance-rest)))

(defun %ct-lookup (ctype kind)
  (let ((entry (assoc kind (cdr ctype))))
    (if entry
        (cdr entry)
        (let* ((family (%family-rest kind))
               (rest (and family (assoc family (cdr ctype)))))
          (cond (rest (cdr rest))
                ((car ctype) (%full-refinement kind))
                (t (%empty-refinement kind)))))))

(defun %ct-kinds (a b)
  (let ((kinds (mapcar #'car (cdr a))))
    (dolist (entry (cdr b))
      (pushnew (car entry) kinds))
    kinds))

(defun %ct-combine (a b default refine)
  (cons default
        (mapcar (lambda (kind)
                  (cons kind (funcall refine kind (%ct-lookup a kind) (%ct-lookup b kind))))
                (%ct-kinds a b))))

(defun %ct-or (a b)
  (%ct-combine a b (or (car a) (car b)) #'%refinement-or))

(defun %ct-and (a b)
  (%ct-combine a b (and (car a) (car b)) #'%refinement-and))

(defun %ct-not (ctype)
  (cons (not (car ctype))
        (mapcar (lambda (entry)
                  (cons (car entry) (%refinement-not (car entry) (cdr entry))))
                (cdr ctype))))

(defun %ct-empty-p (ctype)
  (and (not (car ctype))
       (every (lambda (entry) (%refinement-empty-p (car entry) (cdr entry)))
              (cdr ctype))))

(defun %ct-contains-p (ctype object)
  (let ((kind (%kind-of object)))
    (%refinement-contains-p kind (%ct-lookup ctype kind) object)))

;;; --- the kind of an object ---

(defun %array-kind-of (object)
  (let* ((element-type (array-element-type object))
         (simple (and (not (adjustable-array-p object))
                      (not (array-has-fill-pointer-p object))
                      (null (array-displacement object))))
         (row (assoc element-type *%array-element-kinds* :test #'equal)))
    (if simple (cadr row) (caddr row))))

(defun %complex-kind-of (object)
  (let ((part (realpart object)))
    (cond ((rationalp part) :complex-rational)
          ((typep part 'single-float) :complex-single)
          (t :complex-double))))

(defun %kind-of (object)
  (cond ((%instance-p object) (%instance-class object))
        ((symbolp object) (if (keywordp object) :keyword :symbol))
        ((integerp object) :integer)
        ((rationalp object) :ratio)
        ((typep object 'single-float) :single-float)
        ((floatp object) :double-float)
        ((complexp object) (%complex-kind-of object))
        ((characterp object) (if (< (char-code object) 256) :base-char :extended-char))
        ((consp object) :cons)
        ((arrayp object) (%array-kind-of object))
        ((%structure-p object) (%structure-name object))
        ((hash-table-p object) :hash-table)
        ((functionp object) (if (compiled-function-p object) :compiled-function :interpreted-function))
        ((packagep object) :package)
        ((typep object 'logical-pathname) :logical-pathname)
        ((pathnamep object) :pathname)
        ((typep object 'file-stream) :file-stream)
        ((typep object 'string-stream) :string-stream)
        ((streamp object) :stream)
        ((random-state-p object) :random-state)
        ((readtablep object) :readtable)
        (t :other)))

(defun %ct-member (objects)
  "The canonical type holding exactly OBJECTS."
  (let ((result (%ct-nil)))
    (dolist (object objects)
      (let* ((kind (%kind-of object))
             (refinement
               (case (%kind-class kind)
                 (:interval
                  (let ((bound (cons (if (characterp object)
                                         (char-code object)
                                         (rational object))
                                     nil)))
                    (list (cons bound bound))))
                 (:float
                  (cond ((not (zerop object))
                         (let ((bound (cons (rational object) nil)))
                           (list (list (cons bound bound)) nil nil)))
                        ((minusp (float-sign object)) (list nil t nil))
                        (t (list nil nil t))))
                 (t (list nil (list object) nil)))))
        (setq result (%ct-or result (%ct-of kind refinement)))))
    result))

;;; --- named types ---

(defun %ct-interval (kinds low high)
  (let ((result (%ct-nil)))
    (dolist (kind kinds)
      (let ((refinement (if (eq (%kind-class kind) :float)
                            (%float-range low high)
                            (%intervals-normalize kind (list (cons low high))))))
        (setq result (%ct-or result (%ct-of kind refinement)))))
    result))

(defun %ct-arrays (kinds dims)
  (let ((result (%ct-nil)))
    (dolist (kind kinds)
      (setq result (%ct-or result (%ct-of kind (list (list (cons dims nil)) nil nil)))))
    result))

(defun %ct-vectors (kinds) (%ct-arrays kinds (list '*)))

(defun %fixnum-bound (value) (cons value nil))

(defun %ct-fixnum ()
  (%ct-interval '(:integer)
                (%fixnum-bound most-negative-fixnum)
                (%fixnum-bound most-positive-fixnum)))

(defvar *%class-ctypes* (make-hash-table :test #'eq))

;; Classes no object is made a direct instance of. Leaving them out of
;; the kinds lets their subclasses stand for them, which is what makes
;; `(and function standard-object)` a subtype of `generic-function`.
(defparameter *%abstract-classes* '(funcallable-standard-object))

(defun %class-descendants (class)
  "CLASS and every class below it, leaving out built-in classes, whose
instances are kinds of their own, and the classes with no direct
instances."
  (let ((found nil)
        (seen nil)
        (built-in (find-class 'built-in-class))
        (abstract (mapcar #'find-class *%abstract-classes*)))
    (labels ((walk (c)
               (unless (%memq c seen)
                 (push c seen)
                 (unless (or (eq (%instance-class c) built-in) (%memq c abstract))
                   (push c found))
                 (dolist (sub (%class-ref c direct-subclasses)) (walk sub)))))
      (walk class))
    found))

(defun %ct-clos-class (class)
  "The instances of CLASS and of every class known now to descend from
it. Each is built once for each state of the class hierarchy."
  (let ((cached (gethash class *%class-ctypes*)))
    (if (and cached (eql (car cached) *%class-epoch*))
        (cdr cached)
        (cdr (setf (gethash class *%class-ctypes*)
                   (cons *%class-epoch* (%ct-full-kinds (%class-descendants class))))))))

(defvar *%named-ctypes* (make-hash-table :test #'eq))

(defun %ct-named (name)
  "The canonical type of the standard type NAME, or nil where NAME is not
one this file knows. Each is built once."
  (multiple-value-bind (ctype found) (gethash name *%named-ctypes*)
    (if found
        ctype
        (setf (gethash name *%named-ctypes*) (%ct-build-named name)))))

(defun %ct-build-named (name)
  (case name
    ((nil) (%ct-nil))
    ((t) (%ct-t))
    (symbol (%ct-full-kinds '(:symbol :keyword)))
    (keyword (%ct-full-kinds '(:keyword)))
    (null (%ct-member '(nil)))
    (boolean (%ct-member '(nil t)))
    (cons (%ct-full-kinds '(:cons)))
    (list (%ct-or (%ct-full-kinds '(:cons)) (%ct-member '(nil))))
    (atom (%ct-not (%ct-full-kinds '(:cons))))
    (integer (%ct-full-kinds '(:integer)))
    (fixnum (%ct-fixnum))
    (bignum (%ct-and (%ct-full-kinds '(:integer)) (%ct-not (%ct-fixnum))))
    (bit (%ct-interval '(:integer) (cons 0 nil) (cons 1 nil)))
    (unsigned-byte (%ct-interval '(:integer) (cons 0 nil) nil))
    (signed-byte (%ct-full-kinds '(:integer)))
    (ratio (%ct-full-kinds '(:ratio)))
    (rational (%ct-full-kinds '(:integer :ratio)))
    ((single-float short-float) (%ct-full-kinds '(:single-float)))
    ((double-float long-float) (%ct-full-kinds '(:double-float)))
    (float (%ct-full-kinds '(:single-float :double-float)))
    (real (%ct-full-kinds *%real-kinds*))
    (complex (%ct-full-kinds *%complex-kinds*))
    (number (%ct-full-kinds (append *%real-kinds* *%complex-kinds*)))
    (character (%ct-full-kinds '(:base-char :extended-char)))
    (base-char (%ct-full-kinds '(:base-char)))
    (extended-char (%ct-full-kinds '(:extended-char)))
    (standard-char (%ct-of :base-char (list (cons (cons 10 nil) (cons 10 nil))
                                            (cons (cons 32 nil) (cons 126 nil)))))
    (array (%ct-full-kinds *%array-kinds*))
    (simple-array (%ct-full-kinds (%array-kinds-of '* :simple)))
    (vector (%ct-vectors *%array-kinds*))
    (simple-vector (%ct-vectors '(:simple-array-t)))
    ((string base-string) (%ct-vectors (%array-kinds-of 'character :any)))
    ((simple-string simple-base-string) (%ct-vectors (%array-kinds-of 'character :simple)))
    (bit-vector (%ct-vectors (%array-kinds-of 'bit :any)))
    (simple-bit-vector (%ct-vectors (%array-kinds-of 'bit :simple)))
    (sequence (%ct-or (%ct-named 'list) (%ct-vectors *%array-kinds*)))
    (hash-table (%ct-full-kinds '(:hash-table)))
    (function (%ct-full-kinds *%function-kinds*))
    (compiled-function (%ct-full-kinds '(:compiled-function)))
    (package (%ct-full-kinds '(:package)))
    (pathname (%ct-full-kinds '(:pathname :logical-pathname)))
    (logical-pathname (%ct-full-kinds '(:logical-pathname)))
    (stream (%ct-full-kinds *%stream-kinds*))
    (file-stream (%ct-full-kinds '(:file-stream)))
    (string-stream (%ct-full-kinds '(:string-stream)))
    (synonym-stream (%ct-full-kinds '(:synonym-stream)))
    (broadcast-stream (%ct-full-kinds '(:broadcast-stream)))
    (concatenated-stream (%ct-full-kinds '(:concatenated-stream)))
    (two-way-stream (%ct-full-kinds '(:two-way-stream)))
    (echo-stream (%ct-full-kinds '(:echo-stream)))
    (random-state (%ct-full-kinds '(:random-state)))
    (readtable (%ct-full-kinds '(:readtable)))
    (structure-object (%ct-full-kinds (list :struct-rest)))
    (t nil)))

;;; --- parsing ---
;;;
;;; A parse is `(lower . upper)`. Where the specifier is decided exactly
;;; the two are the same object.

(defun %exact (ctype) (cons ctype ctype))

(defun %bounded (lower upper) (cons lower upper))

(defun %unknown () (%bounded (%ct-nil) (%ct-t)))

(defun %parse-map (function parse)
  (if (eq (car parse) (cdr parse))
      (%exact (funcall function (car parse)))
      (%bounded (funcall function (car parse)) (funcall function (cdr parse)))))

(defun %parse-map2 (function a b)
  (if (and (eq (car a) (cdr a)) (eq (car b) (cdr b)))
      (%exact (funcall function (car a) (car b)))
      (%bounded (funcall function (car a) (car b))
                (funcall function (cdr a) (cdr b)))))

(defun %parse-not (parse)
  (if (eq (car parse) (cdr parse))
      (%exact (%ct-not (car parse)))
      (%bounded (%ct-not (cdr parse)) (%ct-not (car parse)))))

(defun %wild-p (x) (eq x '*))

(defun %numeric-bound (spec)
  (cond ((or (null spec) (%wild-p spec)) nil)
        ((consp spec) (cons (rational (car spec)) t))
        (t (cons (rational spec) nil))))

(defun %numeric-kinds (head)
  (case head
    (integer '(:integer))
    (rational '(:integer :ratio))
    (real *%real-kinds*)
    (float '(:single-float :double-float))
    ((single-float short-float) '(:single-float))
    ((double-float long-float) '(:double-float))
    (t nil)))

(defun %parse-byte (unsigned size)
  (if (or (null size) (%wild-p size))
      (%exact (%ct-named (if unsigned 'unsigned-byte 'signed-byte)))
      (let ((limit (expt 2 (if unsigned size (1- size)))))
        (%exact (%ct-interval '(:integer)
                              (cons (if unsigned 0 (- limit)) nil)
                              (cons (1- limit) nil))))))

(defun %parse-complex (args)
  "A complex type holds the complexes whose parts are of the type its own
part type upgrades to."
  (if (or (null args) (%wild-p (car args)))
      (%exact (%ct-named 'complex))
      (%exact (%ct-full-kinds
               (case (upgraded-complex-part-type (car args))
                 (rational '(:complex-rational))
                 (single-float '(:complex-single))
                 (double-float '(:complex-double))
                 (float '(:complex-single :complex-double))
                 (t *%complex-kinds*))))))

(defun %parse-cons (args)
  (let ((car-parse (if (or (null args) (%wild-p (car args)))
                       (%exact (%ct-t))
                       (%parse (car args))))
        (cdr-parse (if (or (null (cdr args)) (%wild-p (cadr args)))
                       (%exact (%ct-t))
                       (%parse (cadr args)))))
    (%parse-map2
     (lambda (car-type cdr-type)
       (if (or (%ct-empty-p car-type) (%ct-empty-p cdr-type))
           (%ct-nil)
           (%ct-of :cons (list (list (cons car-type cdr-type)) nil nil))))
     car-parse cdr-parse)))

(defun %dims-spec (dims)
  (cond ((%wild-p dims) :any)
        ((integerp dims) (make-list dims :initial-element '*))
        (t dims)))

(defun %element-kinds (element-type simple)
  (%array-kinds-of (if (%wild-p element-type)
                       '*
                       (upgraded-array-element-type element-type))
                   simple))

(defun %parse-array (head args)
  (let ((element (if args (car args) '*))
        (second (if (cdr args) (cadr args) '*)))
    (case head
      (array (%exact (%ct-arrays (%element-kinds element :any) (%dims-spec second))))
      (simple-array (%exact (%ct-arrays (%element-kinds element :simple) (%dims-spec second))))
      (vector (%exact (%ct-arrays (%element-kinds element :any) (list second))))
      (t
       (let ((size element))
         (%exact (%ct-arrays
                  (case head
                    (simple-vector '(:simple-array-t))
                    ((string base-string) (%array-kinds-of 'character :any))
                    ((simple-string simple-base-string) (%array-kinds-of 'character :simple))
                    (bit-vector (%array-kinds-of 'bit :any))
                    (simple-bit-vector (%array-kinds-of 'bit :simple)))
                  (list size))))))))

(defun %parse-symbol (spec)
  (let ((named (%ct-named spec)))
    (cond ((and named (%memq spec '(function compiled-function)))
           (%exact (%ct-or named (%ct-clos-class (find-class 'function)))))
          (named (%exact named))
          ((get spec '%structure-slots)
           (%exact (%ct-full-kinds (let ((class (find-class spec nil)))
                                     (if class
                                         (mapcar (lambda (c) (%class-ref c name))
                                                 (%class-descendants class))
                                         (list spec))))))
          ((find-class spec nil) (%exact (%ct-clos-class (find-class spec))))
          ((get spec '%deftype-expander)
           (%parse (funcall (get spec '%deftype-expander) nil)))
          (t (%unknown)))))

(defun %parse-function (args)
  (if (and (or (null args) (%wild-p (car args)))
           (or (null (cdr args)) (%wild-p (cadr args))))
      (%exact (%ct-named 'function))
      (let ((signature (cons (if args (car args) '*) (if (cdr args) (cadr args) '*)))
            (result (%ct-nil)))
        (dolist (kind *%function-kinds*)
          (setq result (%ct-or result (%ct-of kind (list (list (cons (list signature) nil))
                                                        nil nil)))))
        (%exact result))))

;; The standard predicates that hold of exactly the objects of a type.
(defparameter *%type-predicates*
  '((symbolp . symbol) (keywordp . keyword) (null . null) (consp . cons)
    (listp . list) (atom . atom) (numberp . number) (integerp . integer)
    (rationalp . rational) (realp . real) (floatp . float) (complexp . complex)
    (characterp . character) (stringp . string) (simple-string-p . simple-string)
    (vectorp . vector) (simple-vector-p . simple-vector) (arrayp . array)
    (bit-vector-p . bit-vector) (simple-bit-vector-p . simple-bit-vector)
    (functionp . function) (compiled-function-p . compiled-function)
    (hash-table-p . hash-table) (packagep . package) (pathnamep . pathname)
    (streamp . stream) (random-state-p . random-state) (readtablep . readtable)))

(defun %parse-satisfies (predicate)
  (let ((type (cdr (assoc predicate *%type-predicates*))))
    (if type (%parse type) (%unknown))))

(defun %parse-combination (head args)
  (let ((result (%exact (if (eq head 'and) (%ct-t) (%ct-nil))))
        (combine (if (eq head 'and) #'%ct-and #'%ct-or)))
    (dolist (arg args)
      (setq result (%parse-map2 combine result (%parse arg))))
    result))

(defun %parse-compound (spec)
  (let ((head (car spec))
        (args (cdr spec)))
    (cond ((member head '(and or)) (%parse-combination head args))
          ((eq head 'not) (%parse-not (%parse (car args))))
          ((eq head 'member) (%exact (%ct-member args)))
          ((eq head 'eql) (%exact (%ct-member (list (car args)))))
          ((eq head 'satisfies) (%parse-satisfies (car args)))
          ((%numeric-kinds head)
           (%exact (%ct-interval (%numeric-kinds head)
                                 (%numeric-bound (car args))
                                 (%numeric-bound (cadr args)))))
          ((eq head 'mod)
           (%exact (%ct-interval '(:integer) (cons 0 nil) (cons (car args) t))))
          ((eq head 'unsigned-byte) (%parse-byte t (car args)))
          ((eq head 'signed-byte) (%parse-byte nil (car args)))
          ((eq head 'complex) (%parse-complex args))
          ((eq head 'cons) (%parse-cons args))
          ((member head '(array simple-array vector simple-vector string base-string
                          simple-string simple-base-string bit-vector simple-bit-vector))
           (%parse-array head args))
          ((eq head 'function) (%parse-function args))
          ((and (symbolp head) (get head '%deftype-expander))
           (%parse (funcall (get head '%deftype-expander) args)))
          (t (%unknown)))))

(defun %parse-class-object (class)
  "A class as a type specifier: its name's type where the name is proper,
and the instances of it and its subclasses otherwise."
  (let ((name (%class-ref class name)))
    (if (and name (symbolp name) (eq (find-class name nil) class))
        (%parse name)
        (%exact (%ct-clos-class class)))))

(defun %parse (spec)
  (cond ((symbolp spec) (%parse-symbol spec))
        ((consp spec) (%parse-compound spec))
        ((%class-p spec) (%parse-class-object spec))
        (t (%unknown))))

;;; --- the interface ---

(defparameter *%finite-limit* 64)

(defun %interval-objects (kind intervals)
  (let ((result nil))
    (dolist (interval intervals result)
      (let ((low (car interval))
            (high (cdr interval)))
        (unless (and low high) (return :infinite))
        (cond ((eq kind :ratio)
               (unless (= (car low) (car high)) (return :infinite))
               (push (car low) result))
              ((> (- (car high) (car low)) *%finite-limit*) (return :infinite))
              (t (loop for value from (car low) to (car high)
                       do (push (if (eq kind :integer) value (code-char value)) result))))))))

(defun %float-objects (kind refinement)
  (let ((prototype (if (eq kind :single-float) 1.0 1.0d0))
        (result nil))
    (when (cadr refinement) (push (- (float 0 prototype)) result))
    (when (caddr refinement) (push (float 0 prototype) result))
    (dolist (interval (car refinement) result)
      (let ((low (car interval))
            (high (cdr interval)))
        (unless (and low high (= (car low) (car high))) (return :infinite))
        (unless (zerop (car low))
          (push (float (car low) prototype) result))))))

(defun %refinement-objects (kind refinement)
  "The objects REFINEMENT holds, or :infinite where it holds more than a
short list of them."
  (case (%kind-class kind)
    (:interval (%interval-objects kind refinement))
    (:float (%float-objects kind refinement))
    (t (if (%core-empty-p (car refinement)) (cadr refinement) :infinite))))

(defun %ct-objects (ctype)
  (if (car ctype)
      :infinite
      (let ((result nil))
        (dolist (entry (cdr ctype) result)
          (let ((objects (%refinement-objects (car entry) (cdr entry))))
            (when (eq objects :infinite) (return :infinite))
            (setq result (append objects result)))))))

(defun %decide-by-objects (objects type-1 type-2)
  "Settle whether TYPE-1 is a subtype of TYPE-2 by asking `typep` of each
of OBJECTS, the only objects the answer could turn on."
  (if (eq objects :infinite)
      (values nil nil)
      (let ((unknown nil))
        (dolist (object objects)
          (case (handler-case (and (typep object type-1) (not (typep object type-2)))
                  (error () :unknown))
            (:unknown (setq unknown t))
            ((nil))
            (t (return-from %decide-by-objects (values nil t)))))
        (if unknown (values nil nil) (values t t)))))

(defun subtypep (type-1 type-2 &optional environment)
  (declare (ignore environment))
  (let* ((a (%parse type-1))
         (b (%parse type-2))
         (possible (%ct-and (cdr a) (%ct-not (car b)))))
    (cond ((%ct-empty-p possible) (values t t))
          ((not (%ct-empty-p (%ct-and (car a) (%ct-not (cdr b))))) (values nil t))
          (t (%decide-by-objects (%ct-objects possible) type-1 type-2)))))

(defvar *%upgraded-element-types* (make-hash-table :test #'equal))

(defun upgraded-array-element-type (typespec &optional environment)
  (declare (ignore environment))
  (multiple-value-bind (upgraded found) (gethash typespec *%upgraded-element-types*)
    (if found
        upgraded
        (setf (gethash typespec *%upgraded-element-types*)
              (cond ((subtypep typespec 'bit) 'bit)
                    ((subtypep typespec '(unsigned-byte 8)) '(unsigned-byte 8))
                    ((subtypep typespec 'character) 'character)
                    (t t))))))

(defvar *%upgraded-part-types* (make-hash-table :test #'equal))

(defun upgraded-complex-part-type (typespec &optional environment)
  (declare (ignore environment))
  (multiple-value-bind (upgraded found) (gethash typespec *%upgraded-part-types*)
    (if found
        upgraded
        (setf (gethash typespec *%upgraded-part-types*)
              (cond ((subtypep typespec 'rational) 'rational)
                    ((subtypep typespec 'single-float) 'single-float)
                    ((subtypep typespec 'double-float) 'double-float)
                    ((subtypep typespec 'float) 'float)
                    (t 'real))))))

(export '(subtypep upgraded-array-element-type upgraded-complex-part-type
          keyword boolean atom fixnum bignum bit unsigned-byte signed-byte ratio
          short-float single-float double-float long-float extended-char
          standard-char base-char simple-array simple-vector base-string
          simple-string simple-base-string bit-vector simple-bit-vector sequence
          compiled-function logical-pathname random-state structure-object
          file-stream string-stream synonym-stream broadcast-stream
          concatenated-stream two-way-stream echo-stream mod satisfies member eql
          built-in-class class structure-class standard-class standard-object
          generic-function standard-generic-function method standard-method
          method-combination))

(in-package "COMMON-LISP-USER")
