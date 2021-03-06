(in-package :mgl-mat)

;;;; WITH-THREAD-CACHED-OBJECT

(defvar *thread-caches* (tg:make-weak-hash-table :weakness :key))

(defvar *thread-cache-lock* (bordeaux-threads:make-lock "thread cache lock"))

(defun borrow-thread-cached-object (place-key key)
  (let ((thread-cache
          (bordeaux-threads:with-lock-held (*thread-cache-lock*)
            (gethash (bordeaux-threads:current-thread) *thread-caches*))))
    (when thread-cache
      (let ((place-cache (gethash place-key thread-cache)))
        (when place-cache
          (prog1 (gethash key place-cache)
            (remhash key place-cache)))))))

(defun return-thread-cached-object (place-key key value)
  (let* ((thread-cache
           (bordeaux-threads:with-lock-held (*thread-cache-lock*)
             (or (gethash (bordeaux-threads:current-thread) *thread-caches*)
                 (setf (gethash (bordeaux-threads:current-thread)
                                *thread-caches*)
                       (tg:make-weak-hash-table :weakness :key)))))
         (place-cache
           (or (gethash place-key thread-cache)
               (setf (gethash place-key thread-cache)
                     (make-hash-table :test #'equal)))))
    ;; Overwrite it. Keeping the larger, keeping all may be reasonable
    ;; strategies too.
    (setf (gethash key place-cache) value)))

;;; A thread safe, reentrant caching mechanism with a separate cache
;;; for each PLACE (or for each occurrence of
;;; WITH-THREAD-CACHED-OBJECT in the sources if PLACE is not
;;; specified).
;;;
;;; Conceptually, the thread cache associates a (THREAD PLACE KEY)
;;; triplet with an object. THREAD is the current thread. PLACE is
;;; specified explicitly or it is a gensym unique to each occurrence
;;; of WITH-THREAD-CACHED-OBJECT. KEY is provided by the user.
;;;
;;; Before BODY is executed, VAR is bound to the object associated
;;; with (THREAD PLACE KEY). When BODY is finished, the same triplet
;;; is associated with the then current binding of VAR which may have
;;; been changed by BODY.
;;;
;;; In the example below, ARRAY is bound to an array of the
;;; appropriate ELEMENT-TYPE:
;;;
;;;     (with-thread-cached-object (array element-type
;;;                                 (make-array 7 :element-type element-type))
;;;      (do-something-with array))
;;;
;;; The same thing with a thread global cache:
;;;
;;;     (with-thread-cached-object (array element-type
;;;                                 (make-array 7 :element-type element-type)
;;;                                 :place :thread-global)
;;;      (do-something-with array))
;;;
;;; where :THREAD-GLOBAL can be anything as long as other uses agree
;;; on it.
(defmacro with-thread-cached-object ((var key initform &key place) &body body)
  (let ((place (or place (gensym (symbol-name 'place)))))
    (alexandria:once-only (key)
      `(let ((,var (or (borrow-thread-cached-object ',place ,key)
                       ,initform)))
         (unwind-protect
              (locally ,@body)
           (return-thread-cached-object ',place ,key ,var))))))


;;;; Parameters are lists of the form (NAME TYPE &OPTIONAL (DIRECTION
;;;; :INPUT)). The signatures of blas/cublas functions, cuda/lisp
;;;; kernels are made of parameters.

;;; Determines to which type :MAT is translated. It's (:POINTER
;;; :FLOAT) for the two foreign library wrappers, FLOAT* for cuda
;;; kernels, and (SINGLE-ARRAY SINGLE-FLOAT (*)) for lisp kernels.
(defvar *mat-param-type*)

(defun param-name (param)
  (first param))

(defun param-type (param)
  (if (eq (second param) :mat)
      *mat-param-type*
      (second param)))

(defun param-direction (param)
  (or (third param) :input))

(defun mat-param-p (param)
  (eq (second param) :mat))

(defun non-mat-output-param-p (param)
  (and (not (mat-param-p param))
       (eq (param-direction param) :output)))


;;;; Common utilities for DEFINE-BLAS-FUNCTION and
;;;; DEFINE-CUBLAS-FUNCTION

(defun convert-param-type (object)
  (cond ((eq object :float)
         :double)
        (t
         object)))

(defun convert-param-types (params type)
  (if (eq type :double)
      (map-tree #'convert-param-type params)
      params))

(defun ctype-blas-prefix (ctype)
  (ecase ctype
    ((nil) "")
    ((:float) "s")
    ((:double) "d")))

(defun ensure-pointer-param (param)
  (let ((ctype (param-type param)))
    (if (and (listp ctype)
             (eq (first ctype) :pointer))
        param
        (list (param-name param)
              `(:pointer ,ctype) (param-direction param)))))


;;;; Common utilities for DEFINE-CUDA-KERNEL and DEFINE-LISP-KERNEL

(defun facet-vars (mat-params)
  (mapcar (lambda (mat-param)
            (gensym (string (param-name mat-param))))
          mat-params))


;;;; Base class for cuda and normal foreign pointers. It remembers the
;;;; original base pointer which is presumed to have been returned by
;;;; some kind of allocation function, but allows for offseting said
;;;; base pointer.

(defclass offset-pointer ()
  ((base-pointer :initarg :base-pointer :reader base-pointer)
   (offset :initform 0 :initarg :offset :reader offset)
   (n-bytes :initarg :n-bytes :reader pointer-n-bytes)))

(defgeneric offset-pointer (offset-pointer)
  (:method ((array offset-pointer))
    (let ((base-pointer (slot-value array 'base-pointer)))
      (cond ((null base-pointer)
             nil)
            ((cffi:pointerp base-pointer)
             (cffi:inc-pointer base-pointer (offset array)))
            (t
             (+ base-pointer (offset array)))))))


(defsection @mat-ctypes (:title "Element types")
  (*supported-ctypes* variable)
  (ctype type)
  (*default-mat-ctype* variable)
  (coerce-to-ctype function))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *supported-ctypes* '(:float :double)))

(deftype ctype ()
  #.(format nil "This is basically `~S`." `(member ,@*supported-ctypes*))
  `(member ,@*supported-ctypes*))

(defparameter *lisp-foreign-cuda-lla-types*
  '((single-float :float :float :float 0)
    (double-float :double :double :double 1)))

(defun lisp->ctype (lisp-type)
  (second (find lisp-type *lisp-foreign-cuda-lla-types* :key #'first)))

(defun ctype->lisp (ctype)
  (first (find ctype *lisp-foreign-cuda-lla-types* :key #'second)))

(defun ctype->cuda (ctype)
  (third (find ctype *lisp-foreign-cuda-lla-types* :key #'second)))

(defun ctype->lla (ctype)
  (fourth (find ctype *lisp-foreign-cuda-lla-types* :key #'second)))

(defun ctype->lla-internal (ctype)
  (fifth (find ctype *lisp-foreign-cuda-lla-types* :key #'second)))

(defvar *default-mat-ctype* :double
  "By default MATs are created with this ctype. One of :FLOAT
  or :DOUBLE.")

(defun coerce-to-ctype (x &key (ctype *default-mat-ctype*))
  "Coerce the scalar X to the lisp type corresponding to CTYPE."
  (ecase ctype
    ((:float) (float x 0.0))
    ((:double) (float x 0d0))))

;;; Faster version of CFFI:FOREIGN-TYPE-SIZE.
(declaim (inline ctype-size))
(defun ctype-size (ctype)
  (if (eq ctype :float)
      4
      8))


;;;; Misc

(deftype index () '(integer 0 #.(1- array-total-size-limit)))

(defparameter *no-array-bounds-check*
  #+sbcl '(sb-c::insert-array-bounds-checks 0)
  ;; (SAFETY 0) is too coarse, avoid warnings by using the
  ;; relatively uncontroversial (SPEED 3) instead of ().
  #-sbcl '(speed 3))

;;; A version of THE that's trusted by the compiler.
(defmacro the! (&rest args)
  `(#+sbcl sb-ext:truly-the
    #+cmu ext:truly-the
    #-(or sbcl cmu) the
    ,@args))

;;; Beat Allegro's underflow errors into submission with a club. The
;;; values must be known to be FLT for this to work.
#+allegro
(defmacro with-zero-on-underflow ((prototype) &body body)
  (alexandria:with-gensyms (trap-underflow)
    `(catch ',trap-underflow
       (handler-bind ((floating-point-underflow
                        #'(lambda (c)
                            (declare (ignore c))
                            (throw ',trap-underflow (float 0 ,prototype)))))
         ,@body))))

#-allegro
(defmacro with-zero-on-underflow ((prototype) &body body)
  (declare (ignore prototype))
  `(locally ,@body))

(defun append-to-symbol (symbol suffix)
  ;; Rely on the reader to get case right.
  (read-from-string (format nil "~A::~A~A"
                            (package-name (symbol-package symbol))
                            (symbol-name symbol) suffix)))

(defun map-tree (fn tree)
  (let ((tree (funcall fn tree)))
    (if (listp tree)
        (mapcar (lambda (subtree)
                  (map-tree fn subtree))
                tree)
        tree)))

(declaim (inline clip))
(defun clip (x &key min max)
  (max (min x max) min))

(defun round-up (number divisor)
  (* (ceiling number divisor) divisor))

(cffi:defcfun memcpy :void
  (dest :pointer)
  (src :pointer)
  (n cl-cuda.driver-api:size-t))


;;;; Float I/O

(defun write-as-bytes (integer n stream)
  (declare (type (unsigned-byte 64) integer)
           (type (unsigned-byte 4) n)
           (optimize speed))
  (let ((x integer))
    (declare (type (unsigned-byte 64) x))
    (loop repeat n do
      (write-byte (logand x #xff) stream)
      (setq x (ash x -8)))
    (assert (zerop x))))

(defun read-as-bytes (n stream)
  (declare (type (unsigned-byte 4) n))
  (let ((x 0))
    (declare (type (unsigned-byte 64) x)
             (optimize speed))
    (loop for i below n do
      (setq x (the! (unsigned-byte 64)
                    (+ x (the! (unsigned-byte 64)
                               (ash (the! (unsigned-byte 8)
                                          (read-byte stream))
                                    (* i 8)))))))
    x))

(defun write-single-float-vector/generic (array stream &key (start 0)
                                          (end (array-total-size array)))
  (loop for i upfrom start below end do
    (write-as-bytes (ieee-floats:encode-float32 (row-major-aref array i))
                    4 stream)))

(defun write-double-float-vector/generic (array stream &key (start 0)
                                          (end (array-total-size array)))
  (loop for i upfrom start below end do
    (write-as-bytes (ieee-floats:encode-float64 (row-major-aref array i))
                    8 stream)))

(defun read-single-float-vector/generic (array stream &key (start 0)
                                         (end (array-total-size array)))
  (loop for i upfrom start below end do
    (setf (row-major-aref array i)
          (ieee-floats:decode-float32 (read-as-bytes 4 stream)))))

(defun read-double-float-vector/generic (array stream &key (start 0)
                                         (end (array-total-size array)))
  (loop for i upfrom start below end do
    (setf (row-major-aref array i)
          (ieee-floats:decode-float64 (read-as-bytes 8 stream)))))

(deftype single-float-vector () '(simple-array single-float (*)))
(deftype double-float-vector () '(simple-array double-float (*)))

#+(and sbcl little-endian)
(progn
  (defun sync->fd (fd-stream)
    (force-output fd-stream)
    (let ((fd (sb-impl::fd-stream-fd fd-stream)))
      (sb-unix:unix-lseek fd (file-position fd-stream) sb-unix:l_set)))

  (defun sync<-fd (fd-stream)
    (let ((fd (sb-impl::fd-stream-fd fd-stream)))
      (file-position fd-stream (sb-unix:unix-lseek fd 0 sb-unix:l_incr))))

  (defun write-single-float-vector (array stream &key (start 0)
                                    (end (length array)))
    (declare (type single-float-vector array))
    (if (typep stream 'sb-sys:fd-stream)
        (sb-sys:with-pinned-objects (array)
          (sync->fd stream)
          (let ((fd (sb-impl::fd-stream-fd stream)))
            (sb-unix:unix-write fd (sb-sys:vector-sap array)
                                (* 4 start) (* 4 (- end start))))
          (sync<-fd stream))
        (write-single-float-vector/generic array stream :start start :end end)))

  (defun read-single-float-vector (array stream &key (start 0)
                                   (end (length array)))
    (declare (type single-float-vector array))
    (if (typep stream 'sb-sys:fd-stream)
        (sb-sys:with-pinned-objects (array)
          (sync->fd stream)
          (let* ((l (* 4 (- end start)))
                 (l2 (sb-unix:unix-read (sb-impl::fd-stream-fd stream)
                                        (sb-sys:sap+ (sb-sys:vector-sap array)
                                                     (* 4 start))
                                        l)))
            (sync<-fd stream)
            (unless (= l l2)
              (error "Read only ~S bytes out of ~S~%" l2 l))))
        (read-single-float-vector/generic array stream :start start :end end)))

  (defun write-double-float-vector (array stream &key (start 0)
                                    (end (length array)))
    (declare (type double-float-vector array))
    (if (typep stream 'sb-sys:fd-stream)
        (sb-sys:with-pinned-objects (array)
          (sync->fd stream)
          (let ((fd (sb-impl::fd-stream-fd stream)))
            (sb-unix:unix-write fd (sb-sys:vector-sap array)
                                (* 8 start) (* 8 (- end start))))
          (sync<-fd stream))
        (write-double-float-vector/generic array stream :start start :end end)))

  (defun read-double-float-vector (array stream &key (start 0)
                                   (end (length array)))
    (declare (type double-float-vector array))
    (if (typep stream 'sb-sys:fd-stream)
        (sb-sys:with-pinned-objects (array)
          (sync->fd stream)
          (let ((l (* 8 (- end start))))
            (multiple-value-bind (l2 errno)
                (sb-unix:unix-read (sb-impl::fd-stream-fd stream)
                                   (sb-sys:sap+ (sb-sys:vector-sap array)
                                                (* 8 start))
                                   l)
              (when (null l2)
                (error "read() failed with errno ~D." errno))
              (sync<-fd stream)
              (unless (= l l2)
                (error "Read only ~S bytes out of ~S~%" l2 l)))))
        (read-double-float-vector/generic array stream :start start :end end))))

#+allegro
(progn
  (defun write-single-float-vector (array stream &key (start 0)
                                    (end (length array)))
    (declare (type single-float-vector array))
    (excl:write-vector array stream :start (* 4 start) :end (* 4 end)
                       #+big-endian :endian-swap #+big-endian :byte-32))

  (defun read-single-float-vector (array stream &key (start 0)
                                   (end (length array)))
    (declare (type single-float-vector array))
    (let* ((l (* 4 (- end start)))
           (l2 (- (excl:read-vector
                   array stream :start (* 4 start) :end (* 4 end)
                   #+big-endian :endian-swap #+big-endian :byte-32)
                  (* 4 start))))
      (unless (= l l2)
        (error "Read only ~S bytes out of ~S~%" l2 l))))

  (defun write-double-float-vector (array stream &key (start 0)
                                    (end (length array)))
    (declare (type double-float-vector array))
    (excl:write-vector array stream :start (* 8 start) :end (* 8 end)
                       #+big-endian :endian-swap #+big-endian :byte-64))

  (defun read-double-float-vector (array stream &key (start 0)
                                   (end (length array)))
    (declare (type double-float-vector array))
    (let* ((l (* 8 (- end start)))
           (l2 (- (excl:read-vector
                   array stream :start (* 8 start) :end (* 8 end)
                   #+big-endian :endian-swap #+big-endian :byte-64)
                  (* 8 start))))
      (unless (= l l2)
        (error "Read only ~S bytes out of ~S~%" l2 l)))))

#-(or (and sbcl little-endian) allegro)
(progn
  (setf (symbol-function 'read-single-float-vector)
        #'read-single-float-vector/generic)
  (setf (symbol-function 'write-single-float-vector)
        #'write-single-float-vector/generic)
  (setf (symbol-function 'read-double-float-vector)
        #'read-double-float-vector/generic)
  (setf (symbol-function 'write-double-float-vector)
        #'write-double-float-vector/generic))
