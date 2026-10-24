;;; CLOS: classes, generic functions and methods.
;;;
;;; The runtime provides instances (src/builtins/instances.zig): an object
;;; holding its class, a vector of slot values, and the wrapper its class
;;; had when that vector was laid out. Everything else is here. The
;;; metaobjects are instances too, and each kind keeps its slots at fixed
;;; positions in the vector, so the code below reaches them without a
;;; lookup. A class lists the slots its first superclass has ahead of its
;;; own, which keeps those positions for a subclass of a metaobject class.

(in-package "COMMON-LISP")

;; What an unbound slot holds.
(defvar *%slot-unbound* (make-symbol "UNBOUND"))

;; What the native slot readers hand back where the standard route does
;; not apply and the Lisp below has to take over.
(defvar *%fast-miss* (make-symbol "FAST-MISS"))

;; Set once every metaobject class and the generic functions of the
;; protocol exist. Before that, the code below calls the standard
;; behavior directly rather than through generic functions.
(defvar *%clos-booted* nil)

;; Bumped when a class already in use gets a different precedence list,
;; which is what makes every generic function drop the methods it cached
;; by class. A class defined for the first time has no cached entries.
(defvar *%dispatch-epoch* 0)

;; Bumped whenever a class is defined, redefined or named, which is what
;; `subtypep` keys the types it worked out for classes on.
(defvar *%class-epoch* 0)

;;; --- metaobject layouts ---

(defparameter *%class-layout*
  '(name direct-superclasses direct-subclasses precedence-list direct-slots
    slots direct-default-initargs default-initargs finalized-p wrapper
    prototype documentation direct-methods slot-table plist))

(defparameter *%gf-layout*
  '(name lambda-list methods method-class method-combination
    argument-precedence-order declarations documentation cache epoch
    dispatch-positions required-count eql-positions keyword-info plist
    argument-limit))

(defparameter *%method-layout*
  '(generic-function specializers qualifiers lambda-list function
    documentation slot-definition plist))

(defparameter *%slotd-layout*
  '(name initform initfunction initargs readers writers type allocation
    documentation location allocation-class))

