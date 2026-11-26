;;;; Macros that run Zig comptime: `comptime-eval` hands a Zig expression
;;;; to the Zig compiler and reads back the Lisp form its value prints as.
;;;; The names are exported from ZISP-ZIG, nicknamed ZIG.

(in-package "COMMON-LISP")

(defvar *zig-program* nil
  "The Zig compiler to run. NIL means the value of ZISP_ZIG when it is
set, otherwise \"zig\" found on PATH.")

(defvar *zig-cache-directory* nil
  "Where generator files and their results are kept. NIL means
$XDG_CACHE_HOME/zisp/zig/, or ~/.cache/zisp/zig/ without XDG_CACHE_HOME.")

(define-condition zig-error (error)
  ((arguments :initarg :arguments :initform nil :reader zig-error-arguments)
   (exit-code :initarg :exit-code :initform nil :reader zig-error-exit-code)
   (output :initarg :output :initform "" :reader zig-error-output))
  (:report (lambda (condition stream)
             (format stream "Zig failed running ~{~a~^ ~}:~%~a"
                     (zig-error-arguments condition) (zig-error-output condition)))))

(define-condition zig-not-found (zig-error) ()
  (:report (lambda (condition stream)
             (format stream "The Zig compiler ~s could not be started: ~a"
                     (%zig-program) (zig-error-output condition)))))

(define-condition zig-comptime-error (zig-error) ())

(defun %zig-program ()
  (or *zig-program*
      (and (fboundp '%getenv) (%getenv "ZISP_ZIG"))
      "zig"))

(defun %zig-cache-directory ()
  (or *zig-cache-directory*
      (let ((xdg (and (fboundp '%getenv) (%getenv "XDG_CACHE_HOME")))
            (home (and (fboundp '%getenv) (%getenv "HOME"))))
        (cond ((and xdg (string/= xdg "")) (concatenate 'string (string-right-trim "/" xdg) "/zisp/zig/"))
              (home (concatenate 'string (string-right-trim "/" home) "/.cache/zisp/zig/"))
              (t (error 'zig-not-found :output "Neither XDG_CACHE_HOME nor HOME is set."))))))

(defun %run-zig (arguments directory error-type)
  "Run Zig with ARGUMENTS in DIRECTORY and return its standard output,
signalling ERROR-TYPE when it exits nonzero."
  (unless (fboundp '%run-program)
    (error 'zig-not-found :arguments arguments :output "This build of zisp cannot start a process."))
  (multiple-value-bind (code output errors) (%run-program (%zig-program) arguments directory)
    (cond ((null code) (error 'zig-not-found :arguments arguments :output errors))
          ((/= code 0) (error error-type :arguments arguments :exit-code code :output errors))
          (t output))))

(defvar *%zig-version* nil)

(defun %zig-version (directory)
  (or *%zig-version*
      (setq *%zig-version* (string-trim '(#\Newline #\Space) (%run-zig '("version") directory 'zig-error)))))

(defun %write-file-text (path text)
  "Write TEXT to PATH by way of a temporary file renamed over it, so a
reader sees the whole file or none."
  (let ((temporary (concatenate 'string path ".tmp")))
    (with-open-file (out temporary :direction :output :if-exists :supersede)
      (write-string text out))
    (rename-file temporary path)))

(defun %zig-cache-key (directory &rest parts)
  "The SHA-256 of the Zig version, the printer's source and PARTS,
joined with NUL characters."
  (let ((separator (string (code-char 0))))
    (%sha256-hex (reduce (lambda (joined part) (concatenate 'string joined separator part))
                         (list* (%zig-version directory) (%zig-printer-source) parts)))))

(defun %zig-generator-source (expression imports)
  (with-output-to-string (out)
    (format out "const std = @import(\"std\");~%const lisp = @import(\"zisp_lisp.zig\");~%")
    (dolist (import imports)
      (format out "const ~a = @import(~s);~%" (first import) (string (first import))))
    (format out "~%const form = lisp.print(~a);~%~%" expression)
    (format out "pub fn main(init: std.process.Init) !void {~%")
    (format out "    try std.Io.File.stdout().writeStreamingAll(init.io, form ++ \"\\n\");~%}~%")))

(defun %file-text (path)
  (with-open-file (in path)
    (let ((text (make-string (file-length in))))
      (subseq text 0 (read-sequence text in)))))

(defun %zig-import-arguments (source imports)
  "Zig's arguments making each (name path) import a module NAME, and the
generator the root module that depends on them."
  (append (loop for (name) in imports append (list "--dep" (string name)))
          (list (concatenate 'string "-Mroot=" source))
          (loop for (name path) in imports
                collect (format nil "-M~a=~a" name (namestring (truename path))))))

(defun %read-cached-form (path)
  (with-open-file (in path)
    (with-standard-io-syntax
      (let ((*read-eval* nil))
        (read in)))))

(defun comptime-eval (zig-expression &key imports)
  "Have Zig evaluate ZIG-EXPRESSION at compile time and return the Lisp
form its value prints as. IMPORTS is a list of (name path) pairs, each
Zig file imported under NAME for the expression."
  (unless (fboundp '%run-program)
    (error 'zig-not-found :output "This build of zisp cannot start a process."))
  (let* ((directory (concatenate 'string
                                 (string-right-trim "/" (namestring (truename (ensure-directories-exist (%zig-cache-directory)))))
                                 "/"))
         (generator (%zig-generator-source zig-expression imports))
         (key (progn
                (apply #'%zig-cache-key directory generator
                       (loop for (name path) in imports
                             collect (string name) collect (%file-text path)))))
         (result (concatenate 'string directory key ".lisp")))
    (if (probe-file result)
        (%read-cached-form result)
        (let ((source (concatenate 'string key ".zig")))
          (%write-file-text (concatenate 'string directory "zisp_lisp.zig") (%zig-printer-source))
          (%write-file-text (concatenate 'string directory source) generator)
          (let ((output (%run-zig (list* "run" "--cache-dir" "zig-cache"
                                         (%zig-import-arguments source imports))
                                  directory 'zig-comptime-error)))
            (prog1 (with-standard-io-syntax
                     (let ((*read-eval* nil))
                       (values (read-from-string output))))
              (%write-file-text result output)))))))

;;; Structures from Zig types

(defun %ffi-type-from-zig (field description)
  (flet ((sized (bits signed)
           (case bits
             (8 (if signed :int8 :uint8))
             (16 (if signed :int16 :uint16))
             (32 (if signed :int32 :uint32))
             (64 (if signed :int64 :uint64)))))
    (or (cond ((eq description :pointer) :pointer)
              ((atom description) nil)
              ((eq (first description) :signed) (sized (second description) t))
              ((eq (first description) :unsigned) (sized (second description) nil))
              ((equal description '(:float 32)) :float)
              ((equal description '(:float 64)) :double))
        (error "The field ~a has the Zig type ~s, which has no C type here." field description))))

(defun %cstruct-form (name description)
  (unless (and (consp description) (eq (first description) :struct))
    (error "~s does not describe a Zig struct type." description))
  (destructuring-bind (&key size alignment) (subseq description 1 5)
    (let* ((zig-fields (nthcdr 5 description))
           (fields (mapcar (lambda (field)
                             (list (intern (symbol-name (first field)))
                                   (%ffi-type-from-zig (first field) (getf (rest field) :type))))
                           zig-fields))
           (layout (%layout-foreign-struct name fields)))
      (loop for zig-field in zig-fields
            for slot in (%foreign-struct-slots layout)
            unless (eql (getf (rest zig-field) :offset) (%foreign-slot-offset slot))
              do (error "Zig puts the field ~a at offset ~d, and the C layout puts it at ~d."
                        (first zig-field) (getf (rest zig-field) :offset) (%foreign-slot-offset slot)))
      (unless (and (eql size (%foreign-struct-size layout))
                   (eql alignment (%foreign-struct-alignment layout)))
        (error "Zig gives ~s a size of ~d and alignment of ~d, and the C layout ~d and ~d."
               name size alignment (%foreign-struct-size layout) (%foreign-struct-alignment layout)))
      `(defcstruct ,name ,@fields))))

(defmacro define-cstruct-from-zig (name zig-type &key imports)
  "Define the C structure NAME with the fields, types and offsets Zig
gives the struct type named by the string ZIG-TYPE. IMPORTS is as for
`comptime-eval`."
  (%cstruct-form name (comptime-eval zig-type :imports imports)))

;;; Zig structures from Lisp structures

(defparameter *%zig-keywords*
  '("addrspace" "align" "allowzero" "and" "anyframe" "anytype" "asm" "break" "callconv"
    "catch" "comptime" "const" "continue" "defer" "else" "enum" "errdefer" "error" "export"
    "extern" "fn" "for" "if" "inline" "linksection" "noalias" "noinline" "nosuspend"
    "opaque" "or" "orelse" "packed" "pub" "resume" "return" "struct" "suspend" "switch"
    "test" "threadlocal" "try" "union" "unreachable" "var" "volatile" "while"))

(defun %zig-identifier (name)
  "NAME as a Zig identifier, quoted as @\"...\" when it is a keyword or
holds a character an identifier cannot."
  (if (and (plusp (length name))
           (not (digit-char-p (char name 0)))
           (every (lambda (char) (or (alphanumericp char) (char= char #\_))) name)
           (not (member name *%zig-keywords* :test #'string=)))
      name
      (format nil "@~s" name)))

(defun %zig-struct-name (name)
  (%zig-identifier (remove #\- (string-capitalize (symbol-name name)))))

(defun %zig-field-name (name)
  (%zig-identifier (substitute #\_ #\- (string-downcase (symbol-name name)))))

(defun %zig-field-type (slot type)
  "The Zig type of a structure slot declared TYPE, or NIL for a slot
that holds any Lisp value."
  (flet ((sized (prefix bits)
           (if (member bits '(8 16 32 64))
               (format nil "~a~d" prefix bits)
               (error "The slot ~s has the type ~s, which has no Zig type." slot type))))
    (cond ((eq type t) nil)
          ((member type '(single-float short-float)) "f32")
          ((member type '(double-float long-float)) "f64")
          ((eq type 'fixnum) "i64")
          ((eq type 'foreign-pointer) "?*anyopaque")
          ((and (consp type) (eq (first type) 'signed-byte)) (sized "i" (second type)))
          ((and (consp type) (eq (first type) 'unsigned-byte)) (sized "u" (second type)))
          (t (error "The slot ~s has the type ~s, which has no Zig type." slot type)))))

(defun extern-struct-source (&rest structure-names)
  "Zig source declaring an extern struct for each named Lisp structure,
its fields in slot order."
  (let* ((structures
           (mapcar (lambda (name)
                     (let ((slots (get name '%structure-slots)))
                       (unless slots (error "~s is not a structure with slots." name))
                       (list name
                             (mapcar (lambda (slot type) (list slot (%zig-field-type slot type)))
                                     slots (get name '%structure-slot-types)))))
                   structure-names))
         (needs-value (some (lambda (structure) (some (lambda (field) (null (second field))) (second structure)))
                            structures)))
    (with-output-to-string (out)
      (when needs-value
        (format out "pub const Value = u64;~%~%"))
      (loop for (name fields) in structures
            for first = t then nil
            do (unless first (terpri out))
               (format out "pub const ~a = extern struct {~%" (%zig-struct-name name))
               (loop for (slot type) in fields
                     do (format out "    ~a: ~a,~%" (%zig-field-name slot) (or type "Value")))
               (format out "};~%")))))

(defun write-zig-structs (path &rest structure-names)
  "Write the Zig extern structs for STRUCTURE-NAMES to PATH and return PATH."
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string (apply #'extern-struct-source structure-names) out))
  path)

;;; Type-checking with Zig

(define-condition zig-type-error (zig-error)
  ((function-name :initarg :function-name :reader zig-type-error-function-name)
   (form :initarg :form :reader zig-type-error-form)
   (message :initarg :message :reader zig-type-error-message))
  (:report (lambda (condition stream)
             (format stream "Zig rejects ~s in ~s: ~a"
                     (zig-type-error-form condition) (zig-type-error-function-name condition)
                     (zig-type-error-message condition)))))

(defvar *%checked-functions* (make-hash-table)
  "Each function `defun-checked` accepted, with its Zig parameter types
and result type.")

(defun %zig-checked-type (what type)
  (cond ((eq type 'fixnum) "i61")
        ((eq type 'boolean) "bool")
        ((or (eq type t) (eq type 'integer)) (error "~a has the type ~s, which has no Zig type." what type))
        (t (or (%zig-field-type what type)
               (error "~a has the type ~s, which has no Zig type." what type)))))

;; The translation state: the Lisp variables in scope with their Zig
;; names, the lines written so far with the form each came from, the
;; checked functions called, and a counter for fresh names.
(defvar *%zig-scope* nil)
(defvar *%zig-lines* nil)
(defvar *%zig-callees* nil)
(defvar *%zig-counter* 0)
(defvar *%zig-function* nil)

(defun %zig-emit (indent form control &rest arguments)
  (push (cons (concatenate 'string (make-string (* 4 indent) :initial-element #\Space)
                           (apply #'format nil control arguments))
              form)
        *%zig-lines*))

(defun %zig-fresh-name (symbol)
  (let ((base (%zig-identifier (substitute #\_ #\- (string-downcase (symbol-name symbol))))))
    (if (or (rassoc base *%zig-scope* :test #'string=) (char= (char base 0) #\@))
        (format nil "~a_~d" (string-trim "@\"" base) (incf *%zig-counter*))
        base)))

(defun %mentions-p (symbol form)
  (cond ((eq form symbol) t)
        ((atom form) nil)
        ((eq (first form) 'quote) nil)
        (t (some (lambda (part) (%mentions-p symbol part)) form))))

(defun %zig-not-checkable (form)
  (error "The form ~s in ~s is not one defun-checked translates." form *%zig-function*))

(defun %zig-operand (form)
  (let ((text (%zig-expression form)))
    (if (or (consp form) (and (realp form) (minusp form)))
        (format nil "(~a)" text)
        text)))

(defun %zig-fold (operator operands)
  (reduce (lambda (left right) (format nil "(~a ~a ~a)" left operator right))
          (mapcar #'%zig-operand operands)))

(defun %zig-literal (number)
  (cond ((integerp number) (format nil "~d" number))
        ((floatp number) (format nil "~f" number))
        (t (%zig-not-checkable number))))

(defun %zig-strip (text)
  "TEXT without one pair of enclosing parentheses, when they enclose it all."
  (if (and (> (length text) 1) (char= (char text 0) #\() (char= (char text (1- (length text))) #\))
           (let ((depth 0))
             (loop for index from 0 below (1- (length text))
                   for char = (char text index)
                   do (case char (#\( (incf depth)) (#\) (decf depth)))
                   never (and (zerop depth) (> index 0)))))
      (subseq text 1 (1- (length text)))
      text))

(defun %zig-expression (form)
  "FORM as one line of Zig."
  (cond ((numberp form) (%zig-literal form))
        ((and (symbolp form) (not (keywordp form)) form)
         (or (cdr (assoc form *%zig-scope*)) (%zig-not-checkable form)))
        ((atom form) (%zig-not-checkable form))
        (t
         (destructuring-bind (operator &rest operands) form
           (case operator
             ((+ *) (cond ((null operands) (if (eq operator '+) "0" "1"))
                          ((null (rest operands)) (%zig-expression (first operands)))
                          (t (%zig-strip (%zig-fold (string operator) operands)))))
             (- (cond ((null operands) (%zig-not-checkable form))
                      ((null (rest operands)) (format nil "-~a" (%zig-operand (first operands))))
                      (t (%zig-strip (%zig-fold "-" operands)))))
             ((< > <= >= =)
              (unless (= (length operands) 2) (%zig-not-checkable form))
              (format nil "~a ~a ~a" (%zig-operand (first operands))
                      (if (eq operator '=) "==" (string operator))
                      (%zig-operand (second operands))))
             (truncate
              (unless (= (length operands) 2) (%zig-not-checkable form))
              (format nil "@divTrunc(~a, ~a)" (%zig-expression (first operands)) (%zig-expression (second operands))))
             (if
              (unless (= (length operands) 3) (%zig-not-checkable form))
              (format nil "if (~a) ~a else ~a" (%zig-expression (first operands))
                      (%zig-operand (second operands)) (%zig-operand (third operands))))
             (the
              (unless (= (length operands) 2) (%zig-not-checkable form))
              (format nil "@as(~a, ~a)" (%zig-checked-type (format nil "The form ~s" form) (first operands))
                      (%zig-expression (second operands))))
             (let (%zig-let-expression form))
             (t (%zig-call form)))))))

(defun %zig-call (form)
  (destructuring-bind (name &rest arguments) form
    (let ((signature (if (eq name *%zig-function*)
                         t
                         (gethash name *%checked-functions*))))
      (unless (and (symbolp name) signature) (%zig-not-checkable form))
      (unless (eq signature t) (pushnew name *%zig-callees*))
      (format nil "~a(~{~a~^, ~})" (%zig-identifier (substitute #\_ #\- (string-downcase (symbol-name name))))
              (mapcar #'%zig-expression arguments)))))

(defun %zig-bindings (form)
  "The bindings of the let FORM as (symbol zig-name value-text), each
value translated in the scope outside the let."
  (destructuring-bind (bindings &rest body) (rest form)
    (declare (ignore body))
    (mapcar (lambda (binding)
              (unless (and (consp binding) (symbolp (first binding)) (= (length binding) 2))
                (%zig-not-checkable form))
              (list (first binding) (%zig-fresh-name (first binding)) (%zig-expression (second binding))))
            bindings)))

(defun %zig-let-expression (form)
  (let* ((bindings (%zig-bindings form))
         (label (format nil "blk_~d" (incf *%zig-counter*)))
         (body (cddr form))
         (*%zig-scope* (append (mapcar (lambda (binding) (cons (first binding) (second binding))) bindings)
                               *%zig-scope*)))
    (unless body (%zig-not-checkable form))
    (format nil "~a: { ~{~a ~}~{_ = ~a; ~}break :~a ~a; }"
            label
            (mapcar (lambda (binding) (format nil "const ~a = ~a;" (second binding) (third binding))) bindings)
            (append (loop for binding in bindings
                          unless (%mentions-p (first binding) body) collect (second binding))
                    (mapcar #'%zig-expression (butlast body)))
            label (%zig-expression (car (last body))))))

(defun %zig-tail (form indent)
  "Write FORM, in tail position, as statements that return its value."
  (cond ((and (consp form) (eq (first form) 'let))
         (let ((bindings (%zig-bindings form))
               (body (cddr form)))
           (unless body (%zig-not-checkable form))
           (%zig-emit indent form "{")
           (dolist (binding bindings)
             (%zig-emit (1+ indent) (second (find (first binding) (second form) :key #'first))
                        "const ~a = ~a;" (second binding) (third binding)))
           (let ((*%zig-scope* (append (mapcar (lambda (binding) (cons (first binding) (second binding))) bindings)
                                       *%zig-scope*)))
             (dolist (binding bindings)
               (unless (%mentions-p (first binding) body)
                 (%zig-emit (1+ indent) form "_ = ~a;" (second binding))))
             (%zig-body body (1+ indent)))
           (%zig-emit indent form "}")))
        ((and (consp form) (eq (first form) 'if) (= (length form) 4))
         (%zig-emit indent form "if (~a) {" (%zig-expression (second form)))
         (%zig-tail (third form) (1+ indent))
         (%zig-emit indent form "} else {")
         (%zig-tail (fourth form) (1+ indent))
         (%zig-emit indent form "}"))
        (t (%zig-emit indent form "return ~a;" (%zig-expression form)))))

(defun %zig-body (body indent)
  (dolist (form (butlast body))
    (%zig-emit indent form "_ = ~a;" (%zig-expression form)))
  (%zig-tail (car (last body)) indent))

(defun %zig-signature (name parameter-types result-type)
  (format nil "fn ~a(~{~a~^, ~}) ~a"
          (%zig-identifier (substitute #\_ #\- (string-downcase (symbol-name name))))
          parameter-types result-type))

(defun %checked-function-source (name parameters result-type body)
  "The Zig source for the function and the forms its lines came from, as
two values."
  (let* ((*%zig-function* name)
         (*%zig-counter* 0)
         (*%zig-lines* nil)
         (*%zig-callees* nil)
         (parameter-names (mapcar (lambda (parameter) (%zig-fresh-name (first parameter))) parameters))
         (*%zig-scope* (mapcar (lambda (parameter zig-name) (cons (first parameter) zig-name))
                               parameters parameter-names))
         (parameter-types (mapcar (lambda (parameter)
                                    (%zig-checked-type (format nil "The parameter ~s" (first parameter))
                                                       (second parameter)))
                                  parameters))
         (zig-result (%zig-checked-type (format nil "The result of ~s" name) result-type)))
    (unless body (%zig-not-checkable body))
    (%zig-emit 0 nil "~a {" (%zig-signature name (mapcar (lambda (parameter-name type) (format nil "~a: ~a" parameter-name type))
                                                         parameter-names parameter-types)
                                            zig-result))
    (loop for parameter in parameters
          for zig-name in parameter-names
          unless (%mentions-p (first parameter) body)
            do (%zig-emit 1 nil "_ = ~a;" zig-name))
    (%zig-body body 1)
    (%zig-emit 0 nil "}")
    (dolist (callee *%zig-callees*)
      (destructuring-bind (types result) (gethash callee *%checked-functions*)
        (let ((names (loop for index from 0 below (length types) collect (format nil "a~d" index))))
          (%zig-emit 0 nil "")
          (%zig-emit 0 nil "~a {" (%zig-signature callee (mapcar (lambda (zig-name type) (format nil "~a: ~a" zig-name type))
                                                                 names types)
                                                  result))
          (dolist (zig-name names) (%zig-emit 1 nil "_ = ~a;" zig-name))
          (%zig-emit 1 nil "unreachable;")
          (%zig-emit 0 nil "}"))))
    (%zig-emit 0 nil "")
    (%zig-emit 0 nil "comptime {")
    (%zig-emit 1 nil "_ = &~a;" (%zig-identifier (substitute #\_ #\- (string-downcase (symbol-name name)))))
    (%zig-emit 0 nil "}")
    (let ((lines (reverse *%zig-lines*)))
      (values (format nil "~{~a~%~}" (mapcar #'car lines))
              (mapcar #'cdr lines)
              parameter-types zig-result))))

(defun %zig-first-error (output source)
  "The line number and message of the first error Zig reports in SOURCE."
  (let* ((prefix (concatenate 'string source ":"))
         (start (search prefix output)))
    (when start
      (let* ((line-start (+ start (length prefix)))
             (line-end (position #\: output :start line-start))
             (message-start (search "error: " output :start2 line-end))
             (message-end (or (position #\Newline output :start (or message-start 0)) (length output))))
        (values (reduce (lambda (number digit) (+ (* number 10) (digit-char-p digit)))
                        (subseq output line-start line-end) :initial-value 0)
                (if message-start (subseq output (+ message-start 7) message-end) ""))))))

(defun %check-with-zig (name source forms)
  (let* ((directory (concatenate 'string
                                 (string-right-trim "/" (namestring (truename (ensure-directories-exist (%zig-cache-directory)))))
                                 "/"))
         (key (%zig-cache-key directory source))
         (passed (concatenate 'string directory key ".ok")))
    (unless (probe-file passed)
      (let ((file (concatenate 'string key ".zig")))
        (%write-file-text (concatenate 'string directory file) source)
        (handler-case (%run-zig (list "build-obj" "-fno-emit-bin" "--cache-dir" "zig-cache" file) directory 'zig-error)
          (zig-not-found (condition) (error condition))
          (zig-error (condition)
            (multiple-value-bind (line message) (%zig-first-error (zig-error-output condition) file)
              (error 'zig-type-error
                     :arguments (zig-error-arguments condition)
                     :exit-code (zig-error-exit-code condition)
                     :output (zig-error-output condition)
                     :function-name name
                     :form (and line (nth (1- line) forms))
                     :message (or message "")))))
        (%write-file-text passed "")))))

(defmacro defun-checked (name parameters result-type &body body)
  "Define NAME as a function of PARAMETERS, each (variable type), after
Zig has accepted its body under Zig's typing rules."
  (multiple-value-bind (source forms parameter-types zig-result)
      (%checked-function-source name parameters result-type body)
    (%check-with-zig name source forms)
    (setf (gethash name *%checked-functions*) (list parameter-types zig-result))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (setf (gethash ',name *%checked-functions*) '(,parameter-types ,zig-result)))
       (defun ,name ,(mapcar #'first parameters)
         (declare ,@(mapcar (lambda (parameter) `(type ,(second parameter) ,(first parameter))) parameters))
         (the ,result-type (progn ,@body))))))

(defparameter *%zig-symbols*
  '(*zig-program* *zig-cache-directory* comptime-eval define-cstruct-from-zig
    extern-struct-source write-zig-structs defun-checked zig-type-error
    zig-type-error-function-name zig-type-error-form zig-type-error-message
    zig-error zig-not-found zig-comptime-error
    zig-error-arguments zig-error-exit-code zig-error-output))

(let ((zig (or (find-package "ZISP-ZIG") (make-package "ZISP-ZIG" :nicknames '("ZIG") :use nil))))
  (import *%zig-symbols* zig)
  (export *%zig-symbols* zig))

(in-package "COMMON-LISP-USER")
