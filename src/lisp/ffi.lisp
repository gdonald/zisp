;;;; The foreign function interface: C types, `defcfun`, foreign memory.
;;;;
;;;; The natives it is built on take and give addresses as integers. A
;;;; pointer here is a `foreign-pointer` holding one. The functions are
;;;; exported from ZISP-FFI, nicknamed FFI.

(in-package "COMMON-LISP")

(defstruct (foreign-pointer (:constructor make-pointer (address))
                            (:predicate pointerp)
                            (:copier nil))
  (address 0 :type (integer 0) :read-only t))

(defmethod print-object ((pointer foreign-pointer) stream)
  (print-unreadable-object (pointer stream :type t)
    (format stream "#x~x" (foreign-pointer-address pointer))))

(defun pointer-address (pointer) (foreign-pointer-address pointer))

(defun null-pointer () (make-pointer 0))

(defun null-pointer-p (pointer) (zerop (foreign-pointer-address pointer)))

(defun inc-pointer (pointer offset)
  (make-pointer (+ (foreign-pointer-address pointer) offset)))

(defun pointer-eq (a b)
  (= (foreign-pointer-address a) (foreign-pointer-address b)))

;;; Types

(defparameter *%foreign-type-sizes*
  '((:char . 1) (:unsigned-char . 1) (:short . 2) (:unsigned-short . 2)
    (:int . 4) (:unsigned-int . 4) (:long . 8) (:unsigned-long . 8)
    (:long-long . 8) (:unsigned-long-long . 8) (:pointer . 8) (:string . 8)
    (:float . 4) (:double . 8) (:void . 0)))

(defvar *%foreign-type-aliases* (make-hash-table))

(defun %define-foreign-type-alias (name base)
  (canonical-foreign-type base)
  (setf (gethash name *%foreign-type-aliases*) base)
  name)