(defparameter *%eql-layout* '(object direct-methods))

(defparameter *%combination-layout* '(name options type documentation))

(defmacro %layout-ref (layout object name)
  (let ((index (position name (symbol-value layout))))
    (unless index
      (error "~S has no slot ~S." layout name))
    `(svref (%instance-slots ,object) ,index)))

(defmacro %class-ref (class name) `(%layout-ref *%class-layout* ,class ,name))
(defmacro %gf-ref (gf name) `(%layout-ref *%gf-layout* ,gf ,name))
(defmacro %method-ref (method name) `(%layout-ref *%method-layout* ,method ,name))
(defmacro %slotd-ref (slotd name) `(%layout-ref *%slotd-layout* ,slotd ,name))
(defmacro %eql-ref (specializer name) `(%layout-ref *%eql-layout* ,specializer ,name))
(defmacro %combination-ref (combination name)
  `(%layout-ref *%combination-layout* ,combination ,name))

;; The natives in instances.zig read these slots at these positions.
(unless (and (eql (position 'name *%class-layout*) 0)
             (eql (position 'precedence-list *%class-layout*) 3)
             (eql (position 'wrapper *%class-layout*) 9)
             (eql (position 'slot-table *%class-layout*) 13)
             (eql (position 'type *%slotd-layout*) 6)
             (eql (position 'location *%slotd-layout*) 9)
             (eql (position 'cache *%gf-layout*) 8)
             (eql (position 'epoch *%gf-layout*) 9)
             (eql (position 'dispatch-positions *%gf-layout*) 10)
             (eql (position 'required-count *%gf-layout*) 11)
             (eql (position 'eql-positions *%gf-layout*) 12)
             (eql (position 'argument-limit *%gf-layout*) 15)
             (eql (position 'object *%eql-layout*) 0))
  (error "The metaobject layouts no longer match what the runtime reads."))

(defun %fresh-slots (count)
  (make-array count :initial-element *%slot-unbound*))


;;; --- finding classes ---

(defun find-class (symbol &optional (errorp t) environment)
  (declare (ignore environment))
  (let ((class (%find-class-quietly symbol)))
    (cond (class class)
          ((not errorp) nil)
          (t (error "~S does not name a class." symbol)))))

(defun %set-find-class (symbol new-class &optional errorp environment)
  (declare (ignore errorp environment))
  (%put symbol '%class new-class)
  (setq *%class-epoch* (1+ *%class-epoch*))
  new-class)

(defsetf find-class (symbol &optional errorp environment) (new-class)
  `(%set-find-class ,symbol ,new-class ,errorp ,environment))

(setf (symbol-function 'class-of) #'%class-of)

;;; --- subclass tests ---

(defun %class-precedence (class)
  (%class-ref class precedence-list))

(defun %subclassp (class other)
  (or (eq class other)
      (not (null (%memq other (%class-ref class precedence-list))))))

(defvar *%the-class-class* nil)

(defun %class-p (object)
  (and (%instance-p object)
       (not (null (%memq *%the-class-class*
                         (%class-ref (%instance-class object) precedence-list))))))

;;; --- the bootstrap ---
;;;
;;; The classes the protocol is made of are built by hand first, as bare
;;; shells: an instance of `standard-class` (or of the metaclass named)
;;; holding a name, its superclasses and its direct slots. Once every
;;; shell exists, each is finalized in turn, which makes the slot
;;; definition objects, and the wrappers are filled in last.

;; What a shell's class field holds until its metaclass exists.
(defvar *%bootstrap-placeholder* (vector :bootstrap))

(defun %bootstrap-shell (name)
  (let ((class (%allocate-standard-instance
                *%bootstrap-placeholder* nil
                (make-array (length *%class-layout*) :initial-element nil))))
    (setf (%class-ref class name) name)
    (%put name '%class class)
    class))

;; The initarg and default of each metaobject slot the protocol lets a
;; caller give. A slot not named here has neither and starts as nil.
(defparameter *%metaobject-slot-options*
  '((standard-slot-definition
     (name :name nil) (initform :initform nil) (initfunction :initfunction nil)
     (initargs :initargs nil) (readers :readers nil) (writers :writers nil)
     (type :type t) (allocation :allocation :instance)
     (documentation :documentation nil))
    (standard-method
     (specializers :specializers nil) (qualifiers :qualifiers nil)
     (lambda-list :lambda-list nil) (function :function nil)
     (documentation :documentation nil) (slot-definition :slot-definition nil))
    (standard-generic-function
     (name :name nil) (lambda-list :lambda-list nil)
     (method-class :method-class nil) (method-combination :method-combination nil)
     (argument-precedence-order :argument-precedence-order nil)
     (declarations :declarations nil) (documentation :documentation nil))
    (method-combination
     (name :name nil) (options :options nil) (type :type nil)
     (documentation :documentation nil))
    (eql-specializer (object :object nil))))

(defun %bootstrap-slot-spec (class-name slot-name)
  (let ((options (assoc slot-name (cdr (assoc class-name *%metaobject-slot-options*)))))
    (if options
        (let ((default (caddr options)))
          (list :name slot-name :initargs (list (cadr options))
                :initform default :initfunction (lambda () default)))
        (list :name slot-name :initform nil :initfunction (lambda () nil)))))

;; Each entry: name, metaclass, superclasses, direct slot names.
(defparameter *%bootstrap-hierarchy*
  `((t built-in-class () ())
    (standard-object standard-class (t) ())
    (function built-in-class (t) ())
    (metaobject standard-class (standard-object) ())
    (specializer standard-class (metaobject) ())
    (class standard-class (specializer) ,*%class-layout*)
    (built-in-class standard-class (class) ())
    (standard-class standard-class (class) ())
    (funcallable-standard-class standard-class (class) ())
    (forward-referenced-class standard-class (class) ())
    (structure-class standard-class (class) ())
    (condition-class standard-class (class) ())
    (eql-specializer standard-class (specializer) ,*%eql-layout*)
    (method standard-class (metaobject) ())
    (standard-method standard-class (method) ,*%method-layout*)
    (standard-accessor-method standard-class (standard-method) ())
    (standard-reader-method standard-class (standard-accessor-method) ())
    (standard-writer-method standard-class (standard-accessor-method) ())
    (method-combination standard-class (metaobject) ,*%combination-layout*)
    (slot-definition standard-class (metaobject) ())
    (direct-slot-definition standard-class (slot-definition) ())
    (effective-slot-definition standard-class (slot-definition) ())
    (standard-slot-definition standard-class (slot-definition) ,*%slotd-layout*)
    (standard-direct-slot-definition standard-class
     (standard-slot-definition direct-slot-definition) ())
    (standard-effective-slot-definition standard-class
     (standard-slot-definition effective-slot-definition) ())
    (funcallable-standard-object funcallable-standard-class (standard-object function) ())
    (generic-function funcallable-standard-class (metaobject funcallable-standard-object) ())
    (standard-generic-function funcallable-standard-class (generic-function) ,*%gf-layout*)))

(dolist (entry *%bootstrap-hierarchy*)
  (%bootstrap-shell (car entry)))

(setq *%the-class-class* (find-class 'class))

;;; --- slot definitions ---

(defun %make-slotd (class)
  (%allocate-standard-instance class (%class-ref class wrapper)
                               (%fresh-slots (length *%slotd-layout*))))

(defun %slot-option (spec key &optional default)
  (getf spec key default))

(defun %std-make-direct-slotd (class spec)
  "A direct slot definition from SPEC, a canonical slot description: a
plist of the options `defclass` was given for it."
  (let ((slotd (%make-slotd class)))
    (setf (%slotd-ref slotd name) (getf spec :name))
    (setf (%slotd-ref slotd initform) (%slot-option spec :initform))
    (setf (%slotd-ref slotd initfunction) (%slot-option spec :initfunction))
    (setf (%slotd-ref slotd initargs) (%slot-option spec :initargs))
    (setf (%slotd-ref slotd readers) (%slot-option spec :readers))
    (setf (%slotd-ref slotd writers) (%slot-option spec :writers))
    (setf (%slotd-ref slotd type) (%slot-option spec :type t))
    (setf (%slotd-ref slotd allocation) (%slot-option spec :allocation :instance))
    (setf (%slotd-ref slotd documentation) (%slot-option spec :documentation))
    (setf (%slotd-ref slotd location) nil)
    (setf (%slotd-ref slotd allocation-class) nil)
    slotd))

;;; --- class precedence lists ---

(defun %all-superclasses (class)
  "CLASS and every class above it, each once."
  (let ((seen nil))
    (labels ((walk (c)
               (unless (%memq c seen)
                 (push c seen)
                 (dolist (super (%class-ref c direct-superclasses))
                   (walk super)))))
      (walk class))
    (nreverse seen)))

(defun %std-compute-cpl (class)
  "CLHS 4.3.5: a topological sort of CLASS and its superclasses under each
class's local precedence order. Where several classes could come next,
the one with a direct subclass furthest right in the list built so far
is taken. A hierarchy with no such order is an error."
  (or (%topological-cpl class)
      (error "The superclasses of ~S have no consistent precedence order: ~S."
             (%class-ref class name)
             (mapcar (lambda (c) (%class-ref c name)) (%all-superclasses class)))))

;;; --- effective slots ---

(defun %slotd-names-in-order (class cpl)
  "The names of CLASS's slots: its first superclass's in that class's
order, then the rest from the least specific class down."
  (let* ((first (car (%class-ref class direct-superclasses)))
         (names (if (and first (%class-ref first finalized-p))
                    (mapcar (lambda (slotd) (%slotd-ref slotd name)) (%class-ref first slots))
                    nil)))
    (setq names (reverse names))
    (dolist (c (reverse cpl))
      (dolist (slotd (%class-ref c direct-slots))
        (unless (%memq (%slotd-ref slotd name) names)
          (push (%slotd-ref slotd name) names))))
    (nreverse names)))

(defun %std-compute-effective-slotd (class name direct-slotds)
  "CLHS 7.5.3: DIRECT-SLOTDS, most specific first, combined into one."
  (let ((slotd (%make-slotd (%effective-slotd-class class)))
        (initargs nil)
        (types nil)
        (most (car direct-slotds)))
    (setf (%slotd-ref slotd name) name)
    (setf (%slotd-ref slotd allocation) (%slotd-ref most allocation))
    (setf (%slotd-ref slotd initform) nil)
    (setf (%slotd-ref slotd initfunction) nil)
    (dolist (direct direct-slotds)
      (when (%slotd-ref direct initfunction)
        (setf (%slotd-ref slotd initform) (%slotd-ref direct initform))
        (setf (%slotd-ref slotd initfunction) (%slotd-ref direct initfunction))
        (return)))
    (setf (%slotd-ref slotd documentation)
          (dolist (direct direct-slotds nil)
            (when (%slotd-ref direct documentation)
              (return (%slotd-ref direct documentation)))))
    (dolist (direct direct-slotds)
      (dolist (initarg (%slotd-ref direct initargs))
        (unless (%memq initarg initargs) (push initarg initargs)))
      (unless (eq (%slotd-ref direct type) t)
        (push (%slotd-ref direct type) types)))
    (setf (%slotd-ref slotd initargs) (nreverse initargs))
    (setf (%slotd-ref slotd type)
          (cond ((null types) t)
                ((null (cdr types)) (car types))
                (t (cons 'and (nreverse types)))))
    (setf (%slotd-ref slotd readers) nil)
    (setf (%slotd-ref slotd writers) nil)
    (setf (%slotd-ref slotd location) nil)
    (setf (%slotd-ref slotd allocation-class)
          (if (eq (%slotd-ref most allocation) :class)
              (%slotd-ref most allocation-class)
              class))
    slotd))

(defun %direct-slotds-named (cpl name)
  (let ((found nil))
    (dolist (c cpl)
      (dolist (direct (%class-ref c direct-slots))
        (when (eq (%slotd-ref direct name) name)
          (push direct found))))
    (nreverse found)))

(defun %std-compute-slots (class)
  (let ((cpl (%class-ref class precedence-list)))
    (mapcar (lambda (name)
              (if *%clos-booted*
                  (compute-effective-slot-definition class name (%direct-slotds-named cpl name))
                  (%std-compute-effective-slotd class name (%direct-slotds-named cpl name))))
            (%slotd-names-in-order class cpl))))

(defun %effective-slotd-class (class)
  (if *%clos-booted*
      (effective-slot-definition-class class)
      (find-class 'standard-effective-slot-definition)))

;;; --- finalization ---

(defun %std-compute-default-initargs (class)
  (let ((result nil))
    (dolist (c (%class-ref class precedence-list))
      (dolist (entry (%class-ref c direct-default-initargs))
        (unless (find (car entry) result :key #'car :test #'eq)
          (push entry result))))
    (nreverse result)))

(defun %assign-slot-locations (class slots)
  "Number the instance slots and give each class slot the cell of the
class its definition belongs to. Returns the instance slots' names."
  (let ((index 0)
        (names nil)
        (table (make-hash-table :test #'eq)))
    (dolist (slotd slots)
      (if (eq (%slotd-ref slotd allocation) :instance)
          (progn
            (setf (%slotd-ref slotd location) index)
            (push (%slotd-ref slotd name) names)
            (setq index (1+ index)))
          (setf (%slotd-ref slotd location)
                (%class-slot-cell (%slotd-ref slotd allocation-class) (%slotd-ref slotd name))))
      (setf (gethash (%slotd-ref slotd name) table) slotd))
    (setf (%class-ref class slot-table) table)
    (nreverse names)))

(defun %class-slot-cell (class name)
  "The cell holding the value of the class slot NAME that CLASS defines.
A redefinition that keeps the slot shared keeps the cell, and with it
the value."
  (let ((cells (getf (%class-ref class plist) :class-slot-cells)))
    (or (cdr (assoc name cells))
        (let ((cell (cons name *%slot-unbound*)))
          (setf (getf (%class-ref class plist) :class-slot-cells)
                (acons name cell cells))
          cell))))

(defun %forward-referenced-p (class)
  (eq (%instance-class class) (find-class 'forward-referenced-class)))

(defun %finalizable-p (class)
  (every (lambda (super)
           (and (not (%forward-referenced-p super))
                (or (%class-ref super finalized-p) (%finalizable-p super))))
         (%class-ref class direct-superclasses)))

(defun %class-shared-slot-names (class)
  (let ((names nil))
    (dolist (slotd (%class-ref class slots))
      (unless (eq (%slotd-ref slotd allocation) :instance)
        (push (%slotd-ref slotd name) names)))
    names))

(defun %std-finalize-inheritance (class)
  (dolist (super (%class-ref class direct-superclasses))
    (unless (%class-ref super finalized-p)
      (if *%clos-booted* (finalize-inheritance super) (%std-finalize-inheritance super))))
  (let* ((cpl (if *%clos-booted*
                  (compute-class-precedence-list class)
                  (%std-compute-cpl class)))
         (old-names (let ((wrapper (%class-ref class wrapper)))
                      (and wrapper (car wrapper))))
         (old-cpl (%class-ref class precedence-list)))
    (when (and (%class-ref class finalized-p) (not (equal cpl old-cpl)))
      (setq *%dispatch-epoch* (1+ *%dispatch-epoch*)))
    (setf (%class-ref class precedence-list) cpl)
    (let* ((slots (if *%clos-booted* (compute-slots class) (%std-compute-slots class)))
           (names (%assign-slot-locations class slots)))
      (setf (%class-ref class slots) slots)
      (setf (%class-ref class default-initargs)
            (if *%clos-booted*
                (compute-default-initargs class)
                (%std-compute-default-initargs class)))
      (when (or (null (%class-ref class wrapper))
                (not (equal names old-names)))
        (setf (%class-ref class wrapper) (list names (%class-shared-slot-names class))))
      (setf (%class-ref class finalized-p) t)
      (setf (%class-ref class prototype) nil)
      (setq *%class-epoch* (1+ *%class-epoch*))
      (%clear-class-caches class)
      class)))

(defun %clear-class-caches (class)
  (setf (getf (%class-ref class plist) :initargs-cache) nil)
  (setf (getf (%class-ref class plist) :fast-init) nil))

(defun %refinalize-subclasses (class)
  "After CLASS changes, the classes below it that were finalized are
finalized again, so their precedence lists and slots follow."
  (dolist (sub (%class-ref class direct-subclasses))
    (when (%class-ref sub finalized-p)
      (if *%clos-booted* (finalize-inheritance sub) (%std-finalize-inheritance sub))
      (%refinalize-subclasses sub))))

;;; --- finishing the bootstrap ---

(dolist (entry *%bootstrap-hierarchy*)
  (destructuring-bind (name metaclass supers slot-names) entry
    (let ((class (find-class name)))
      (%set-instance-layout class (find-class metaclass) nil (%instance-slots class))
      (setf (%class-ref class direct-superclasses) (mapcar #'find-class supers))
      (dolist (super (%class-ref class direct-superclasses))
        (push class (%class-ref super direct-subclasses)))
      (setf (%class-ref class direct-slots)
            (mapcar (lambda (slot-name)
                      (%std-make-direct-slotd (find-class 'standard-direct-slot-definition)
                                              (%bootstrap-slot-spec name slot-name)))
                    slot-names)))))

(dolist (entry *%bootstrap-hierarchy*)
  (%std-finalize-inheritance (find-class (car entry))))

;; Every metaobject above was made before the class it is an instance of
;; had a wrapper.
(defun %fix-wrapper (object)
  (%set-instance-layout object (%instance-class object)
                        (%class-ref (%instance-class object) wrapper)
                        (%instance-slots object)))

(dolist (entry *%bootstrap-hierarchy*)
  (let ((class (find-class (car entry))))
    (%fix-wrapper class)
    (dolist (slotd (%class-ref class direct-slots)) (%fix-wrapper slotd))
    (dolist (slotd (%class-ref class slots)) (%fix-wrapper slotd))))

(defvar *%the-class-t* (find-class t))
(defvar *%the-class-standard-class* (find-class 'standard-class))
(defvar *%the-class-funcallable-standard-class* (find-class 'funcallable-standard-class))
(defvar *%the-class-standard-generic-function* (find-class 'standard-generic-function))
(defvar *%the-class-standard-method* (find-class 'standard-method))
(defvar *%the-class-eql-specializer* (find-class 'eql-specializer))

;;; --- instances ---

(defun %funcallable-class-p (class)
  (%subclassp (%instance-class class) *%the-class-funcallable-standard-class*))

(defun %uncallable-instance (&rest arguments)
  (declare (ignore arguments))
  (error "This funcallable instance has no function yet."))

(defun %std-allocate-instance (class)
  (unless (%class-ref class finalized-p)
    (if *%clos-booted* (finalize-inheritance class) (%std-finalize-inheritance class)))
  (let* ((wrapper (%class-ref class wrapper))
         (slots (%fresh-slots (length (car wrapper)))))
    (if (%funcallable-class-p class)
        (let ((instance (%allocate-funcallable-instance class wrapper slots)))
          (%set-funcallable-instance-function instance #'%uncallable-instance)
          instance)
        (%allocate-standard-instance class wrapper slots))))

(defun %std-initialize-from-defaults (instance)
  "Fill every slot of a fresh metaobject that has an initform, which is
what `shared-initialize` would do. Used until it exists."
  (dolist (slotd (%class-ref (%instance-class instance) slots))
    (let ((location (%slotd-ref slotd location))
          (initfunction (%slotd-ref slotd initfunction)))
      (when (and (integerp location) initfunction)
        (setf (svref (%instance-slots instance) location)
              (%initial-value (%slotd-ref slotd initform) initfunction)))))
  instance)

;;; --- lambda lists ---

(defun %keyword-of (key-parameter)
  (let ((head (if (consp key-parameter) (car key-parameter) key-parameter)))
    (if (consp head)
        (car head)
        (intern (symbol-name head) "KEYWORD"))))

(defun %lambda-list-keywords-accepted (lambda-list)
  "The keywords LAMBDA-LIST accepts, or t where it accepts any."
  (destructuring-bind (required optional rest keys allow key-p) (%parse-lambda-list lambda-list)
    (declare (ignore required optional rest))
    (cond (allow t)
          (key-p (mapcar #'%keyword-of keys))
          (t nil))))

(defun %required-count (lambda-list)
  (length (car (%parse-lambda-list lambda-list))))

;;; --- specializers ---

(defvar *%eql-specializers* (make-hash-table :test #'eql))

(defun intern-eql-specializer (object)
  (or (gethash object *%eql-specializers*)
      (let ((specializer (%std-allocate-instance *%the-class-eql-specializer*)))
        (setf (%eql-ref specializer object) object)
        (setf (%eql-ref specializer direct-methods) nil)
        (setf (gethash object *%eql-specializers*) specializer))))

(defun %eql-specializer-p (x)
  (%direct-instance-p x *%the-class-eql-specializer*))

(defun eql-specializer-object (specializer)
  (%eql-ref specializer object))

(defun %specializer-direct-methods (specializer)
  (if (%eql-specializer-p specializer)
      (%eql-ref specializer direct-methods)
      (%class-ref specializer direct-methods)))

(defun %add-direct-method (specializer method)
  (if (%eql-specializer-p specializer)
      (pushnew method (%eql-ref specializer direct-methods))
      (pushnew method (%class-ref specializer direct-methods))))

(defun %remove-direct-method (specializer method)
  (if (%eql-specializer-p specializer)
      (setf (%eql-ref specializer direct-methods)
            (remove method (%eql-ref specializer direct-methods)))
      (setf (%class-ref specializer direct-methods)
            (remove method (%class-ref specializer direct-methods)))))

(defun %resolve-specializer (designator)
  (cond ((%instance-p designator) designator)
        ((and (consp designator) (eq (car designator) 'eql))
         (intern-eql-specializer (cadr designator)))
        ((symbolp designator) (find-class designator))
        (t (error "~S is not a specializer." designator))))

;;; --- methods ---

(defun %method-function-of (method)
  "What a call to METHOD runs: its function, or METHOD itself where an
effective method made it as a plain function."
  (if (functionp method) method (%method-ref method function)))

(defun %invoke-method (method arguments next-methods)
  (funcall (%method-function-of method) arguments next-methods))

(defun %method-qualifiers (method) (%method-ref method qualifiers))
(defun %method-specializers (method) (%method-ref method specializers))

(defun %std-make-method (class qualifiers lambda-list specializers documentation function)
  (let ((method (%std-allocate-instance class)))
    (%std-initialize-from-defaults method)
    (setf (%method-ref method qualifiers) qualifiers)
    (setf (%method-ref method lambda-list) lambda-list)
    (setf (%method-ref method specializers) specializers)
    (setf (%method-ref method documentation) documentation)
    (setf (%method-ref method function) function)
    (setf (%method-ref method generic-function) nil)
    method))

;;; --- generic functions ---

(defun %std-make-generic-function (name lambda-list)
  (let ((gf (%std-allocate-instance *%the-class-standard-generic-function*)))
    (%std-initialize-from-defaults gf)
    (setf (%gf-ref gf name) name)
    (setf (%gf-ref gf lambda-list) lambda-list)
    (setf (%gf-ref gf method-class) *%the-class-standard-method*)
    (setf (%gf-ref gf method-combination) nil)
    (%finish-generic-function gf)
    gf))

(defun %finish-generic-function (gf)
  "Make GF callable and work out what its dispatch looks at."
  (unless (%gf-ref gf method-class)
    (setf (%gf-ref gf method-class) *%the-class-standard-method*))
  (unless (%gf-ref gf method-combination)
    (setf (%gf-ref gf method-combination) *%standard-method-combination*))
  (%update-dispatch-info gf)
  (%set-funcallable-instance-function gf (%make-discriminator gf))
  (when (%gf-ref gf name)
    (%set-function-name gf (%gf-ref gf name)))
  gf)

(defun %make-discriminator (gf)
  (lambda (&rest arguments) (%gf-dispatch gf arguments)))

(defun %gf-precedence-positions (gf)
  "The required argument positions in the order specificity compares them."
  (let* ((lambda-list (%gf-ref gf lambda-list))
         (required (car (%parse-lambda-list lambda-list)))
         (order (%gf-ref gf argument-precedence-order)))
    (if order
        (mapcar (lambda (name) (position name required)) order)
        (let ((positions nil))
          (dotimes (i (length required)) (push i positions))
          (nreverse positions)))))

(defun %update-dispatch-info (gf)
  (let ((positions nil)
        (eqls nil)
        (lambda-list (%gf-ref gf lambda-list)))
    (dolist (method (%gf-ref gf methods))
      (let ((index 0))
        (dolist (specializer (%method-ref method specializers))
          (unless (eq specializer *%the-class-t*)
            (pushnew index positions))
          (when (%eql-specializer-p specializer)
            (let ((entry (assoc index eqls)))
              (if entry
                  (pushnew specializer (cdr entry))
                  (push (list index specializer) eqls))))
          (setq index (1+ index)))))
    (setf (%gf-ref gf dispatch-positions) (sort positions #'<))
    (setf (%gf-ref gf eql-positions) eqls)
    (setf (%gf-ref gf required-count) (%required-count lambda-list))
    (setf (%gf-ref gf argument-limit)
          (destructuring-bind (required optional rest keys allow key-p) (%parse-lambda-list lambda-list)
            (declare (ignore keys allow))
            (if (or rest key-p) nil (+ (length required) (length optional)))))
    (setf (%gf-ref gf keyword-info) (%gf-keyword-info gf))
    (setf (%gf-ref gf cache) nil)))

(defun %gf-keyword-info (gf)
  "Where GF's keyword arguments start and what its own lambda list
accepts, or nil where it takes no keywords."
  (destructuring-bind (required optional rest keys allow key-p)
      (%parse-lambda-list (%gf-ref gf lambda-list))
    (declare (ignore rest))
    (if key-p
        (list (+ (length required) (length optional))
              (if allow t (mapcar #'%keyword-of keys)))
        nil)))

;;; --- dispatch ---

(defun %dispatch-key (gf position argument)
  (let ((eqls (cdr (assoc position (%gf-ref gf eql-positions)))))
    (or (and eqls
             (dolist (specializer eqls nil)
               (when (eql (%eql-ref specializer object) argument)
                 (return specializer))))
        (%class-of argument))))

(defun %gf-dispatch-miss (gf arguments)
  "What `%gf-dispatch` does when its cache has nothing for ARGUMENTS:
check them, work out the effective method, keep it, and run it."
  (let ((required (%gf-ref gf required-count))
        (limit (%gf-ref gf argument-limit)))
    (when (and (> required 0) (null (nthcdr (1- required) arguments)))
      (%program-error "~S needs ~D arguments, given ~S."
                      (%gf-ref gf name) required arguments))
    (when (and limit (nthcdr limit arguments))
      (%program-error "~S takes at most ~D arguments, given ~S."
                      (%gf-ref gf name) limit arguments)))
  (unless (eql (%gf-ref gf epoch) *%dispatch-epoch*)
    (setf (%gf-ref gf cache) nil)
    (setf (%gf-ref gf epoch) *%dispatch-epoch*))
  (if (not (eq (%instance-class gf) *%the-class-standard-generic-function*))
      (funcall (%compute-emfun gf arguments) arguments)
      (let ((positions (%gf-ref gf dispatch-positions)))
        (if (null positions)
            (funcall (or (%gf-ref gf cache)
                         (setf (%gf-ref gf cache) (%compute-emfun gf arguments)))
                     arguments)
            (let ((node (or (%gf-ref gf cache)
                            (setf (%gf-ref gf cache) (make-hash-table :test #'eq)))))
              (loop
                (let* ((position (car positions))
                       (key (%dispatch-key gf position (nth position arguments))))
                  (if (null (cdr positions))
                      (return
                        (funcall (or (gethash key node)
                                     (setf (gethash key node) (%compute-emfun gf arguments)))
                                 arguments))
                      (setq node (or (gethash key node)
                                     (setf (gethash key node) (make-hash-table :test #'eq)))
                            positions (cdr positions))))))))))

(defun %specializer-applicable-p (specializer argument)
  (if (%eql-specializer-p specializer)
      (eql (%eql-ref specializer object) argument)
      (%subclassp (%class-of argument) specializer)))

(defun %method-applicable-p (method arguments)
  (let ((rest arguments))
    (dolist (specializer (%method-ref method specializers) t)
      (unless (%specializer-applicable-p specializer (car rest))
        (return nil))
      (setq rest (cdr rest)))))

(defun %more-specific-p (method other arguments positions)
  "CLHS 7.6.6.1.2: whether METHOD precedes OTHER for ARGUMENTS."
  (dolist (position positions nil)
    (let ((a (nth position (%method-ref method specializers)))
          (b (nth position (%method-ref other specializers))))
      (unless (eq a b)
        (return (cond ((%eql-specializer-p a) t)
                      ((%eql-specializer-p b) nil)
                      (t (%class-precedes-p a b (%class-of (nth position arguments))))))))))

(defun %more-specific-by-classes-p (method other classes positions)
  (dolist (position positions nil)
    (let ((a (nth position (%method-ref method specializers)))
          (b (nth position (%method-ref other specializers))))
      (unless (eq a b)
        (return (%class-precedes-p a b (nth position classes)))))))

(defun %class-precedes-p (class other subclass)
  "Whether CLASS comes before OTHER in SUBCLASS's precedence list."
  (not (null (%memq other (cdr (%memq class (%class-precedence subclass)))))))

(defun %std-compute-applicable-methods (gf arguments)
  (let ((applicable nil)
        (positions (%gf-precedence-positions gf)))
    (dolist (method (%gf-ref gf methods))
      (when (%method-applicable-p method arguments)
        (push method applicable)))
    (stable-sort (nreverse applicable)
                 (lambda (a b) (%more-specific-p a b arguments positions)))))

(defun %compute-emfun (gf arguments)
  (let ((methods (if (eq (%instance-class gf) *%the-class-standard-generic-function*)
                     (%std-compute-applicable-methods gf arguments)
                     (compute-applicable-methods gf arguments))))
    (if (null methods)
        (lambda (arguments) (apply #'no-applicable-method gf arguments))
        (%keyword-checked gf methods (%effective-method-function gf methods)))))

(defun %keyword-checked (gf methods emfun)
  "EMFUN, checking first that each keyword argument is one GF or one of
METHODS accepts (CLHS 7.6.5)."
  (let ((info (%gf-ref gf keyword-info)))
    (if (or (null info) (eq (cadr info) t))
        emfun
        (let ((accepted (cadr info))
              (start (car info)))
          (dolist (method methods)
            (let ((more (%lambda-list-keywords-accepted (%method-ref method lambda-list))))
              (when (eq more t) (return-from %keyword-checked emfun))
              (setq accepted (append more accepted))))
          (lambda (arguments)
            (let ((keys (nthcdr start arguments)))
              (unless (getf keys :allow-other-keys)
                (do ((walk keys (cddr walk)))
                    ((null walk))
                  (unless (or (%memq (car walk) accepted) (eq (car walk) :allow-other-keys))
                    (error 'program-error
                           :format-control "~S is not a keyword ~S accepts."
                           :format-arguments (list (car walk) (%gf-ref gf name)))))))
            (funcall emfun arguments))))))

;;; --- effective methods ---

(defvar *%standard-method-combination* nil)

(defun %split-standard-methods (gf methods)
  "METHODS, most specific first, as their standard roles: arounds and
befores most specific first, primaries the same, afters least specific
first."
  (let ((around nil) (before nil) (primary nil) (after nil))
    (dolist (method methods)
      (let ((qualifiers (%method-ref method qualifiers)))
        (cond ((null qualifiers) (push method primary))
              ((and (null (cdr qualifiers)) (eq (car qualifiers) :around)) (push method around))
              ((and (null (cdr qualifiers)) (eq (car qualifiers) :before)) (push method before))
              ((and (null (cdr qualifiers)) (eq (car qualifiers) :after)) (push method after))
              (t (%invalid-method gf method)))))
    (values (nreverse around) (nreverse before) (nreverse primary) after)))

(defun %invalid-method (gf method)
  (error "~S has qualifiers ~S, which the method combination of ~S does not accept."
         method (%method-ref method qualifiers) (%gf-ref gf name)))

(defun %no-primary-method (gf)
  (lambda (arguments)
    (error "No primary method of ~S applies to ~S." (%gf-ref gf name) arguments)))

(defun %std-emfun (gf methods)
  (multiple-value-bind (around before primary after) (%split-standard-methods gf methods)
    (if (null primary)
        (%no-primary-method gf)
        (let ((main
                (let ((first (%method-function-of (car primary)))
                      (next (cdr primary)))
                  (if (and (null before) (null after))
                      (lambda (arguments) (funcall first arguments next))
                      (lambda (arguments)
                        (dolist (method before)
                          (funcall (%method-function-of method) arguments nil))
                        (multiple-value-prog1 (funcall first arguments next)
                          (dolist (method after)
                            (funcall (%method-function-of method) arguments nil))))))))
          (if (null around)
              main
              (let ((first (%method-function-of (car around)))
                    (next (append (cdr around)
                                  (list (lambda (arguments next-methods)
                                          (declare (ignore next-methods))
                                          (funcall main arguments))))))
                (lambda (arguments) (funcall first arguments next))))))))

(defun %standard-combination-form (gf methods)
  (multiple-value-bind (around before primary after) (%split-standard-methods gf methods)
    (if (null primary)
        `(%signal-no-primary-method ',gf)
        (let ((main (if (or before after)
                        `(progn ,@(mapcar (lambda (m) `(call-method ,m)) before)
                                (multiple-value-prog1 (call-method ,(car primary) ,(cdr primary))
                                  ,@(mapcar (lambda (m) `(call-method ,m)) after)))
                        `(call-method ,(car primary) ,(cdr primary)))))
          (if around
              `(call-method ,(car around) (,@(cdr around) (make-method ,main)))
              main)))))

(defun %signal-no-primary-method (gf)
  (error "No primary method of ~S applies." (%gf-ref gf name)))

(defun %standard-combination-p (combination)
  (eq combination *%standard-method-combination*))

(defun %effective-method-function (gf methods)
  (let ((combination (%gf-ref gf method-combination))
        (standard-gf (eq (%instance-class gf) *%the-class-standard-generic-function*)))
    (if (and standard-gf (%standard-combination-p combination))
        (%std-emfun gf methods)
        (%emfun-from-form
         (if standard-gf
             (%std-compute-effective-method gf combination methods)
             (compute-effective-method gf combination methods))))))

(defun %std-compute-effective-method (gf combination methods)
  (funcall (%combination-ref combination type) gf combination methods))

(defun %next-method-form (next)
  (if (and (consp next) (eq (car next) 'make-method))
      `(lambda (%em-arguments %em-next)
         (declare (ignore %em-next) (ignorable %em-arguments))
         ,(%expand-effective-form (cadr next)))
      `',next))

(defun %call-method-expansion (method next-methods)
  (if (and (consp method) (eq (car method) 'make-method))
      (%expand-effective-form (cadr method))
      `(%invoke-method ',method %em-arguments
                       (list ,@(mapcar #'%next-method-form next-methods)))))

(defun %expand-effective-form (form)
  `(macrolet ((call-method (method &optional next-methods)
                (%call-method-expansion method next-methods))
              (make-method (form)
                (declare (ignore form))
                (error "make-method appears outside call-method.")))
     ,form))

(defun %emfun-from-form (form)
  "The function an effective method form comes to. A form that is one
`call-method` is called directly rather than evaluated."
  (if (and (consp form) (eq (car form) 'call-method)
           (not (and (consp (cadr form)) (eq (car (cadr form)) 'make-method)))
           (every (lambda (next) (not (consp next))) (caddr form)))
      (let ((function (%method-function-of (cadr form)))
            (next (caddr form)))
        (lambda (arguments) (funcall function arguments next)))
      (eval `(lambda (%em-arguments)
               (declare (ignorable %em-arguments))
               ,(%expand-effective-form form)))))

;;; --- congruence ---

(defun %program-error (control &rest arguments)
  (error '%simple-program-error :format-control control :format-arguments arguments))

(defun %check-congruent (gf method)
  "CLHS 7.6.4: METHOD's lambda list has to agree with GF's."
  (let ((gf-list (%gf-ref gf lambda-list)))
    (when gf-list
      (destructuring-bind (g-required g-optional g-rest g-keys g-allow g-key-p)
          (%parse-lambda-list gf-list)
        (declare (ignore g-allow))
        (destructuring-bind (m-required m-optional m-rest m-keys m-allow m-key-p)
            (%parse-lambda-list (%method-ref method lambda-list))
          (declare (ignore m-keys))
          (unless (= (length g-required) (length m-required))
            (%program-error "~S has ~D required parameters where ~S has ~D."
                            method (length m-required) (%gf-ref gf name) (length g-required)))
          (unless (= (length g-optional) (length m-optional))
            (%program-error "~S has ~D optional parameters where ~S has ~D."
                            method (length m-optional) (%gf-ref gf name) (length g-optional)))
          (unless (eq (not (or g-rest g-key-p)) (not (or m-rest m-key-p)))
            (%program-error "~S and ~S disagree on taking &rest or &key."
                            method (%gf-ref gf name)))
          (when g-key-p
            (unless (or m-rest m-allow m-key-p)
              (%program-error "~S takes no keyword arguments where ~S does."
                              method (%gf-ref gf name)))
            (let ((accepted (%lambda-list-keywords-accepted (%method-ref method lambda-list))))
              (unless (or (eq accepted t) m-rest)
                (dolist (key g-keys)
                  (unless (%memq (%keyword-of key) accepted)
                    (%program-error "~S does not accept the keyword ~S that ~S names."
                                    method (%keyword-of key) (%gf-ref gf name))))))))))))

;;; --- adding and removing methods ---

;; The generic functions whose methods decide how an instance is made.
;; A method added to one of them makes every class work out again
;; whether it can take the direct route.
(defvar *%initialization-epoch* 0)
(defvar *%initialization-functions*
  '(make-instance allocate-instance initialize-instance shared-initialize
    reinitialize-instance))

(defun %find-method-same (gf qualifiers specializers)
  (dolist (method (%gf-ref gf methods) nil)
    (when (and (equal (%method-ref method qualifiers) qualifiers)
               (equal (%method-ref method specializers) specializers))
      (return method))))

(defun %std-add-method (gf method)
  (let ((owner (%method-ref method generic-function)))
    (when (and owner (not (eq owner gf)))
      (error "~S already belongs to ~S." method (%gf-ref owner name))))
  (if (null (%gf-ref gf lambda-list))
      (setf (%gf-ref gf lambda-list) (%gf-lambda-list-from-method (%method-ref method lambda-list)))
      (%check-congruent gf method))
  (let ((old (%find-method-same gf (%method-ref method qualifiers) (%method-ref method specializers))))
    (when old (%std-remove-method gf old)))
  (setf (%method-ref method generic-function) gf)
  (push method (%gf-ref gf methods))
  (dolist (specializer (%method-ref method specializers))
    (%add-direct-method specializer method))
  (%methods-changed gf)
  gf)

(defun %std-remove-method (gf method)
  (when (%memq method (%gf-ref gf methods))
    (setf (%gf-ref gf methods) (remove method (%gf-ref gf methods)))
    (setf (%method-ref method generic-function) nil)
    (dolist (specializer (%method-ref method specializers))
      (%remove-direct-method specializer method))
    (%methods-changed gf))
  gf)

(defun %methods-changed (gf)
  (%update-dispatch-info gf)
  (when (%memq (%gf-ref gf name) *%initialization-functions*)
    (setq *%initialization-epoch* (1+ *%initialization-epoch*)))
  (%gf-dependents-changed gf))

(defun %gf-dependents-changed (gf)
  (declare (ignore gf))
  nil)

(defun %gf-lambda-list-from-method (lambda-list)
  "The lambda list `defmethod` gives a generic function it creates: the
method's with the specializers dropped, and its keyword parameters kept
by name only."
  (destructuring-bind (required optional rest keys allow key-p) (%parse-lambda-list lambda-list)
    (append (mapcar (lambda (p) (if (consp p) (car p) p)) required)
            (when optional
              (cons '&optional (mapcar (lambda (p) (if (consp p) (car p) p)) optional)))
            (when rest (list '&rest rest))
            (when key-p
              (cons '&key (mapcar (lambda (p)
                                    (let ((head (if (consp p) (car p) p)))
                                      (if (consp head) (list head) head)))
                                  keys)))
            (when allow (list '&allow-other-keys)))))

;;; --- ensure-generic-function ---

(defun %generic-function-p (object)
  (and (%funcallable-instance-p object)
       (%subclassp (%instance-class object) (find-class 'generic-function))))

(defun %existing-generic-function (name)
  (when (and (fboundp name)
             (not (and (symbolp name) (or (special-operator-p name) (macro-function name)))))
    (let ((function (fdefinition name)))
      (if (%generic-function-p function)
          function
          nil))))

(defun %function-name-symbol (name)
  (if (consp name) (cadr name) name))

(defun %check-redefinable-as-generic (name)
  (when (and (symbolp name) (or (special-operator-p name) (macro-function name)))
    (%program-error "~S names a macro or special operator, so it cannot be a generic function."
                    name))
  (when (and (fboundp name) (not (%generic-function-p (fdefinition name))))
    (%program-error "~S names an ordinary function, so it cannot be a generic function."
                    name)))

(defun %std-ensure-generic-function (name &key (lambda-list nil lambda-list-p)
                                             (generic-function-class nil class-p)
                                             (method-class nil method-class-p)
                                             (method-combination nil combination-p)
                                             (argument-precedence-order nil order-p)
                                             (declarations nil declarations-p)
                                             (documentation nil documentation-p)
                                        &allow-other-keys)
  (let ((existing (%existing-generic-function name)))
    (unless existing (%check-redefinable-as-generic name))
    (cond ((and (not *%clos-booted*) (null existing))
           (let ((gf (%std-make-generic-function name lambda-list)))
             (setf (fdefinition name) gf)
             gf))
          ((null existing)
           (let ((gf (make-instance (if class-p
                                        (%as-class generic-function-class)
                                        *%the-class-standard-generic-function*)
                                    :name name :lambda-list lambda-list
                                    :method-class (and method-class (%as-class method-class))
                                    :method-combination method-combination
                                    :argument-precedence-order argument-precedence-order
                                    :declarations declarations
                                    :documentation documentation)))
             (setf (fdefinition name) gf)
             gf))
          (t
           (when (and class-p (not (eq (%instance-class existing) (%as-class generic-function-class))))
             (change-class existing (%as-class generic-function-class)))
           (when lambda-list-p
             (setf (%gf-ref existing lambda-list) lambda-list)
             (dolist (method (%gf-ref existing methods))
               (%check-congruent existing method)))
           (when (and method-class-p method-class)
             (setf (%gf-ref existing method-class) (%as-class method-class)))
           (when combination-p
             (setf (%gf-ref existing method-combination)
                   (or method-combination *%standard-method-combination*)))
           (when order-p (setf (%gf-ref existing argument-precedence-order) argument-precedence-order))
           (when declarations-p (setf (%gf-ref existing declarations) declarations))
           (when documentation-p (setf (%gf-ref existing documentation) documentation))
           (%update-dispatch-info existing)
           existing))))

(defun %as-class (designator)
  (if (symbolp designator) (find-class designator) designator))

(defun ensure-generic-function (name &rest options &key environment &allow-other-keys)
  (declare (ignore environment))
  (apply #'%std-ensure-generic-function name options))

;;; --- defgeneric ---

(defun %defgeneric-option-check (options)
  (let ((seen nil))
    (dolist (option options)
      (unless (and (consp option)
                   (%memq (car option) '(:argument-precedence-order declare :documentation
                                         :method-combination :generic-function-class
                                         :method-class :method)))
        (%program-error "~S is not a defgeneric option." option))
      (unless (%memq (car option) '(:method declare))
        (when (%memq (car option) seen)
          (%program-error "The defgeneric option ~S is given twice." (car option)))
        (push (car option) seen)))))

(defun %check-generic-lambda-list (lambda-list)
  (let ((seen nil) (state :required))
    (dolist (item lambda-list)
      (cond ((%memq item '(&optional &rest &key &allow-other-keys))
             (setq state item))
            ((%lambda-list-keyword-p item)
             (%program-error "~S cannot appear in a generic function lambda list." item))
            (t
             (let ((name (cond ((symbolp item) item)
                               ((and (consp item) (%memq state '(&optional &key)) (null (cdr item)))
                                (if (consp (car item)) (cadar item) (car item)))
                               (t (%program-error "~S cannot appear in a generic function lambda list."
                                                  item)))))
               (when (%memq name seen)
                 (%program-error "~S appears twice in ~S." name lambda-list))
               (push name seen)))))))

(defun %check-precedence-order (lambda-list order)
  "An :argument-precedence-order has to name each required parameter once."
  (when order
    (let ((required (car (%parse-lambda-list lambda-list))))
      (unless (and (= (length order) (length required))
                   (every (lambda (name) (%memq name required)) order)
                   (every (lambda (name) (%memq name order)) required))
        (%program-error "~S does not order the required parameters ~S." order required)))))

(defmacro defgeneric (name lambda-list &rest options)
  (%defgeneric-option-check options)
  (%check-generic-lambda-list lambda-list)
  (%check-precedence-order lambda-list (cdr (assoc :argument-precedence-order options)))
  (let ((methods (remove-if-not (lambda (o) (eq (car o) :method)) options))
        (combination (cdr (assoc :method-combination options)))
        (gf-class (cadr (assoc :generic-function-class options)))
        (method-class (cadr (assoc :method-class options)))
        (documentation (cadr (assoc :documentation options)))
        (order (cdr (assoc :argument-precedence-order options)))
        (declarations (mapcan (lambda (o) (if (eq (car o) 'declare) (copy-list (cdr o)) nil))
                              options)))
    `(progn
       (%defgeneric ',name ',lambda-list
                    :method-combination ',combination
                    ,@(when gf-class `(:generic-function-class ',gf-class))
                    :method-class ',method-class
                    :documentation ',documentation
                    :argument-precedence-order ',order
                    :declarations ',declarations)
       (%set-initial-methods
        ',name
        (list ,@(mapcar (lambda (option) `(defmethod ,name ,@(cdr option))) methods)))
       (fdefinition ',name))))

(defun %defgeneric (name lambda-list &rest options &key method-combination &allow-other-keys)
  (let ((existing (%existing-generic-function name)))
    ;; Methods an earlier evaluation of this defgeneric defined go away.
    (when existing
      (dolist (method (getf (%gf-ref existing plist) :initial-methods))
        (%remove-method-generic existing method))))
  (apply #'%std-ensure-generic-function name
         :lambda-list lambda-list
         :method-combination (%find-method-combination name method-combination)
         options))

(defun %set-initial-methods (name methods)
  (setf (getf (%gf-ref (fdefinition name) plist) :initial-methods) methods))

(defun %remove-method-generic (gf method)
  (if *%clos-booted* (remove-method gf method) (%std-remove-method gf method)))

(defun %add-method-generic (gf method)
  (if *%clos-booted* (add-method gf method) (%std-add-method gf method)))

;;; --- defmethod ---

(defun %parse-defmethod (rest)
  "The qualifiers, the lambda list, and the body of a defmethod's REST."
  (let ((qualifiers nil))
    (loop
      (when (listp (car rest)) (return))
      (push (car rest) qualifiers)
      (setq rest (cdr rest)))
    (values (nreverse qualifiers) (car rest) (cdr rest))))

(defun %split-specialized (lambda-list)
  "The plain lambda list and the specializer designators of a specialized
one. A designator is a class name, or an `(eql form)` with the form left
to evaluate."
  (let ((plain nil) (specializers nil) (required t))
    (dolist (item lambda-list)
      (cond ((%lambda-list-keyword-p item)
             (setq required nil)
             (push item plain))
            (required
             (if (consp item)
                 (progn
                   (unless (and (symbolp (car item)) (consp (cdr item)) (null (cddr item)))
                     (%program-error "~S is not a specialized parameter." item))
                   (push (car item) plain)
                   (push (cadr item) specializers))
                 (progn
                   (push item plain)
                   (push t specializers))))
            (t (push item plain))))
    (values (nreverse plain) (nreverse specializers))))

(defun %specializer-form (designator)
  (if (and (consp designator) (eq (car designator) 'eql))
      `(list 'eql ,(cadr designator))
      `',designator))

(defun %body-parts (body)
  "BODY as its docstring, its declarations and its forms."
  (let ((documentation nil) (declarations nil))
    (loop
      (cond ((and (stringp (car body)) (cdr body) (null documentation))
             (setq documentation (car body)))
            ((and (consp (car body)) (eq (caar body) 'declare))
             (push (car body) declarations))
            (t (return)))
      (setq body (cdr body)))
    (values documentation (nreverse declarations) body)))

(defun %method-lambda-list (plain)
  "PLAIN, accepting any keyword where it accepts some: the generic
function decides which keywords are valid (CLHS 7.6.5)."
  (if (and (%memq '&key plain) (not (%memq '&allow-other-keys plain)))
      (let ((aux (%memq '&aux plain)))
        (append (ldiff plain aux) (list '&allow-other-keys) aux))
      plain))

(defun %make-method-lambda (name plain specializers body)
  "The function of the method, made from the method: a function of the
argument list and the next methods. Its body reaches `call-next-method`
and `next-method-p` through the global macros of those names, which read
the variables bound here, unless it takes one as a function object, when
they are local functions instead."
  (multiple-value-bind (documentation declarations forms) (%body-parts body)
    (declare (ignore documentation))
    (let* ((required (car (%parse-lambda-list plain)))
           (specialized (let ((names nil))
                          (mapc (lambda (p s) (unless (eq s t) (push p names)))
                                required specializers)
                          names))
           (inner `(destructuring-bind ,(%method-lambda-list plain) %arguments
                     (declare (ignorable ,@specialized))
                     ,@declarations
                     (block ,(%function-name-symbol name) ,@forms))))
      `(lambda (%method)
         (declare (ignorable %method))
         (lambda (%arguments %next-methods)
           (declare (ignorable %next-methods))
           ,(if (%tree-names-function-p forms '(call-next-method next-method-p))
                `(flet ((call-next-method (&rest %cnm-arguments)
                          (%call-next-method %method %arguments %next-methods %cnm-arguments))
                        (next-method-p () (not (null %next-methods))))
                   ,inner)
                inner))))))

(defmacro call-next-method (&rest arguments)
  `(%call-next-method %method %arguments %next-methods (list ,@arguments)))

(defmacro next-method-p ()
  '(not (null %next-methods)))

(defun %call-next-method (method arguments next-methods given)
  (when given
    (let ((gf (%method-ref method generic-function)))
      (when (and gf (eq (%instance-class gf) *%the-class-standard-generic-function*)
                 (not (equal (%std-compute-applicable-methods gf given)
                             (%std-compute-applicable-methods gf arguments))))
        (error "The arguments ~S given to call-next-method have methods of ~S applying that ~S do not."
               given (%gf-ref gf name) arguments))))
  (let ((arguments (or given arguments)))
    (if next-methods
        (%invoke-method (car next-methods) arguments (cdr next-methods))
        (apply #'no-next-method (%method-ref method generic-function) method arguments))))

(defmacro defmethod (name &rest rest)
  (multiple-value-bind (qualifiers lambda-list body) (%parse-defmethod rest)
    (multiple-value-bind (plain specializers) (%split-specialized lambda-list)
      `(%defmethod ',name ',qualifiers ',plain
                   (list ,@(mapcar #'%specializer-form specializers))
                   ,(%body-parts body)
                   ,(%make-method-lambda name plain specializers body)))))

(defun %defmethod (name qualifiers lambda-list specializers documentation maker)
  (let* ((gf (or (%existing-generic-function name)
                 (%std-ensure-generic-function name :lambda-list
                                               (%gf-lambda-list-from-method lambda-list))))
         (method-class (%gf-ref gf method-class))
         (specializers (mapcar #'%resolve-specializer specializers))
         (method (if (or (not *%clos-booted*) (eq method-class *%the-class-standard-method*))
                     (%std-make-method method-class qualifiers lambda-list specializers
                                       documentation nil)
                     (make-instance method-class
                                    :qualifiers qualifiers :lambda-list lambda-list
                                    :specializers specializers :documentation documentation
                                    :function #'%uncallable-instance))))
    (setf (%method-ref method function) (funcall maker method))
    (%add-method-generic gf method)
    method))

;;; --- method combinations ---

;; Each method combination type by name: a function of the generic
;; function, the method combination object and the applicable methods,
;; most specific first, returning the effective method form.
(defvar *%method-combination-types* (make-hash-table :test #'eq))

(defun %make-method-combination (name options type documentation)
  (let ((combination (%std-allocate-instance (find-class 'method-combination))))
    (%std-initialize-from-defaults combination)
    (setf (%combination-ref combination name) name)
    (setf (%combination-ref combination options) options)
    (setf (%combination-ref combination type) type)
    (setf (%combination-ref combination documentation) documentation)
    combination))

(setq *%standard-method-combination*
      (%make-method-combination
       'standard nil
       (lambda (gf combination methods)
         (declare (ignore combination))
         (%standard-combination-form gf methods))
       "The standard method combination."))

(setf (gethash 'standard *%method-combination-types*)
      (cons (%combination-ref *%standard-method-combination* type)
            "The standard method combination."))

(defun %find-method-combination (gf-name spec)
  "The method combination object `(:method-combination . SPEC)` names."
  (cond ((or (null spec) (and (eq (car spec) 'standard) (null (cdr spec))))
         *%standard-method-combination*)
        ((eq (car spec) 'standard)
         (%program-error "The standard method combination takes no options, given ~S." (cdr spec)))
        (t
         (let ((type (gethash (car spec) *%method-combination-types*)))
           (unless type
             (error "~S names no method combination, given for ~S." (car spec) gf-name))
           (%make-method-combination (car spec) (cdr spec) (car type) (cdr type))))))

(defun invalid-method-error (method format-control &rest arguments)
  (error "Invalid method ~S: ~?" method format-control arguments))

(defun method-combination-error (format-control &rest arguments)
  (error "Method combination error: ~?" format-control arguments))

(defun %short-combination-type (name operator identity-with-one-argument)
  (lambda (gf combination methods)
    (let ((order (or (car (%combination-ref combination options)) :most-specific-first))
          (around nil)
          (primary nil))
      (unless (%memq order '(:most-specific-first :most-specific-last))
        (method-combination-error "~S is not an order the ~S method combination accepts."
                                  order name))
      (dolist (method methods)
        (let ((qualifiers (%method-ref method qualifiers)))
          (cond ((equal qualifiers '(:around)) (push method around))
                ((equal qualifiers (list name)) (push method primary))
                (t (invalid-method-error method "~S does not accept the qualifiers ~S."
                                         name qualifiers)))))
      (setq around (nreverse around))
      (setq primary (if (eq order :most-specific-first) (nreverse primary) primary))
      (if (null primary)
          `(%signal-no-primary-method ',gf)
          (let ((form (if (and identity-with-one-argument (null (cdr primary)))
                          `(call-method ,(car primary))
                          `(,operator ,@(mapcar (lambda (m) `(call-method ,m)) primary)))))
            (if around
                `(call-method ,(car around) (,@(cdr around) (make-method ,form)))
                form))))))

(defun %define-short-method-combination (name &key documentation identity-with-one-argument
                                                   (operator name))
  (setf (gethash name *%method-combination-types*)
        (cons (%short-combination-type name operator identity-with-one-argument)
              documentation))
  name)

(defun %qualifier-pattern-match-p (qualifiers pattern)
  (cond ((eq pattern '*) t)
        ((null pattern) (null qualifiers))
        ((atom qualifiers) nil)
        ((consp pattern)
         (and (or (eq (car pattern) '*) (eq (car pattern) (car qualifiers)))
              (%qualifier-pattern-match-p (cdr qualifiers) (cdr pattern))))
        (t nil)))

(defun %dmc-parse-group (spec)
  "A long form method group specifier as (name patterns predicate order
required description). Exactly one of PATTERNS and PREDICATE is given."
  (let ((name (car spec))
        (rest (cdr spec))
        (patterns nil)
        (predicate nil))
    (if (and rest (symbolp (car rest)) (car rest) (not (eq (car rest) '*))
             (not (keywordp (car rest))))
        (setq predicate (car rest) rest (cdr rest))
        (loop
          (when (or (null rest) (keywordp (car rest))) (return))
          (push (car rest) patterns)
          (setq rest (cdr rest))))
    (list name (nreverse patterns) predicate
          (getf rest :order :most-specific-first)
          (getf rest :required)
          (getf rest :description))))

(defun %dmc-parse-long-form (name lambda-list groups rest)
  "The parts of a long form define-method-combination as a plist."
  (let ((arguments nil) (gf-variable nil))
    (loop
      (cond ((and (consp (car rest)) (eq (caar rest) :arguments))
             (setq arguments (cdar rest)))
            ((and (consp (car rest)) (eq (caar rest) :generic-function))
             (setq gf-variable (cadar rest)))
            (t (return)))
      (setq rest (cdr rest)))
    (multiple-value-bind (documentation declarations body) (%body-parts rest)
      (list :name name :lambda-list lambda-list
            :groups (mapcar #'%dmc-parse-group groups)
            :arguments arguments :generic-function gf-variable
            :documentation documentation :declarations declarations :body body))))

(defun %dmc-partition (gf methods matchers)
  "METHODS, most specific first, sorted into one list per group, each
going to the first group whose matcher accepts its qualifiers."
  (declare (ignore gf))
  (let ((groups (make-list (length matchers))))
    (dolist (method methods)
      (let ((index 0) (placed nil))
        (dolist (matcher matchers)
          (when (funcall matcher (%method-ref method qualifiers))
            (push method (nth index groups))
            (setq placed t)
            (return))
          (setq index (1+ index)))
        (unless placed
          (invalid-method-error method "its qualifiers ~S match no method group."
                                (%method-ref method qualifiers)))))
    (mapcar #'nreverse groups)))

(defun %dmc-order-group (methods order required name)
  (when (and required (null methods))
    (method-combination-error "The method group ~S has no methods." name))
  (case order
    (:most-specific-first methods)
    (:most-specific-last (reverse methods))
    (t (method-combination-error "~S is not a method group order." order))))

(defun %dmc-matcher-form (group)
  (destructuring-bind (name patterns predicate order required description) group
    (declare (ignore name order required description))
    (if predicate
        `(function ,predicate)
        `(lambda (%qualifiers)
           (or ,@(mapcar (lambda (pattern) `(%qualifier-pattern-match-p %qualifiers ',pattern))
                         patterns))))))

(defun %dmc-parse-arguments (lambda-list)
  "An :arguments lambda list as specs: (:whole var), (:required var),
(:optional var default supplied), (:rest var) and (:key var default
supplied keyword)."
  (let ((specs nil) (state :required))
    (dolist (item lambda-list)
      (cond ((eq item '&whole) (setq state :whole))
            ((eq item '&optional) (setq state :optional))
            ((%memq item '(&rest &body)) (setq state :rest))
            ((eq item '&key) (setq state :key))
            ((eq item '&allow-other-keys))
            ((eq state :whole) (push (list :whole item) specs) (setq state :required))
            ((eq state :required) (push (list :required item) specs))
            ((eq state :optional)
             (push (if (consp item)
                       (list :optional (car item) (cadr item) (caddr item))
                       (list :optional item nil nil))
                   specs))
            ((eq state :rest) (push (list :rest item) specs))
            ((eq state :key)
             (push (if (consp item)
                       (list :key (if (consp (car item)) (cadar item) (car item))
                             (cadr item) (caddr item) (%keyword-of item))
                       (list :key item nil nil (%keyword-of item)))
                   specs))))
    (nreverse specs)))

(defun %dmc-spec-variables (specs)
  (let ((variables nil))
    (dolist (spec specs (nreverse variables))
      (push (cadr spec) variables)
      (when (and (%memq (car spec) '(:optional :key)) (cadddr spec))
        (push (cadddr spec) variables)))))

(defun %dmc-key-tail (plist keyword)
  "The tail of PLIST that starts with KEYWORD as a key, or nil."
  (do ((walk plist (cddr walk)))
      ((or (atom walk) (atom (cdr walk))) nil)
    (when (eq (car walk) keyword) (return walk))))

(defun %dmc-argument-bindings (specs gf)
  "The let* bindings that give the :arguments variables SPECS the
arguments of a call to GF, held in `%em-arguments`. Each variable lines
up with the parameter of GF's own lambda list in the same position, and
one with no such parameter gets nil or its default."
  (destructuring-bind (required optional rest keys allow key-p)
      (%parse-lambda-list (%gf-ref gf lambda-list))
    (declare (ignore rest keys allow key-p))
    (let ((gf-required (length required))
          (gf-optional (length optional))
          (required-index 0)
          (optional-index 0)
          (bindings nil))
      (let ((tail `(nthcdr ,(+ gf-required gf-optional) %em-arguments)))
        (dolist (spec specs (nreverse bindings))
          (case (car spec)
            (:whole (push (list (cadr spec) '%em-arguments) bindings))
            (:required
             (push (list (cadr spec)
                         (if (< required-index gf-required) `(nth ,required-index %em-arguments) nil))
                   bindings)
             (setq required-index (1+ required-index)))
            (:optional
             (destructuring-bind (variable default supplied) (cdr spec)
               (let ((position (+ gf-required optional-index)))
                 (if (< optional-index gf-optional)
                     (progn
                       (push (list variable `(if (nthcdr ,position %em-arguments)
                                                 (nth ,position %em-arguments)
                                                 ,default))
                             bindings)
                       (when supplied
                         (push (list supplied `(if (nthcdr ,position %em-arguments) t nil)) bindings)))
                     (progn
                       (push (list variable default) bindings)
                       (when supplied (push (list supplied nil) bindings))))))
             (setq optional-index (1+ optional-index)))
            (:rest (push (list (cadr spec) tail) bindings))
            (:key
             (destructuring-bind (variable default supplied keyword) (cdr spec)
               (push (list variable `(let ((%found (%dmc-key-tail ,tail ',keyword)))
                                       (if %found (cadr %found) ,default)))
                     bindings)
               (when supplied
                 (push (list supplied `(if (%dmc-key-tail ,tail ',keyword) t nil)) bindings))))))))))

(defmacro define-method-combination (name &rest rest)
  (if (or (null rest) (keywordp (car rest)))
      `(%define-short-method-combination ',name ,@(mapcar (lambda (x) `',x) rest))
      (let* ((parsed (%dmc-parse-long-form name (car rest) (cadr rest) (cddr rest)))
             (groups (getf parsed :groups))
             (specs (%dmc-parse-arguments (getf parsed :arguments)))
             (variables (%dmc-spec-variables specs))
             (body `(let ((%groups (%dmc-partition
                                    %gf %methods
                                    (list ,@(mapcar #'%dmc-matcher-form groups)))))
                      (let* ,(let ((index -1))
                               (mapcar (lambda (group)
                                         (setq index (1+ index))
                                         `(,(car group)
                                           (%dmc-order-group (nth ,index %groups)
                                                             ,(nth 3 group) ,(nth 4 group)
                                                             ',(car group))))
                                       groups))
                        ,@(getf parsed :declarations)
                        (progn ,@(getf parsed :body))))))
        `(progn
           (setf (gethash ',name *%method-combination-types*)
                 (cons (lambda (%gf %combination %methods)
                         (declare (ignorable %gf))
                         (apply (lambda ,(getf parsed :lambda-list)
                                  (let (,@(when (getf parsed :generic-function)
                                            `((,(getf parsed :generic-function) %gf)))
                                        ,@(mapcar (lambda (variable) `(,variable ',variable))
                                                  variables))
                                    ,(if specs
                                         `(list 'let* (%dmc-argument-bindings ',specs %gf) ,body)
                                         body)))
                                (%combination-ref %combination options)))
                       ,(getf parsed :documentation)))
           ',name))))

(dolist (operator '(+ and or list append nconc min max progn))
  (%define-short-method-combination operator :identity-with-one-argument (not (eq operator 'list))))

;;; --- built-in classes ---

(defun %define-std-class (name metaclass supers)
  "A class made directly, the way the bootstrap made the first ones."
  (let ((class (or (find-class name nil) (%bootstrap-shell name))))
    (%set-instance-layout class (find-class metaclass) (%class-ref (find-class metaclass) wrapper)
                          (%instance-slots class))
    (setf (%class-ref class direct-superclasses) (mapcar #'find-class supers))
    (dolist (super (%class-ref class direct-superclasses))
      (pushnew class (%class-ref super direct-subclasses)))
    (%std-finalize-inheritance class)
    class))

(dolist (entry '((sequence t) (list sequence) (symbol t) (cons list) (null symbol list)
                 (array t) (vector array sequence) (string vector) (bit-vector vector)
                 (character t) (number t) (complex number) (real number) (float real)
                 (single-float float) (double-float float) (rational real)
                 (integer rational) (fixnum integer) (bignum integer) (ratio rational)
                 (hash-table t) (package t) (pathname t) (logical-pathname pathname)
                 (random-state t) (readtable t) (stream t) (file-stream stream)
                 (string-stream stream) (synonym-stream stream) (broadcast-stream stream)
                 (concatenated-stream stream) (two-way-stream stream) (echo-stream stream)))
  (%define-std-class (car entry) 'built-in-class (cdr entry)))

(%define-std-class 'structure-object 'structure-class '(t))

;;; --- slot access ---

(defun %obsolete-instance-p (instance)
  (not (eq (%instance-wrapper instance) (%class-ref (%instance-class instance) wrapper))))

(defun %ensure-current (instance)
  (when (%obsolete-instance-p instance)
    (%update-obsolete-instance instance))
  instance)

(defparameter *%standard-metaclasses* nil)

(defun %standard-instance-p (object)
  "Whether OBJECT's slots are reached the standard way, which is when its
class's class is one of the standard metaclasses."
  (and (%instance-p object)
       (not (null (%memq (%instance-class (%instance-class object)) *%standard-metaclasses*)))))

(defun %std-slotd (instance name)
  (gethash name (%class-ref (%instance-class instance) slot-table)))

(defun %slotd-value (instance slotd)
  (let ((location (%slotd-ref slotd location)))
    (if (consp location)
        (cdr location)
        (svref (%instance-slots instance) location))))

(defun %set-slotd-value (instance slotd new-value)
  (let ((location (%slotd-ref slotd location)))
    (if (consp location)
        (setf (cdr location) new-value)
        (setf (svref (%instance-slots instance) location) new-value))))

(defun %check-slot-type (slotd new-value)
  (let ((type (%slotd-ref slotd type)))
    (unless (or (eq type t) (eq new-value *%slot-unbound*))
      (unless (%typep-or-unknown new-value type)
        (error 'type-error :datum new-value :expected-type type)))))

(defun %typep-or-unknown (object type)
  "Whether OBJECT is of TYPE, taking a type that does not parse yet as
satisfied."
  (let ((outcome (multiple-value-list (%catch-error (typep object type)))))
    (if (car outcome) t (cadr outcome))))

(defun %std-slot-value (instance name)
  (%ensure-current instance)
  (let ((slotd (%std-slotd instance name)))
    (if (null slotd)
        (values (slot-missing (%instance-class instance) instance name 'slot-value))
        (let ((value (%slotd-value instance slotd)))
          (if (eq value *%slot-unbound*)
              (values (slot-unbound (%instance-class instance) instance name))
              value)))))

(defun %std-set-slot-value (instance name new-value)
  (%ensure-current instance)
  (let ((slotd (%std-slotd instance name)))
    (if (null slotd)
        (progn (slot-missing (%instance-class instance) instance name 'setf new-value)
               new-value)
        (progn (%check-slot-type slotd new-value)
               (%set-slotd-value instance slotd new-value)))))

(defun %find-slotd (class name)
  (dolist (slotd (class-slots class) nil)
    (when (eq (slot-definition-name slotd) name) (return slotd))))

(defun slot-value (object slot-name)
  (let ((value (%fast-slot-value object slot-name)))
    (if (eq value *%fast-miss*)
        (%slow-slot-value object slot-name)
        value)))

(defun %slow-slot-value (object slot-name)
  (if (%standard-instance-p object)
      (%std-slot-value object slot-name)
      (let* ((class (class-of object))
             (slotd (%find-slotd class slot-name)))
        (if slotd
            (slot-value-using-class class object slotd)
            (values (slot-missing class object slot-name 'slot-value))))))

(defun (setf slot-value) (new-value object slot-name)
  (if (%fast-set-slot-value object slot-name new-value)
      new-value
      (%slow-set-slot-value new-value object slot-name)))

(defun %slow-set-slot-value (new-value object slot-name)
  (if (%standard-instance-p object)
      (%std-set-slot-value object slot-name new-value)
      (let* ((class (class-of object))
             (slotd (%find-slotd class slot-name)))
        (if slotd
            (setf (slot-value-using-class class object slotd) new-value)
            (progn (slot-missing class object slot-name 'setf new-value)
                   new-value)))))

(defun slot-boundp (object slot-name)
  (let ((bound (%fast-slot-boundp object slot-name)))
    (if (eq bound *%fast-miss*)
        (%slow-slot-boundp object slot-name)
        bound)))

(defun %slow-slot-boundp (object slot-name)
  (if (%standard-instance-p object)
      (progn
        (%ensure-current object)
        (let ((slotd (%std-slotd object slot-name)))
          (if slotd
              (not (eq (%slotd-value object slotd) *%slot-unbound*))
              (values (slot-missing (%instance-class object) object slot-name 'slot-boundp)))))
      (let* ((class (class-of object))
             (slotd (%find-slotd class slot-name)))
        (if slotd
            (slot-boundp-using-class class object slotd)
            (values (slot-missing class object slot-name 'slot-boundp))))))

(defun slot-makunbound (object slot-name)
  (if (%standard-instance-p object)
      (progn
        (%ensure-current object)
        (let ((slotd (%std-slotd object slot-name)))
          (if slotd
              (%set-slotd-value object slotd *%slot-unbound*)
              (slot-missing (%instance-class object) object slot-name 'slot-makunbound))
          object))
      (let* ((class (class-of object))
             (slotd (%find-slotd class slot-name)))
        (if slotd
            (slot-makunbound-using-class class object slotd)
            (slot-missing class object slot-name 'slot-makunbound))
        object)))

(defun slot-exists-p (object slot-name)
  (if (%standard-instance-p object)
      (progn (%ensure-current object)
             (not (null (%std-slotd object slot-name))))
      (not (null (%find-slotd (class-of object) slot-name)))))

;;; --- updating obsolete instances ---

(defun %update-obsolete-instance (instance)
  "CLHS 4.3.6.1: move INSTANCE to its class's current layout and run
`update-instance-for-redefined-class`."
  (let* ((class (%instance-class instance))
         (old-wrapper (%instance-wrapper instance))
         (old-names (car old-wrapper))
         (old-shared (cadr old-wrapper))
         (old-slots (%instance-slots instance)))
    (unless (%class-ref class finalized-p) (finalize-inheritance class))
    (let* ((wrapper (%class-ref class wrapper))
           (names (car wrapper))
           (slots (%fresh-slots (length names)))
           (added nil)
           (discarded nil)
           (plist nil)
           (index 0))
      (dolist (name names)
        (let ((old-index (position name old-names)))
          (cond (old-index
                 (setf (svref slots index) (svref old-slots old-index)))
                ((%memq name old-shared)
                 (setf (svref slots index) (%old-shared-value class name)))
                (t (push name added))))
        (setq index (1+ index)))
      (let ((old-index 0))
        (dolist (name old-names)
          (unless (%memq name names)
            (push name discarded)
            (let ((value (svref old-slots old-index)))
              (unless (eq value *%slot-unbound*)
                (setq plist (list* name value plist)))))
          (setq old-index (1+ old-index))))
      (%set-instance-layout instance class wrapper slots)
      (update-instance-for-redefined-class instance (nreverse added) (nreverse discarded) plist)
      instance)))

(defun %old-shared-value (class name)
  "The value a slot NAME had while it was shared, which stays in the cell
of whichever class above CLASS defined it."
  (dolist (c (%class-ref class precedence-list) *%slot-unbound*)
    (let ((cell (cdr (assoc name (getf (%class-ref c plist) :class-slot-cells)))))
      (when cell (return (cdr cell))))))

;;; --- the standard generic functions ---

(defgeneric slot-missing (class object slot-name operation &optional new-value))
(defmethod slot-missing ((class t) object slot-name operation &optional new-value)
  (declare (ignore new-value))
  (error "~S has no slot named ~S (~S)." object slot-name operation))

(defgeneric slot-unbound (class instance slot-name))
(defmethod slot-unbound ((class t) instance slot-name)
  (error 'unbound-slot :name slot-name :instance instance))

(defgeneric no-applicable-method (generic-function &rest function-arguments))
(defmethod no-applicable-method ((generic-function t) &rest function-arguments)
  (error "No method of ~S applies to the arguments ~S."
         (generic-function-name generic-function) function-arguments))

(defgeneric no-next-method (generic-function method &rest args))
(defmethod no-next-method ((generic-function t) (method t) &rest args)
  (error "~S has no next method to call (from ~S, given ~S)."
         (generic-function-name generic-function) method args))

;;; --- making instances ---

(defun %initarg-supplied-p (key initargs)
  (do ((walk initargs (cddr walk)))
      ((null walk) nil)
    (when (eq (car walk) key) (return t))))

(defun %add-default-initargs (class initargs)
  (let ((extra nil))
    (dolist (entry (%class-ref class default-initargs))
      (unless (%initarg-supplied-p (car entry) initargs)
        (push (car entry) extra)
        (push (funcall (caddr entry)) extra)))
    (if extra (append initargs (nreverse extra)) initargs)))

(defun %methods-for-instance-of (gf class)
  "The methods of GF whose first specializer is a class CLASS's instances
belong to."
  (remove-if-not (lambda (method)
                   (let ((specializer (car (%method-ref method specializers))))
                     (and (not (%eql-specializer-p specializer))
                          (%subclassp class specializer))))
                 (%gf-ref gf methods)))

(defun %methods-for-class (gf class)
  "The methods of GF a call with CLASS itself as the first argument
could run."
  (remove-if-not (lambda (method)
                   (let ((specializer (car (%method-ref method specializers))))
                     (if (%eql-specializer-p specializer)
                         (eq (%eql-ref specializer object) class)
                         (%subclassp (%instance-class class) specializer))))
                 (%gf-ref gf methods)))

(defun %valid-initargs (class instance-functions class-functions)
  "The initargs a call making or changing an instance of CLASS accepts,
or t where it accepts any (CLHS 7.1.2)."
  (let ((keys nil))
    (dolist (slotd (%class-ref class slots))
      (setq keys (append (%slotd-ref slotd initargs) keys)))
    (dolist (spec (list (cons instance-functions #'%methods-for-instance-of)
                        (cons class-functions #'%methods-for-class)))
      (dolist (name (car spec))
        (dolist (method (funcall (cdr spec) (fdefinition name) class))
          (let ((accepted (%lambda-list-keywords-accepted (%method-ref method lambda-list))))
            (when (eq accepted t) (return-from %valid-initargs t))
            (setq keys (append accepted keys))))))
    keys))

(defun %check-initargs (class initargs instance-functions class-functions cache-key)
  (when (oddp (length initargs))
    (%program-error "The initialization arguments ~S do not come in pairs." initargs))
  (unless (getf initargs :allow-other-keys)
    (let* ((cached (getf (%class-ref class plist) cache-key))
           (valid (if (and cached (eql (car cached) *%initialization-epoch*))
                      (cdr cached)
                      (cdr (setf (getf (%class-ref class plist) cache-key)
                                 (cons *%initialization-epoch*
                                       (%valid-initargs class instance-functions class-functions)))))))
      (unless (eq valid t)
        (do ((walk initargs (cddr walk)))
            ((null walk))
          (unless (or (%memq (car walk) valid) (eq (car walk) :allow-other-keys))
            (%program-error "~S is not a valid initialization argument for ~S."
                            (car walk) (%class-ref class name))))))))

(defvar *%standard-initialization-methods* nil)

(defun %fast-initialization-p (class)
  "Whether making an instance of CLASS runs only the standard methods, so
it can be done without going through the generic functions."
  (let ((cached (getf (%class-ref class plist) :fast-init)))
    (if (and cached (eql (car cached) *%initialization-epoch*))
        (cdr cached)
        (cdr (setf (getf (%class-ref class plist) :fast-init)
                   (cons *%initialization-epoch*
                         (and (every (lambda (method) (%memq method *%standard-initialization-methods*))
                                     (%methods-for-class #'allocate-instance class))
                              (every (lambda (name)
                                       (every (lambda (method)
                                                (%memq method *%standard-initialization-methods*))
                                              (%methods-for-instance-of (fdefinition name) class)))
                                     '(initialize-instance shared-initialize)))))))))

(defun %std-make-instance (class initargs)
  (unless (%class-ref class finalized-p) (finalize-inheritance class))
  (let ((initargs (%add-default-initargs class initargs)))
    (%check-initargs class initargs '(initialize-instance shared-initialize)
                     '(make-instance allocate-instance) :make-instance-initargs)
    (if (%fast-initialization-p class)
        (%std-shared-initialize (%std-allocate-instance class) t initargs)
        (let ((instance (apply #'allocate-instance class initargs)))
          (apply #'initialize-instance instance initargs)
          instance))))

(defun %std-shared-initialize (instance slot-names initargs)
  (let ((standard (%standard-instance-p instance)))
    (dolist (slotd (if standard
                       (%class-ref (%instance-class instance) slots)
                       (class-slots (class-of instance))))
      (let* ((name (if standard (%slotd-ref slotd name) (slot-definition-name slotd)))
             (keys (if standard (%slotd-ref slotd initargs) (slot-definition-initargs slotd)))
             (tail (and keys (nth-value 2 (get-properties initargs keys)))))
        (if tail
            (setf (slot-value instance name) (cadr tail))
            (let ((initfunction (if standard
                                    (%slotd-ref slotd initfunction)
                                    (slot-definition-initfunction slotd))))
              (when (and initfunction
                         (or (eq slot-names t) (%memq name slot-names))
                         (not (slot-boundp instance name)))
                (setf (slot-value instance name)
                      (%initial-value (if standard
                                          (%slotd-ref slotd initform)
                                          (slot-definition-initform slotd))
                                      initfunction))))))))
  instance)

(defgeneric allocate-instance (class &rest initargs &key &allow-other-keys))
(defmethod allocate-instance ((class standard-class) &rest initargs)
  (declare (ignore initargs))
  (%std-allocate-instance class))
(defmethod allocate-instance ((class funcallable-standard-class) &rest initargs)
  (declare (ignore initargs))
  (%std-allocate-instance class))
(defmethod allocate-instance ((class condition-class) &rest initargs)
  (declare (ignore initargs))
  (%std-allocate-instance class))
(defmethod allocate-instance ((class built-in-class) &rest initargs)
  (declare (ignore initargs))
  (error "~S is a built-in class, which has no instances to make." (%class-ref class name)))

(defgeneric make-instance (class &rest initargs &key &allow-other-keys))
(defmethod make-instance ((class symbol) &rest initargs)
  (apply #'make-instance (find-class class) initargs))
(defmethod make-instance ((class standard-class) &rest initargs)
  (%std-make-instance class initargs))
(defmethod make-instance ((class funcallable-standard-class) &rest initargs)
  (%std-make-instance class initargs))
(defmethod make-instance ((class condition-class) &rest initargs)
  (%std-make-instance class initargs))

(defgeneric initialize-instance (instance &rest initargs &key &allow-other-keys))
(defmethod initialize-instance ((instance t) &rest initargs)
  (apply #'shared-initialize instance t initargs))

(defgeneric reinitialize-instance (instance &rest initargs &key &allow-other-keys))
(defmethod reinitialize-instance ((instance t) &rest initargs)
  (let ((class (class-of instance)))
    (when (%standard-instance-p instance) (%ensure-current instance))
    (%check-initargs class initargs '(reinitialize-instance shared-initialize) nil
                     :reinitialize-initargs))
  (apply #'shared-initialize instance nil initargs))

(defgeneric shared-initialize (instance slot-names &rest initargs &key &allow-other-keys))
(defmethod shared-initialize ((instance t) slot-names &rest initargs)
  (unless (or (eq slot-names t) (listp slot-names))
    (error 'type-error :datum slot-names :expected-type '(or (member t) list)))
  (when (oddp (length initargs))
    (%program-error "The initialization arguments ~S do not come in pairs." initargs))
  (do ((walk initargs (cddr walk)))
      ((null walk))
    (unless (symbolp (car walk))
      (%program-error "~S cannot name an initialization argument." (car walk))))
  (%std-shared-initialize instance slot-names initargs))

(defgeneric update-instance-for-different-class (previous current &rest initargs
                                                &key &allow-other-keys))
(defmethod update-instance-for-different-class ((previous t) (current t) &rest initargs)
  (let ((class (class-of current))
        (added nil))
    (%check-initargs class initargs '(update-instance-for-different-class shared-initialize) nil
                     :different-class-initargs)
    (dolist (slotd (class-slots class))
      (when (and (eq (slot-definition-allocation slotd) :instance)
                 (not (slot-exists-p previous (slot-definition-name slotd))))
        (push (slot-definition-name slotd) added)))
    (apply #'shared-initialize current (nreverse added) initargs)))

(defgeneric update-instance-for-redefined-class (instance added-slots discarded-slots
                                                property-list &rest initargs
                                                &key &allow-other-keys))
(defmethod update-instance-for-redefined-class ((instance t) added-slots discarded-slots
                                                property-list &rest initargs)
  (declare (ignore discarded-slots property-list))
  (%check-initargs (class-of instance) initargs
                   '(update-instance-for-redefined-class shared-initialize) nil
                   :redefined-class-initargs)
  (apply #'shared-initialize instance added-slots initargs))

(defgeneric change-class (instance new-class &rest initargs &key &allow-other-keys))
(defmethod change-class ((instance t) (new-class symbol) &rest initargs)
  (apply #'change-class instance (find-class new-class) initargs))
(defmethod change-class ((instance standard-object) (new-class standard-class) &rest initargs)
  (%std-change-class instance new-class initargs))
(defmethod change-class ((instance funcallable-standard-object)
                         (new-class funcallable-standard-class) &rest initargs)
  (%std-change-class instance new-class initargs))

(defun %std-change-class (instance new-class initargs)
  (%ensure-current instance)
  (unless (%class-ref new-class finalized-p) (finalize-inheritance new-class))
  (let* ((previous (%allocate-standard-instance (%instance-class instance)
                                                (%instance-wrapper instance)
                                                (copy-seq (%instance-slots instance))))
         (wrapper (%class-ref new-class wrapper))
         (slots (%fresh-slots (length (car wrapper)))))
    (dolist (slotd (%class-ref new-class slots))
      (when (eq (%slotd-ref slotd allocation) :instance)
        (let ((old (%std-slotd instance (%slotd-ref slotd name))))
          (when old
            (setf (svref slots (%slotd-ref slotd location)) (%slotd-value instance old))))))
    (%set-instance-layout instance new-class wrapper slots)
    (apply #'update-instance-for-different-class previous instance initargs)
    instance))

(defgeneric make-instances-obsolete (class))
(defmethod make-instances-obsolete ((class symbol))
  (make-instances-obsolete (find-class class)))
(defmethod make-instances-obsolete ((class standard-class))
  (%obsolete-class-instances class))
(defmethod make-instances-obsolete ((class funcallable-standard-class))
  (%obsolete-class-instances class))

(defun %obsolete-class-instances (class)
  (when (%class-ref class finalized-p)
    (let ((wrapper (%class-ref class wrapper)))
      (setf (%class-ref class wrapper) (list (car wrapper) (cadr wrapper)))))
  class)

(setq *%standard-initialization-methods*
      (append (%gf-ref #'allocate-instance methods)
              (%gf-ref #'initialize-instance methods)
              (%gf-ref #'shared-initialize methods)))

;;; --- metaobject readers ---

(defmacro %define-readers (class-name ref-macro &rest pairs)
  `(progn
     ,@(mapcar (lambda (pair)
                 `(progn
                    (defgeneric ,(car pair) (object))
                    (defmethod ,(car pair) ((object ,class-name)) (,ref-macro object ,(cadr pair)))))
               pairs)))

(%define-readers class %class-ref
  (class-direct-superclasses direct-superclasses)
  (class-direct-subclasses direct-subclasses)
  (class-direct-slots direct-slots)
  (class-direct-default-initargs direct-default-initargs)
  (class-finalized-p finalized-p))

(defgeneric class-name (class))
(defmethod class-name ((class class)) (%class-ref class name))
(defgeneric (setf class-name) (new-value class))
(defmethod (setf class-name) (new-value (class class))
  (reinitialize-instance class :name new-value)
  new-value)

(defun %require-finalized (class operation)
  (unless (%class-ref class finalized-p)
    (error "~S is not finalized, so ~S has nothing to return." (%class-ref class name) operation)))

(defgeneric class-precedence-list (class))
(defmethod class-precedence-list ((class class))
  (%require-finalized class 'class-precedence-list)
  (%class-ref class precedence-list))

(defgeneric class-slots (class))
(defmethod class-slots ((class class))
  (%require-finalized class 'class-slots)
  (%class-ref class slots))

(defgeneric class-default-initargs (class))
(defmethod class-default-initargs ((class class))
  (%require-finalized class 'class-default-initargs)
  (%class-ref class default-initargs))

(defgeneric class-prototype (class))
(defmethod class-prototype ((class class))
  (unless (%class-ref class finalized-p) (finalize-inheritance class))
  (or (%class-ref class prototype)
      (setf (%class-ref class prototype) (allocate-instance class))))

(%define-readers slot-definition %slotd-ref
  (slot-definition-name name)
  (slot-definition-initform initform)
  (slot-definition-initfunction initfunction)
  (slot-definition-initargs initargs)
  (slot-definition-type type)
  (slot-definition-allocation allocation)
  (slot-definition-location location))

(%define-readers direct-slot-definition %slotd-ref
  (slot-definition-readers readers)
  (slot-definition-writers writers))

(%define-readers standard-generic-function %gf-ref
  (generic-function-lambda-list lambda-list)
  (generic-function-methods methods)
  (generic-function-method-class method-class)
  (generic-function-method-combination method-combination)
  (generic-function-argument-precedence-order argument-precedence-order)
  (generic-function-declarations declarations))

(defgeneric generic-function-name (generic-function))
(defmethod generic-function-name ((generic-function standard-generic-function))
  (%gf-ref generic-function name))
(defgeneric (setf generic-function-name) (new-value generic-function))
(defmethod (setf generic-function-name) (new-value (generic-function standard-generic-function))
  (setf (%gf-ref generic-function name) new-value))

(%define-readers standard-method %method-ref
  (method-generic-function generic-function)
  (method-specializers specializers)
  (method-qualifiers qualifiers)
  (method-lambda-list lambda-list)
  (method-function function))

(%define-readers standard-accessor-method %method-ref
  (accessor-method-slot-definition slot-definition))

(defgeneric specializer-direct-methods (specializer))
(defmethod specializer-direct-methods ((specializer class))
  (%class-ref specializer direct-methods))
(defmethod specializer-direct-methods ((specializer eql-specializer))
  (%eql-ref specializer direct-methods))

(defgeneric specializer-direct-generic-functions (specializer))
(defmethod specializer-direct-generic-functions ((specializer specializer))
  (remove-duplicates (mapcar (lambda (method) (%method-ref method generic-function))
                             (specializer-direct-methods specializer))))

(defgeneric method-combination-name (combination))
(defmethod method-combination-name ((combination method-combination))
  (%combination-ref combination name))

;;; --- the class protocol ---

(defgeneric compute-class-precedence-list (class))
(defmethod compute-class-precedence-list ((class class)) (%std-compute-cpl class))

(defgeneric compute-slots (class))
(defmethod compute-slots ((class class)) (%std-compute-slots class))

(defgeneric compute-effective-slot-definition (class name direct-slot-definitions))
(defmethod compute-effective-slot-definition ((class class) name direct-slot-definitions)
  (%std-compute-effective-slotd class name direct-slot-definitions))

(defgeneric compute-default-initargs (class))
(defmethod compute-default-initargs ((class class)) (%std-compute-default-initargs class))

(defgeneric finalize-inheritance (class))
(defmethod finalize-inheritance ((class class)) (%std-finalize-inheritance class))
(defmethod finalize-inheritance ((class forward-referenced-class))
  (error "~S is a forward reference to a class not defined yet." (%class-ref class name)))

(defgeneric direct-slot-definition-class (class &rest initargs))
(defmethod direct-slot-definition-class ((class class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'standard-direct-slot-definition))

(defgeneric effective-slot-definition-class (class &rest initargs))
(defmethod effective-slot-definition-class ((class class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'standard-effective-slot-definition))

(defgeneric validate-superclass (class superclass))
(defmethod validate-superclass ((class class) (superclass class))
  (let ((meta (%instance-class class))
        (super-meta (%instance-class superclass)))
    (or (eq superclass *%the-class-t*)
        (eq meta super-meta)
        (eq super-meta (find-class 'forward-referenced-class))
        (and (eq meta *%the-class-standard-class*)
             (eq super-meta *%the-class-funcallable-standard-class*))
        (and (eq meta *%the-class-funcallable-standard-class*)
             (eq super-meta *%the-class-standard-class*)))))

(defgeneric add-direct-subclass (superclass subclass))
(defmethod add-direct-subclass ((superclass class) (subclass class))
  (pushnew subclass (%class-ref superclass direct-subclasses)))

(defgeneric remove-direct-subclass (superclass subclass))
(defmethod remove-direct-subclass ((superclass class) (subclass class))
  (setf (%class-ref superclass direct-subclasses)
        (remove subclass (%class-ref superclass direct-subclasses))))

(defgeneric reader-method-class (class direct-slot &rest initargs))
(defmethod reader-method-class ((class class) direct-slot &rest initargs)
  (declare (ignore direct-slot initargs))
  (find-class 'standard-reader-method))

(defgeneric writer-method-class (class direct-slot &rest initargs))
(defmethod writer-method-class ((class class) direct-slot &rest initargs)
  (declare (ignore direct-slot initargs))
  (find-class 'standard-writer-method))

;;; --- slot access through the class ---

(defgeneric slot-value-using-class (class object slot))
(defmethod slot-value-using-class ((class standard-class) object (slot standard-effective-slot-definition))
  (%std-slot-value object (%slotd-ref slot name)))
(defmethod slot-value-using-class ((class funcallable-standard-class) object
                                   (slot standard-effective-slot-definition))
  (%std-slot-value object (%slotd-ref slot name)))

(defgeneric (setf slot-value-using-class) (new-value class object slot))
(defmethod (setf slot-value-using-class) (new-value (class standard-class) object
                                          (slot standard-effective-slot-definition))
  (%std-set-slot-value object (%slotd-ref slot name) new-value))
(defmethod (setf slot-value-using-class) (new-value (class funcallable-standard-class) object
                                          (slot standard-effective-slot-definition))
  (%std-set-slot-value object (%slotd-ref slot name) new-value))

(defgeneric slot-boundp-using-class (class object slot))
(defmethod slot-boundp-using-class ((class class) object (slot standard-effective-slot-definition))
  (%ensure-current object)
  (not (eq (%slotd-value object slot) *%slot-unbound*)))

(defgeneric slot-makunbound-using-class (class object slot))
(defmethod slot-makunbound-using-class ((class class) object (slot standard-effective-slot-definition))
  (%ensure-current object)
  (%set-slotd-value object slot *%slot-unbound*)
  object)

;;; --- structure classes ---

(defun %define-structure-class (name slot-names include)
  "The class `defstruct` defines for NAME, whose slots sit in a structure
at the positions SLOT-NAMES gives them, below the structure INCLUDE names
or below `structure-object`."
  (let ((own (if include
                 (nthcdr (length (get include '%structure-slots)) slot-names)
                 slot-names)))
    (ensure-class name :metaclass 'structure-class
                       :direct-superclasses (list (or include 'structure-object))
                       :direct-slots (mapcar (lambda (slot-name) (list :name slot-name)) own))))

(defmethod allocate-instance ((class structure-class) &rest initargs)
  (declare (ignore initargs))
  (let ((name (%class-ref class name)))
    (apply #'%make-structure name (make-list (length (get name '%structure-slots))))))

(defmethod slot-value-using-class ((class structure-class) object slot)
  (%structure-ref object (slot-definition-location slot)))

(defmethod (setf slot-value-using-class) (new-value (class structure-class) object slot)
  (%set-structure-ref object (slot-definition-location slot) new-value))

(defmethod slot-boundp-using-class ((class structure-class) object slot)
  (declare (ignore object slot))
  t)

;;; --- defining classes ---

;; Classes named as superclasses before they are defined, by name. Such
;; a class is not found by `find-class` until its own definition turns it
;; into a real one.
(defvar *%forward-classes* (make-hash-table :test #'eq))

(defun %designated-superclass (designator)
  (cond ((%class-p designator) designator)
        ((find-class designator nil))
        ((gethash designator *%forward-classes*))
        (t (let ((class (%std-allocate-instance (find-class 'forward-referenced-class))))
             (%std-initialize-from-defaults class)
             (setf (%class-ref class name) designator)
             (setf (%class-ref class direct-superclasses) nil)
             (setf (%class-ref class direct-subclasses) nil)
             (setf (%class-ref class direct-slots) nil)
             (setf (%class-ref class direct-methods) nil)
             (setf (%class-ref class plist) nil)
             (setf (gethash designator *%forward-classes*) class)))))

(defun %default-superclasses (class)
  (let ((meta (%instance-class class)))
    (cond ((%subclassp meta *%the-class-funcallable-standard-class*)
           (list (find-class 'funcallable-standard-object)))
          ((%subclassp meta (find-class 'condition-class))
           (list (find-class 'condition)))
          (t (list (find-class 'standard-object))))))

(defun %remove-accessor-methods (class)
  (dolist (entry (getf (%class-ref class plist) :accessor-methods))
    (let ((gf (car entry)))
      (remove-method gf (cdr entry))))
  (setf (getf (%class-ref class plist) :accessor-methods) nil))

(defun %add-accessor-method (class gf-name lambda-list method-class specializers slotd function)
  (let* ((gf (or (%existing-generic-function gf-name)
                 (ensure-generic-function gf-name :lambda-list lambda-list)))
         (method (%std-make-method method-class nil lambda-list specializers nil function)))
    (setf (%method-ref method slot-definition) slotd)
    (add-method gf method)
    (push (cons gf method) (getf (%class-ref class plist) :accessor-methods))))

(defun %reader-function (slot-name)
  (lambda (arguments next-methods)
    (declare (ignore next-methods))
    (slot-value (car arguments) slot-name)))

(defun %writer-function (slot-name)
  (lambda (arguments next-methods)
    (declare (ignore next-methods))
    (setf (slot-value (cadr arguments) slot-name) (car arguments))))

(defun %add-accessor-methods (class)
  (dolist (slotd (%class-ref class direct-slots))
    (let ((name (slot-definition-name slotd)))
      (dolist (reader (slot-definition-readers slotd))
        (%add-accessor-method class reader '(object) (reader-method-class class slotd)
                              (list class) slotd (%reader-function name)))
      (dolist (writer (slot-definition-writers slotd))
        (%add-accessor-method class writer '(new-value object) (writer-method-class class slotd)
                              (list *%the-class-t* class) slotd (%writer-function name))))))

(defun %make-direct-slot-definitions (class specs)
  (let ((names nil))
    (mapcar (lambda (spec)
              (let ((name (getf spec :name)))
                (when (%memq name names)
                  (%program-error "The slot ~S is given twice." name))
                (push name names))
              (let ((slotd (apply #'make-instance (apply #'direct-slot-definition-class class spec)
                                  spec)))
                (when (eq (slot-definition-allocation slotd) :class)
                  (setf (%slotd-ref slotd allocation-class) class))
                slotd))
            specs)))

(defun %initialize-class (class reinitializing &key (name nil name-p)
                                                    (direct-superclasses nil supers-p)
                                                    (direct-slots nil slots-p)
                                                    (direct-default-initargs nil defaults-p)
                                                    (documentation nil documentation-p)
                                               &allow-other-keys)
  (when name-p (setf (%class-ref class name) name))
  (when (or supers-p (not reinitializing))
    (let ((supers (if direct-superclasses
                      (mapcar #'%designated-superclass direct-superclasses)
                      (%default-superclasses class))))
      (dolist (super supers)
        (unless (validate-superclass class super)
          (error "~S cannot be a superclass of ~S: their metaclasses ~S and ~S do not mix."
                 (%class-ref super name) (%class-ref class name)
                 (%class-ref (%instance-class super) name)
                 (%class-ref (%instance-class class) name))))
      (dolist (old (%class-ref class direct-superclasses))
        (remove-direct-subclass old class))
      (setf (%class-ref class direct-superclasses) supers)
      (dolist (super supers)
        (add-direct-subclass super class))))
  (when (or slots-p (not reinitializing))
    (%remove-accessor-methods class)
    (setf (%class-ref class direct-slots) (%make-direct-slot-definitions class direct-slots)))
  (when (or defaults-p (not reinitializing))
    (setf (%class-ref class direct-default-initargs) direct-default-initargs))
  (when (or documentation-p (not reinitializing))
    (setf (%class-ref class documentation) documentation))
  (when (or slots-p (not reinitializing))
    (%add-accessor-methods class))
  (when (%finalizable-p class)
    (finalize-inheritance class)
    (%initialize-shared-slots class))
  (%refinalize-subclasses class)
  class)

(defun %initialize-shared-slots (class)
  "Give each shared slot CLASS defines the value of its initform when it
has none yet."
  (dolist (slotd (%class-ref class slots))
    (let ((location (%slotd-ref slotd location)))
      (when (and (consp location)
                 (eq (cdr location) *%slot-unbound*)
                 (eq (%slotd-ref slotd allocation-class) class)
                 (%slotd-ref slotd initfunction))
        (setf (cdr location) (%initial-value (%slotd-ref slotd initform)
                                             (%slotd-ref slotd initfunction)))))))

(defmethod shared-initialize :after ((class class) slot-names &rest initargs
                                     &key name direct-superclasses direct-slots
                                          direct-default-initargs documentation
                                     &allow-other-keys)
  (declare (ignore name direct-superclasses direct-slots direct-default-initargs documentation))
  (apply #'%initialize-class class (not (eq slot-names t)) initargs))

(defgeneric ensure-class-using-class (class name &rest keys &key &allow-other-keys))

(defun %class-keys (keys)
  (let ((result nil))
    (do ((walk keys (cddr walk)))
        ((null walk) (nreverse result))
      (unless (%memq (car walk) '(:metaclass))
        (push (car walk) result)
        (push (cadr walk) result)))))

(defmethod ensure-class-using-class ((class null) name &rest keys
                                     &key (metaclass 'standard-class) &allow-other-keys)
  (let ((forward (gethash name *%forward-classes*)))
    (if forward
        (progn
          (remhash name *%forward-classes*)
          (change-class forward (%as-class metaclass))
          (setf (find-class name) forward)
          (apply #'reinitialize-instance forward :name name (%class-keys keys))
          forward)
        (let ((made (apply #'make-instance (%as-class metaclass) :name name (%class-keys keys))))
          (setf (find-class name) made)
          made))))

(defmethod ensure-class-using-class ((class class) name &rest keys
                                     &key (metaclass 'standard-class) &allow-other-keys)
  (let ((meta (%as-class metaclass)))
    (unless (eq (%instance-class class) meta)
      (change-class class meta))
    (apply #'reinitialize-instance class :name name (%class-keys keys))
    class))

(defun ensure-class (name &rest keys &key &allow-other-keys)
  "A class whose proper name is NAME is redefined. One `find-class` still
finds under NAME after it was renamed is not, and a new class is made."
  (let ((existing (find-class name nil)))
    (apply #'ensure-class-using-class
           (and existing (eq (%class-ref existing name) name) existing)
           name keys)))

(defmethod update-instance-for-different-class :after ((previous forward-referenced-class)
                                                       (current class) &rest initargs)
  (declare (ignore initargs))
  (setf (%class-ref current direct-subclasses) (%class-ref previous direct-subclasses)))

;;; --- defclass ---

(defun %canonical-slot-spec (spec)
  "A defclass slot specifier as the form that builds its canonical plist."
  (let ((name (if (consp spec) (car spec) spec))
        (options (if (consp spec) (cdr spec) nil))
        (initargs nil) (readers nil) (writers nil) (others nil)
        (seen nil) (initform-p nil) (initform nil))
    (unless (and (symbolp name) name (not (constantp name)))
      (%program-error "~S cannot name a slot." name))
    (when (oddp (length options))
      (%program-error "The options of the slot ~S do not come in pairs." name))
    (do ((walk options (cddr walk)))
        ((null walk))
      (let ((key (car walk)) (value (cadr walk)))
        (case key
          (:initarg (push value initargs))
          (:reader (push value readers))
          (:writer (push value writers))
          (:accessor (push value readers) (push `(setf ,value) writers))
          ((:initform :type :allocation :documentation)
           (when (%memq key seen)
             (%program-error "The slot option ~S is given twice for ~S." key name))
           (push key seen)
           (if (eq key :initform)
               (setq initform-p t initform value)
               (progn
                 (when (and (eq key :allocation) (not (%memq value '(:instance :class))))
                   (%program-error "~S is not a slot allocation." value))
                 (setq others (list* key `',value others)))))
          (t (%program-error "~S is not a slot option of defclass." key)))))
    `(list :name ',name
           ,@(when initform-p
               `(:initform ',initform :initfunction (lambda () ,initform)))
           ,@(when initargs `(:initargs ',(reverse initargs)))
           ,@(when readers `(:readers ',(reverse readers)))
           ,@(when writers `(:writers ',(reverse writers)))
           ,@others)))

(defun %canonical-default-initargs (plist)
  (when (oddp (length plist))
    (%program-error "The :default-initargs ~S do not come in pairs." plist))
  (let ((forms nil) (seen nil))
    (do ((walk plist (cddr walk)))
        ((null walk))
      (when (%memq (car walk) seen)
        (%program-error "The default initarg ~S is given twice." (car walk)))
      (push (car walk) seen)
      (push `(list ',(car walk) ',(cadr walk) (lambda () ,(cadr walk))) forms))
    `(list ,@(nreverse forms))))

(defun %canonical-class-options (options)
  (let ((result nil) (seen nil))
    (dolist (option options)
      (unless (and (consp option) (symbolp (car option)))
        (%program-error "~S is not a class option." option))
      (when (%memq (car option) seen)
        (%program-error "The class option ~S is given twice." (car option)))
      (push (car option) seen)
      (case (car option)
        (:default-initargs
         (setq result (list* :direct-default-initargs
                             (%canonical-default-initargs (cdr option)) result)))
        (:documentation (setq result (list* :documentation `',(cadr option) result)))
        (:metaclass (setq result (list* :metaclass `',(cadr option) result)))
        (t (%program-error "~S is not a defclass option." (car option)))))
    result))

(defmacro defclass (name direct-superclasses direct-slots &rest options)
  (unless (and (symbolp name) name)
    (%program-error "~S cannot name a class." name))
  (unless (listp direct-superclasses)
    (%program-error "~S is not a list of superclasses." direct-superclasses))
  (unless (listp direct-slots)
    (%program-error "~S is not a list of slots." direct-slots))
  (let ((names nil))
    (dolist (slot direct-slots)
      (let ((slot-name (if (consp slot) (car slot) slot)))
        (when (%memq slot-name names)
          (%program-error "The slot ~S appears twice in ~S." slot-name name))
        (push slot-name names))))
  `(ensure-class ',name
                 :direct-superclasses ',direct-superclasses
                 :direct-slots (list ,@(mapcar #'%canonical-slot-spec direct-slots))
                 ,@(%canonical-class-options options)))

;;; --- methods through generic functions ---

(defgeneric add-method (generic-function method))
(defmethod add-method ((generic-function standard-generic-function) (method method))
  (%std-add-method generic-function method))

(defgeneric remove-method (generic-function method))
(defmethod remove-method ((generic-function standard-generic-function) (method method))
  (%std-remove-method generic-function method))

(defun %specializer-designated (designator)
  (cond ((%instance-p designator) designator)
        ((and (consp designator) (eq (car designator) 'eql))
         (intern-eql-specializer (cadr designator)))
        ((symbolp designator) (find-class designator))
        (t (error "~S is not a specializer." designator))))

(defgeneric find-method (generic-function qualifiers specializers &optional errorp))
(defmethod find-method ((generic-function standard-generic-function) qualifiers specializers
                        &optional (errorp t))
  (let ((required (%gf-ref generic-function required-count)))
    (unless (= (length specializers) required)
      (error "~S takes ~D required arguments, so ~S cannot name one of its methods."
             (%gf-ref generic-function name) required specializers)))
  (let* ((specializers (mapcar #'%specializer-designated specializers))
         (found (%find-method-same generic-function qualifiers specializers)))
    (cond (found found)
          (errorp (error "~S has no method with qualifiers ~S and specializers ~S."
                         (%gf-ref generic-function name) qualifiers specializers))
          (t nil))))

(defgeneric compute-applicable-methods (generic-function arguments))
(defmethod compute-applicable-methods ((generic-function standard-generic-function) arguments)
  (%std-compute-applicable-methods generic-function arguments))

(defgeneric compute-applicable-methods-using-classes (generic-function classes))
(defmethod compute-applicable-methods-using-classes ((generic-function standard-generic-function)
                                                     classes)
  (let ((applicable nil)
        (definite t)
        (positions (%gf-precedence-positions generic-function)))
    (dolist (method (%gf-ref generic-function methods))
      (let ((rest classes)
            (applies t))
        (dolist (specializer (%method-ref method specializers))
          (cond ((%eql-specializer-p specializer)
                 (when (%subclassp (%class-of (%eql-ref specializer object)) (car rest))
                   (setq definite nil))
                 (setq applies nil))
                ((not (%subclassp (car rest) specializer))
                 (setq applies nil)))
          (setq rest (cdr rest)))
        (when applies (push method applicable))))
    (if definite
        (values (stable-sort (nreverse applicable)
                             (lambda (a b) (%more-specific-by-classes-p a b classes positions)))
                t)
        (values nil nil))))

(defgeneric compute-effective-method (generic-function method-combination methods))
(defmethod compute-effective-method ((generic-function standard-generic-function)
                                     method-combination methods)
  (values (%std-compute-effective-method generic-function method-combination methods) nil))

(defgeneric find-method-combination (generic-function type options))
(defmethod find-method-combination ((generic-function standard-generic-function) type options)
  (%find-method-combination (%gf-ref generic-function name) (cons type options)))

(defgeneric function-keywords (method))
(defmethod function-keywords ((method standard-method))
  (destructuring-bind (required optional rest keys allow key-p)
      (%parse-lambda-list (%method-ref method lambda-list))
    (declare (ignore required optional rest key-p))
    (values (mapcar #'%keyword-of keys) allow)))

;;; --- metaobjects made with make-instance ---

(defmethod shared-initialize :after ((generic-function standard-generic-function) slot-names
                                     &key (method-combination nil combination-p)
                                     &allow-other-keys)
  (declare (ignore slot-names))
  (when (and combination-p (consp method-combination))
    (setf (%gf-ref generic-function method-combination)
          (%find-method-combination (%gf-ref generic-function name) method-combination)))
  (%finish-generic-function generic-function))

;;; --- printing ---

(defun %print-unreadable-object (object stream type identity body)
  (let ((stream (cond ((null stream) *standard-output*)
                      ((eq stream t) *terminal-io*)
                      (t stream))))
    (when *print-readably*
      (error 'print-not-readable :object object))
    (write-string "#<" stream)
    (when type
      (prin1 (type-of object) stream)
      (when (or body identity) (write-char #\Space stream)))
    (when body (funcall body))
    (when identity
      (when body (write-char #\Space stream))
      (format stream "{~X}" (%object-address object)))
    (write-string ">" stream)
    nil))

(defmacro print-unreadable-object ((object stream &key type identity) &body body)
  `(%print-unreadable-object ,object ,stream ,type ,identity
                             ,(if body `(lambda () ,@body) nil)))

(defgeneric print-object (object stream))
(defmethod print-object ((object t) stream)
  (%write-unhooked object stream)
  object)
(defmethod print-object ((object standard-object) stream)
  (print-unreadable-object (object stream :type t :identity t))
  object)
(defmethod print-object ((object class) stream)
  (print-unreadable-object (object stream :type t)
    (prin1 (%class-ref object name) stream))
  object)
(defmethod print-object ((object generic-function) stream)
  (print-unreadable-object (object stream :type t)
    (prin1 (generic-function-name object) stream))
  object)
(defmethod print-object ((object standard-method) stream)
  (print-unreadable-object (object stream :type t)
    (let ((gf (%method-ref object generic-function)))
      (format stream "~S ~{~S ~}~S"
              (and gf (generic-function-name gf))
              (%method-ref object qualifiers)
              (mapcar (lambda (specializer)
                        (if (%eql-specializer-p specializer)
                            (list 'eql (%eql-ref specializer object))
                            (%class-ref specializer name)))
                      (%method-ref object specializers)))))
  object)
(defmethod print-object ((object slot-definition) stream)
  (print-unreadable-object (object stream :type t)
    (prin1 (slot-definition-name object) stream))
  object)
(defmethod print-object ((object eql-specializer) stream)
  (print-unreadable-object (object stream :type t)
    (prin1 (%eql-ref object object) stream))
  object)
(defmethod print-object ((object method-combination) stream)
  (print-unreadable-object (object stream :type t)
    (prin1 (%combination-ref object name) stream))
  object)

;;; --- describe ---

(defgeneric describe-object (object stream))
(defmethod describe-object ((object t) stream)
  (format stream "~&~S is of type ~S.~%" object (type-of object))
  (values))
(defmethod describe-object ((object standard-object) stream)
  (%describe-slots object stream))

(defun %describe-slots (object stream)
  (let ((class (class-of object)))
    (format stream "~&~S is an instance of ~S.~%" object (class-name class))
    (dolist (slotd (class-slots class))
      (let ((name (slot-definition-name slotd)))
        (if (slot-boundp object name)
            (format stream "  ~S = ~S~%" name (slot-value object name))
            (format stream "  ~S is unbound~%" name)))))
  (values))

(defun describe (object &optional (stream *standard-output*))
  (let ((stream (cond ((null stream) *standard-output*)
                      ((eq stream t) *terminal-io*)
                      (t stream))))
    (describe-object object stream)
    (values)))

;;; --- documentation ---

(defgeneric documentation (x doc-type))
(defgeneric (setf documentation) (new-value x doc-type))

(defun %documentation-key (doc-type)
  (intern (concatenate 'string "%DOCUMENTATION-" (symbol-name doc-type)) "COMMON-LISP"))

(defmethod documentation ((x symbol) doc-type)
  (cond ((and (eq doc-type 'type) (find-class x nil))
         (documentation (find-class x) t))
        ((and (eq doc-type 'function) (fboundp x) (%generic-function-p (fdefinition x)))
         (%gf-ref (fdefinition x) documentation))
        ((and (eq doc-type 'method-combination) (gethash x *%method-combination-types*))
         (cdr (gethash x *%method-combination-types*)))
        (t (get x (%documentation-key doc-type)))))
(defmethod (setf documentation) (new-value (x symbol) doc-type)
  (cond ((and (eq doc-type 'type) (find-class x nil))
         (setf (documentation (find-class x) t) new-value))
        (t (%put x (%documentation-key doc-type) new-value)))
  new-value)

(defmethod documentation ((x list) doc-type)
  (if (and (eq (car x) 'setf) (fboundp x) (%generic-function-p (fdefinition x)))
      (%gf-ref (fdefinition x) documentation)
      (get (cadr x) (%documentation-key (if (eq doc-type 'function) 'setf-function doc-type)))))
(defmethod (setf documentation) (new-value (x list) doc-type)
  (%put (cadr x) (%documentation-key (if (eq doc-type 'function) 'setf-function doc-type))
        new-value)
  new-value)

(defmethod documentation ((x class) doc-type)
  (declare (ignore doc-type))
  (%class-ref x documentation))
(defmethod (setf documentation) (new-value (x class) doc-type)
  (declare (ignore doc-type))
  (setf (%class-ref x documentation) new-value))

(defmethod documentation ((x standard-generic-function) doc-type)
  (declare (ignore doc-type))
  (%gf-ref x documentation))
(defmethod (setf documentation) (new-value (x standard-generic-function) doc-type)
  (declare (ignore doc-type))
  (setf (%gf-ref x documentation) new-value))

(defmethod documentation ((x standard-method) doc-type)
  (declare (ignore doc-type))
  (%method-ref x documentation))
(defmethod (setf documentation) (new-value (x standard-method) doc-type)
  (declare (ignore doc-type))
  (setf (%method-ref x documentation) new-value))

(defmethod documentation ((x standard-slot-definition) doc-type)
  (declare (ignore doc-type))
  (%slotd-ref x documentation))
(defmethod (setf documentation) (new-value (x standard-slot-definition) doc-type)
  (declare (ignore doc-type))
  (setf (%slotd-ref x documentation) new-value))

(defmethod documentation ((x method-combination) doc-type)
  (declare (ignore doc-type))
  (%combination-ref x documentation))

(defmethod documentation ((x function) doc-type)
  (declare (ignore doc-type))
  nil)

;;; --- with-slots, with-accessors ---

(defmacro with-slots (slot-entries instance-form &body body)
  (let ((instance (gensym "INSTANCE")))
    `(let ((,instance ,instance-form))
       (declare (ignorable ,instance))
       (symbol-macrolet ,(mapcar (lambda (entry)
                                   (if (consp entry)
                                       `(,(car entry) (slot-value ,instance ',(cadr entry)))
                                       `(,entry (slot-value ,instance ',entry))))
                                 slot-entries)
         ,@body))))

(defmacro with-accessors (slot-entries instance-form &body body)
  (let ((instance (gensym "INSTANCE")))
    `(let ((,instance ,instance-form))
       (declare (ignorable ,instance))
       (symbol-macrolet ,(mapcar (lambda (entry) `(,(car entry) (,(cadr entry) ,instance)))
                                 slot-entries)
         ,@body))))

;;; --- make-load-form ---

(defgeneric make-load-form (object &optional environment))
(defmethod make-load-form ((object t) &optional environment)
  (declare (ignore environment))
  (error "~S has no load form." object))
(defmethod make-load-form ((object class) &optional environment)
  (declare (ignore environment))
  (let ((name (%class-ref object name)))
    (if (and name (eq (find-class name nil) object))
        `(find-class ',name)
        (error "~S has no proper name, so it has no load form." object))))

(defun make-load-form-saving-slots (object &key (slot-names nil slot-names-p) environment)
  (declare (ignore environment))
  (let* ((class (class-of object))
         (names (if slot-names-p
                    slot-names
                    (mapcar #'slot-definition-name
                            (remove-if-not (lambda (slotd)
                                             (eq (slot-definition-allocation slotd) :instance))
                                           (class-slots class))))))
    (values `(allocate-instance (find-class ',(class-name class)))
            `(progn
               ,@(mapcar (lambda (name)
                           (if (slot-boundp object name)
                               `(setf (slot-value ,object ',name) ',(slot-value object name))
                               `(slot-makunbound ,object ',name)))
                         names)))))

;;; --- literal objects in compiled files ---
;;;
;;; A fasl is read back as source, so an object of a class that defines
;;; `make-load-form` cannot be written into it as it stands. Each one is
;;; made at load time by its creation form and finished by its
;;; initialization form (CLHS 3.2.4.4), and the forms refer to it through
;;; a `#.` lookup into a table the fasl fills as it loads.

(defvar *%fasl-table* nil)

(defun %fasl-begin ()
  (setq *%fasl-table* (make-hash-table)))

(defun %fasl-set (index object)
  (setf (gethash index *%fasl-table*) object))

(defun %fasl-object (index)
  (gethash index *%fasl-table*))

(defstruct (%fasl-reference (:constructor %make-fasl-reference (index))
                            (:copier nil) (:predicate nil)
                            (:print-object %print-fasl-reference))
  index)

(defun %print-fasl-reference (reference stream)
  (let ((*package* (find-package "KEYWORD")))
    (format stream "#.(~S ~D)" '%fasl-object (%fasl-reference-index reference))))

;; The state of one externalization: what each object it has seen became,
;; the forms written so far, and the initialization forms held back until
;; the form being built is done.
(defvar *%externalized* nil)
(defvar *%externalized-forms* nil)
(defvar *%deferred-initializations* nil)

(defun %needs-load-form-p (object)
  (or (typep object 'standard-object)
      (typep object 'structure-object)
      (typep object 'condition)))

(defun %tree-contains-p (tree object)
  (let ((seen (make-hash-table :test #'eq)))
    (labels ((walk (x)
               (cond ((eq x object) t)
                     ((gethash x seen) nil)
                     ((consp x) (setf (gethash x seen) t)
                      (or (walk (car x)) (walk (cdr x))))
                     ((and (vectorp x) (not (stringp x)))
                      (setf (gethash x seen) t)
                      (some #'walk x))
                     (t nil))))
      (walk tree))))

(defun %externalize-tree (tree within)
  "TREE with each object that needs a load form replaced by a reference
to the one load makes. WITHIN is the object whose form TREE belongs to."
  (let ((seen (make-hash-table :test #'eq)))
    (labels ((walk (x)
               (cond ((%needs-load-form-p x) (%externalize-object x within))
                     ((gethash x seen) x)
                     ((consp x)
                      (setf (gethash x seen) t)
                      (let ((head (walk (car x)))
                            (tail (walk (cdr x))))
                        (if (and (eq head (car x)) (eq tail (cdr x))) x (cons head tail))))
                     ((and (simple-vector-p x) (some #'%needs-load-form-p x))
                      (map 'vector #'walk x))
                     (t x))))
      (walk tree))))

(defun %externalize-object (object within)
  "The reference to OBJECT, writing out its creation form, once what that
refers to has been written, and its initialization form. An
initialization that waits on an object goes after that object's own
initialization, and one that depends on WITHIN, the object whose form
OBJECT turned up in, goes after WITHIN's."
  (let ((known (gethash object *%externalized*)))
    (if known
        known
        (let* ((index (hash-table-count *%externalized*))
               (reference (%make-fasl-reference index)))
          (setf (gethash object *%externalized*) reference)
          (multiple-value-bind (creation initialization) (make-load-form object)
            (let ((initialization-form nil)
                  (waiting nil))
              (let ((*%deferred-initializations* nil))
                (push `(%fasl-set ,index ,(%externalize-tree creation object))
                      *%externalized-forms*)
                (when initialization
                  (setq initialization-form (%externalize-tree initialization object)))
                (setq waiting (reverse *%deferred-initializations*)))
              (let ((after-creation (append (when initialization (list initialization-form))
                                            waiting)))
                (if (and within initialization (%tree-contains-p initialization within))
                    (dolist (form after-creation)
                      (push form *%deferred-initializations*))
                    (dolist (form after-creation)
                      (push form *%externalized-forms*))))))
          reference))))

(defun %externalize-load-forms (forms)
  (let ((*%externalized* (make-hash-table :test #'eq))
        (*%externalized-forms* (list '(%fasl-begin))))
    (dolist (form forms)
      (let ((*%deferred-initializations* nil))
        (let ((externalized (%externalize-tree form nil)))
          (push externalized *%externalized-forms*)
          (dolist (later (reverse *%deferred-initializations*))
            (push later *%externalized-forms*)))))
    (nreverse *%externalized-forms*)))

;;; --- the end of the bootstrap ---

(setq *%standard-metaclasses*
      (list *%the-class-standard-class* *%the-class-funcallable-standard-class*
            (find-class 'condition-class)))

(setq *%clos-booted* t)

(defun set-funcallable-instance-function (funcallable-instance function)
  (%set-funcallable-instance-function funcallable-instance function))

(export '(add-method allocate-instance built-in-class call-method call-next-method
          change-class class class-name class-of compute-applicable-methods defclass
          defgeneric define-method-combination defmethod describe describe-object
          documentation ensure-generic-function find-class find-method function-keywords
          generic-function initialize-instance invalid-method-error make-instance
          make-instances-obsolete make-load-form make-load-form-saving-slots make-method
          method method-combination method-combination-error method-qualifiers
          next-method-p no-applicable-method no-next-method print-object
          print-unreadable-object reinitialize-instance remove-method shared-initialize
          slot-boundp slot-exists-p slot-makunbound slot-missing slot-unbound slot-value
          standard standard-class standard-generic-function standard-method standard-object
          structure-class structure-object update-instance-for-different-class
          update-instance-for-redefined-class with-accessors with-slots
          type structure compiler-macro variable))

(defparameter *%mop-symbols*
  '(accessor-method-slot-definition add-direct-subclass class-default-initargs
    class-direct-default-initargs class-direct-slots class-direct-subclasses
    class-direct-superclasses class-finalized-p class-precedence-list class-prototype
    class-slots compute-applicable-methods-using-classes compute-class-precedence-list
    compute-default-initargs compute-effective-method compute-effective-slot-definition
    compute-slots direct-slot-definition direct-slot-definition-class
    effective-slot-definition effective-slot-definition-class ensure-class
    ensure-class-using-class eql-specializer eql-specializer-object finalize-inheritance
    find-method-combination forward-referenced-class funcallable-standard-class
    funcallable-standard-object generic-function-argument-precedence-order
    generic-function-declarations generic-function-lambda-list
    generic-function-method-class generic-function-method-combination
    generic-function-methods generic-function-name intern-eql-specializer metaobject
    method-combination-name method-function method-generic-function method-lambda-list
    method-specializers reader-method-class remove-direct-subclass
    set-funcallable-instance-function slot-boundp-using-class slot-definition
    slot-definition-allocation slot-definition-initargs slot-definition-initform
    slot-definition-initfunction slot-definition-location slot-definition-name
    slot-definition-readers slot-definition-type slot-definition-writers
    slot-makunbound-using-class slot-value-using-class specializer
    specializer-direct-generic-functions specializer-direct-methods
    standard-accessor-method standard-direct-slot-definition
    standard-effective-slot-definition standard-reader-method standard-slot-definition
    standard-writer-method validate-superclass writer-method-class))

(let ((mop (or (find-package "ZISP-MOP") (make-package "ZISP-MOP" :nicknames '("MOP") :use nil))))
  (import *%mop-symbols* mop)
  (export *%mop-symbols* mop))