(defmacro defctype (name base)
  `(%define-foreign-type-alias ',name ',base))

(defun canonical-foreign-type (type)
  "The base C type TYPE names, through any aliases."
  (cond ((assoc type *%foreign-type-sizes*) type)
        ((nth-value 1 (gethash type *%foreign-type-aliases*))
         (canonical-foreign-type (gethash type *%foreign-type-aliases*)))
        (t (error 'type-error :datum type :expected-type 'foreign-type))))

(defun foreign-type-size (type)
  (if (%struct-type-p type)
      (%foreign-struct-size (%foreign-struct type))
      (cdr (assoc (canonical-foreign-type type) *%foreign-type-sizes*))))

(defun foreign-type-alignment (type)
  (if (%struct-type-p type)
      (%foreign-struct-alignment (%foreign-struct type))
      (max 1 (foreign-type-size type))))

;;; Structures

(defstruct (%foreign-struct (:copier nil))
  name
  slots
  (size 0)
  (alignment 1))

;; One field: its name, type, how many of the type, and its offset.
(defstruct (%foreign-slot (:copier nil))
  name type (count 1) (offset 0))

(defvar *%foreign-structs* (make-hash-table))

(defun %struct-type-p (type)
  (and (consp type) (eq (first type) :struct)))

(defun %foreign-struct (type)
  (let ((name (if (%struct-type-p type) (second type) type)))
    (or (gethash name *%foreign-structs*)
        (error 'type-error :datum type :expected-type 'foreign-struct))))

(defun %round-up (n alignment)
  (* alignment (ceiling n alignment)))

(defun %layout-foreign-struct (name fields)
  "The layout C gives a structure with FIELDS, each a list of a name, a
type and optionally :count: each field at the next offset its type's
alignment allows, and the size rounded up to the largest alignment."
  (let ((offset 0) (alignment 1) (slots nil))
    (dolist (field fields)
      (destructuring-bind (slot-name type &key (count 1)) field
        (let ((type (if (%struct-type-p type) type (canonical-foreign-type type)))
              (slot-alignment (foreign-type-alignment type)))
          (setq offset (%round-up offset slot-alignment)
                alignment (max alignment slot-alignment))
          (push (make-%foreign-slot :name slot-name :type type :count count :offset offset) slots)
          (incf offset (* count (foreign-type-size type))))))
    (make-%foreign-struct :name name :slots (nreverse slots)
                          :size (%round-up offset alignment) :alignment alignment)))

(defmacro defcstruct (name &rest fields)
  "Define the C structure NAME, written (:struct NAME) as a type. Each
field is a list of its name and type, then :count for an array."
  `(progn
     (setf (gethash ',name *%foreign-structs*) (%layout-foreign-struct ',name ',fields))
     ',name))

(defun %c-type-for-slot-type (type)
  "The C type a structure slot declared TYPE is laid out as."
  (flet ((sized (bits signed)
           (case bits
             (8 (if signed :char :unsigned-char))
             (16 (if signed :short :unsigned-short))
             (32 (if signed :int :unsigned-int))
             (64 (if signed :long-long :unsigned-long-long)))))
    (or (cond ((member type '(single-float short-float)) :float)
              ((member type '(double-float long-float)) :double)
              ((eq type 'fixnum) :long)
              ((eq type 'foreign-pointer) :pointer)
              ((and (consp type) (eq (first type) 'signed-byte)) (sized (second type) t))
              ((and (consp type) (eq (first type) 'unsigned-byte)) (sized (second type) nil)))
        (error "A slot of type ~s has no C type." type))))

(defun %define-cstruct-from-defstruct (name)
  (let ((slots (get name '%structure-slots))
        (types (get name '%structure-slot-types)))
    (unless slots (error "~s is not a structure with slots." name))
    (setf (gethash name *%foreign-structs*)
          (%layout-foreign-struct name (mapcar (lambda (slot type) (list slot (%c-type-for-slot-type type)))
                                               slots types)))
    name))

(defmacro defcstruct-from-defstruct (name)
  "Lay the Lisp structure NAME out as a C structure of the same name,
each slot's C type following from its :type: (signed-byte N) and
(unsigned-byte N) for N of 8, 16, 32 or 64, fixnum, single-float,
double-float and foreign-pointer."
  `(%define-cstruct-from-defstruct ',name))

(defun write-foreign-struct (instance pointer)
  "Store the slots of the Lisp structure INSTANCE in the C structure
`defcstruct-from-defstruct` made for its type, at POINTER."
  (let ((name (type-of instance)))
    (dolist (slot (foreign-slot-names name) pointer)
      (setf (foreign-slot-value pointer name slot) (slot-value instance slot)))))

(defun read-foreign-struct (pointer name)
  "A new Lisp structure of type NAME holding the C structure at POINTER."
  (apply #'%make-structure name
         (mapcar (lambda (slot) (foreign-slot-value pointer name slot)) (foreign-slot-names name))))

(defun %foreign-struct-slot (type slot-name)
  (or (find slot-name (%foreign-struct-slots (%foreign-struct type)) :key #'%foreign-slot-name)
      (error "The C structure ~s has no field ~s." type slot-name)))

(defun foreign-slot-offset (type slot-name)
  (%foreign-slot-offset (%foreign-struct-slot type slot-name)))

(defun foreign-slot-names (type)
  (mapcar #'%foreign-slot-name (%foreign-struct-slots (%foreign-struct type))))

(defun foreign-slot-pointer (pointer type slot-name)
  (inc-pointer pointer (foreign-slot-offset type slot-name)))

(defun foreign-slot-value (pointer type slot-name)
  "The value of a field of the structure at POINTER. A field that is a
structure or an array is a pointer to it."
  (let ((slot (%foreign-struct-slot type slot-name)))
    (if (or (%struct-type-p (%foreign-slot-type slot)) (/= (%foreign-slot-count slot) 1))
        (inc-pointer pointer (%foreign-slot-offset slot))
        (mem-ref pointer (%foreign-slot-type slot) (%foreign-slot-offset slot)))))

(defun (setf foreign-slot-value) (new pointer type slot-name)
  (let ((slot (%foreign-struct-slot type slot-name)))
    (setf (mem-ref pointer (%foreign-slot-type slot) (%foreign-slot-offset slot)) new)))

(defctype :size-t :unsigned-long)
(defctype :ssize-t :long)
(defctype :off-t :long)
(defctype :int8 :char)
(defctype :uint8 :unsigned-char)
(defctype :int16 :short)
(defctype :uint16 :unsigned-short)
(defctype :int32 :int)
(defctype :uint32 :unsigned-int)
(defctype :int64 :long-long)
(defctype :uint64 :unsigned-long-long)

(defun %foreign-argument (value type)
  (if (and (member type '(:pointer :string)) (pointerp value))
      (foreign-pointer-address value)
      value))

(defun %foreign-result (value type)
  (if (eq type :pointer) (make-pointer value) value))

;;; Symbols and libraries

(defun foreign-symbol-pointer (name)
  "A pointer to the C symbol NAME, or NIL when no loaded library has it."
  (let ((address (%foreign-symbol-address name)))
    (and address (make-pointer address))))

(defun load-foreign-library (path)
  (let ((outcome (%load-foreign-library (namestring path))))
    (unless (eq outcome t)
      (error "The foreign library ~a could not be loaded: ~a" path outcome))
    path))

(defun %foreign-function-address (name)
  (or (%foreign-symbol-address name)
      (error "No loaded library defines the C function ~a." name)))

;;; Calls

(defun foreign-funcall-pointer (pointer return-type &rest types-and-arguments)
  "Call the C function at POINTER. TYPES-AND-ARGUMENTS alternate a C type
and the argument passed as it."
  (let ((types nil) (arguments nil))
    (loop for (type argument) on types-and-arguments by #'cddr
          do (let ((base (canonical-foreign-type type)))
               (push base types)
               (push (%foreign-argument argument base) arguments)))
    (let ((base (canonical-foreign-type return-type)))
      (%foreign-result (%foreign-call (foreign-pointer-address pointer) base
                                      (nreverse types) (nreverse arguments))
                       base))))

(defun %call-foreign-function (name return-type types arguments)
  (%foreign-result (%foreign-call (%foreign-function-address name) return-type types
                                  (mapcar #'%foreign-argument arguments types))
                   return-type))

(defmacro foreign-funcall (name &rest types-and-arguments)
  "Call the C function NAME. TYPES-AND-ARGUMENTS alternate a C type and an
argument, and end with the return type."
  (let ((pairs (butlast types-and-arguments))
        (return-type (car (last types-and-arguments))))
    `(%call-foreign-function ,name ',(canonical-foreign-type return-type)
                             ',(loop for (type) on pairs by #'cddr collect (canonical-foreign-type type))
                             (list ,@(loop for (nil argument) on pairs by #'cddr collect argument)))))

(defun %lisp-name-for-c-name (c-name)
  (intern (substitute #\- #\_ (string-upcase c-name))))

(defmacro defcfun (name return-type &rest parameters)
  "Define a Lisp function that calls the C function NAME, a string or a
list of the C name and the Lisp name. Each parameter is a list of its
name and its C type."
  (multiple-value-bind (c-name lisp-name)
      (if (consp name)
          (values (first name) (second name))
          (values name (%lisp-name-for-c-name name)))
    (let ((names (mapcar #'first parameters))
          (types (mapcar (lambda (parameter) (canonical-foreign-type (second parameter))) parameters)))
      `(progn
         (%foreign-function-address ,c-name)
         (defun ,lisp-name ,names
           (%call-foreign-function ,c-name ',(canonical-foreign-type return-type) ',types
                                   (list ,@names)))
         ',lisp-name))))

;;; Callbacks

;; Each entry is NIL or (function return-type . parameter-types), for the
;; entry point of that slot. The first 32 return an integer and the rest
;; a double.
(defvar *%callbacks* (make-array 64 :initial-element nil))
(defvar *%callback-slots* (make-hash-table))

(defun %free-callback-slot (return-type)
  (let ((start (if (member return-type '(:float :double)) 32 0)))
    (or (loop for slot from start below (+ start 32)
              unless (svref *%callbacks* slot) return slot)
        (error "All 32 callbacks returning ~a are in use." return-type))))

(defun %define-callback (name return-type types function)
  (when (eq return-type :string)
    (error "A callback cannot return :string."))
  (let* ((float-result (member return-type '(:float :double)))
         (held (gethash name *%callback-slots*))
         (slot (if (and held (eq (>= held 32) (and float-result t)))
                   held
                   (progn
                     (when held (setf (svref *%callbacks* held) nil))
                     (%free-callback-slot return-type)))))
    (setf (svref *%callbacks* slot) (list* function return-type types)
          (gethash name *%callback-slots*) slot)
    name))

(defmacro defcallback (name return-type parameters &body body)
  "Define a Lisp function C can call through the pointer `callback`
gives for NAME. Each parameter is a list of its name and its C type."
  (let ((names (mapcar #'first parameters))
        (types (mapcar (lambda (parameter) (canonical-foreign-type (second parameter))) parameters))
        (result (canonical-foreign-type return-type)))
    `(%define-callback ',name ',result ',types
                       (lambda ,names
                         (let ,(loop for name in names
                                     for type in types
                                     when (eq type :pointer)
                                       collect `(,name (make-pointer ,name)))
                           (%foreign-argument (block ,name ,@body) ',result))))))

(defun get-callback (name)
  (let ((slot (gethash name *%callback-slots*)))
    (unless slot (error "~s is not a callback." name))
    (make-pointer (%callback-address slot))))

(defmacro callback (name)
  `(get-callback ',name))

;;; Foreign memory

(defun mem-ref (pointer type &optional (offset 0))
  (let ((base (canonical-foreign-type type)))
    (%foreign-result (%mem-ref (+ (foreign-pointer-address pointer) offset) base) base)))

(defun (setf mem-ref) (new pointer type &optional (offset 0))
  (let ((base (canonical-foreign-type type)))
    (%mem-set (+ (foreign-pointer-address pointer) offset) base (%foreign-argument new base))
    new))

(defun mem-aref (pointer type &optional (index 0))
  (mem-ref pointer type (* index (foreign-type-size type))))

(defun (setf mem-aref) (new pointer type &optional (index 0))
  (setf (mem-ref pointer type (* index (foreign-type-size type))) new))

(defun foreign-alloc (type &key (count 1) (initial-element nil element-p)
                                (initial-contents nil contents-p))
  "A pointer to COUNT objects of TYPE from malloc, which `foreign-free`
gives back."
  (let* ((count (if contents-p (length initial-contents) count))
         (pointer (make-pointer (%foreign-alloc (* count (foreign-type-size type))))))
    (when element-p
      (dotimes (index count) (setf (mem-aref pointer type index) initial-element)))
    (when contents-p
      (let ((index 0))
        (map nil (lambda (element)
                   (setf (mem-aref pointer type index) element)
                   (incf index))
             initial-contents)))
    pointer))

(defun foreign-free (pointer)
  (%foreign-free (foreign-pointer-address pointer))
  nil)

(defmacro with-foreign-object ((var type &optional (count 1)) &body body)
  `(let ((,var (foreign-alloc ,type :count ,count)))
     (unwind-protect (progn ,@body)
       (foreign-free ,var))))

(defmacro with-foreign-objects (bindings &body body)
  (if (null bindings)
      `(progn ,@body)
      `(with-foreign-object ,(first bindings)
         (with-foreign-objects ,(rest bindings) ,@body))))

(defun foreign-string-alloc (string)
  (make-pointer (%lisp-string-to-foreign string)))

(defun foreign-string-to-lisp (pointer)
  (%foreign-string-to-lisp (foreign-pointer-address pointer)))

(defmacro with-foreign-string ((var string) &body body)
  `(let ((,var (foreign-string-alloc ,string)))
     (unwind-protect (progn ,@body)
       (foreign-free ,var))))

(defparameter *%ffi-symbols*
  '(foreign-pointer make-pointer pointerp pointer-address null-pointer null-pointer-p
    inc-pointer pointer-eq defctype canonical-foreign-type foreign-type-size
    foreign-symbol-pointer load-foreign-library foreign-funcall foreign-funcall-pointer
    defcfun mem-ref mem-aref foreign-alloc foreign-free with-foreign-object
    with-foreign-objects foreign-string-alloc foreign-string-to-lisp with-foreign-string
    defcallback callback get-callback defcstruct foreign-slot-value foreign-slot-offset
    foreign-slot-pointer foreign-slot-names foreign-type-alignment defcstruct-from-defstruct
    write-foreign-struct read-foreign-struct))

(let ((ffi (or (find-package "ZISP-FFI") (make-package "ZISP-FFI" :nicknames '("FFI") :use nil))))
  (import *%ffi-symbols* ffi)
  (export *%ffi-symbols* ffi))

(in-package "COMMON-LISP-USER")
