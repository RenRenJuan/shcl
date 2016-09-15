(in-package :shcl.evaluate)

(optimization-settings)

(defparameter *umask*
  (logior sb-posix:s-irusr sb-posix:s-iwusr sb-posix:s-irgrp sb-posix:s-iroth)
  "The umask that should be used when creating new files.")

(define-condition not-implemented (warning error)
  ((message
    :initarg :message
    :initform ""
    :accessor not-implemented-message
    :type string))
  (:report (lambda (c s) (format s "NOT-IMPLEMENTED ~A~%" (not-implemented-message c))))
  (:documentation
   "A condition indicating that a feature hasn't been implemented
yet."))

(define-once-global %fd-retain-count-table% (make-hash-table)
  (:documentation
   "This table tracks how many outstanding retains each file
descriptor has."))
(define-once-global %fd-retain-count-table-lock% (make-lock)
  (:documentation
   "This lock protects `%fd-retain-count-table-lock%'."))
(defparameter *autorelease-fd-scope* nil
  "The collection of file descriptors that should be released when the
current fd scope exits.

This is bound by `with-fd-scope'.")

(defun fd-managed-p (fd)
  "Returns t iff the given fd is being managed with retain/release."
  (with-lock-held (%fd-retain-count-table-lock%)
    (not (not (gethash fd %fd-retain-count-table%)))))

(define-condition fd-already-managed (error)
  ((fd
    :initarg :fd
    :initform (required)
    :accessor fd-already-managed-fd))
  (:report (lambda (c s) (format s "Can't enter FD ~A into retain/release management again" (fd-already-managed-fd c)))))

(defun %manage-new-fd (fd)
  "Enter the given fd into the retain/release table."
  (when (gethash fd %fd-retain-count-table%)
    (error 'fd-already-managed :fd fd))
  (setf (gethash fd %fd-retain-count-table%) 1)
  fd)

(define-condition fd-not-managed (error)
  ((fd
    :initarg :fd
    :initform (required)
    :accessor fd-not-managed-fd))
  (:report (lambda (c s) (format s "Can't retain unmanaged FD ~A" (fd-not-managed-fd c)))))

(defun fd-retain (fd)
  "Increment the retain count for the given fd.

The given fd will not be closed in the shell process until the retain
count reaches 0.  See `fd-release'."
  (with-lock-held (%fd-retain-count-table-lock%)
    (unless (gethash fd %fd-retain-count-table%)
      (error 'fd-not-managed :fd fd))
    (incf (gethash fd %fd-retain-count-table%))
    fd))

(define-condition fd-over-release (error)
  ((fd
    :initarg :fd
    :initform (required)
    :accessor fd-over-release-fd))
  (:report (lambda (c s) (format s "FD ~A was over released" (fd-over-release-fd c)))))

(defun %fd-release (fd)
  "Do the work of `fd-release', but assume the table is already
locked."
  (unless (gethash fd %fd-retain-count-table%)
    (error 'fd-over-release :fd fd))
  (let ((count (decf (gethash fd %fd-retain-count-table%))))
    (when (equal 0 count)
      (debug-log 'status "CLOSE ~A" fd)
      (sb-posix:close fd)
      (remhash fd %fd-retain-count-table%)))
  nil)

(defun fd-release (fd)
  "Decrement the retain count for the given fd.

If the retain count reaches 0, then it will be closed immediately."
  (with-lock-held (%fd-retain-count-table-lock%)
    (%fd-release fd)))

(define-condition fd-autorelease-without-scope (error)
  ((fd
    :initarg :fd
    :initform (required)
    :accessor fd-autorelease-without-scope-fd))
  (:report (lambda (c s) (format s "FD ~A was autoreleased without an FD scope in place" (fd-autorelease-without-scope-fd c)))))

(defun fd-autorelease (fd)
  "Release the given fd when the current fd scope exits."
  (unless *autorelease-fd-scope*
    (error 'fd-autorelease-without-scope :fd fd))
  (vector-push-extend fd *autorelease-fd-scope*)
  fd)

(defmacro with-fd-scope (() &body body)
  "Introduce an fd scope.

Calls to `fd-autorelease' while this fd scope is active will not
decrement fd retain counts until control leaves this fd scope.

Additionally, any manipulations to the fd table `*fd-bindings*' will
be reverted when this scope exits."
  (let ((fd (gensym "FD")))
    `(let ((*fd-bindings* *fd-bindings*)
           (*autorelease-fd-scope* (make-extensible-vector :element-type 'integer)))
       (unwind-protect (progn ,@body)
         (with-lock-held (%fd-retain-count-table-lock%)
           (loop :for ,fd :across *autorelease-fd-scope* :do
              (%fd-release ,fd)))))))

(defmacro with-living-fds ((fd-list-sym) &body body)
  "Lock the fd table and list all managed file descriptors.

Since this locks the fd table, it is very important to minimize the
amount of work done in the body of this macro.  Ideally, you would
do nothing exept spawn a new process."
  `(with-lock-held (%fd-retain-count-table-lock%)
     (let ((,fd-list-sym (hash-table-keys %fd-retain-count-table%)))
       (declare (dynamic-extent ,fd-list-sym))
       ,@body)))

(defun open-retained (pathname flags mode)
  "This is a wrapper around the posix open function which
atomically adds the new fd to the fd table and gives it a +1 retain
count."
  (with-lock-held (%fd-retain-count-table-lock%)
    (let ((fd (sb-posix:open pathname flags mode)))
      (debug-log 'status "OPEN ~A = ~A" fd pathname)
      (%manage-new-fd fd))))

(defun pipe-retained ()
  "This is a wrapper around the posix pipe function which atomically
adds the new fds to the fd table and gives them +1 retain counts.

Returns two values: the read-end of the pipe and the write end of the
pipe."
  (with-lock-held (%fd-retain-count-table-lock%)
    (multiple-value-bind (read-end write-end) (sb-posix:pipe)
      (debug-log 'status "PIPE ~A -> ~A" write-end read-end)
      (values (%manage-new-fd read-end) (%manage-new-fd write-end)))))

(defmacro with-pipe ((read-end write-end) &body body)
  "Introduce a pipe into the retain table (as if with `pipe-retained')
with a +0 retain count.

That is, you do not need to release the file descriptors produced by
this macro.  You must balance any retains you perform on the given
file descriptors."
  (let ((raw-read-end (gensym "RAW-READ-END"))
        (raw-write-end (gensym "RAW-WRITE-END")))
    `(multiple-value-bind (,raw-read-end ,raw-write-end) (pipe-retained)
       (let ((,read-end (fd-autorelease ,raw-read-end))
             (,write-end (fd-autorelease ,raw-write-end)))
         ,@body))))

(defgeneric open-args-for-redirect (redirect)
  (:documentation
   "Returns the flags that should be passed to the posix open function
for the given redirect."))
(defmethod open-args-for-redirect ((r less))
  (declare (ignore r))
  (logior sb-posix:o-rdonly))
(defmethod open-args-for-redirect ((r great))
  (declare (ignore r))
  (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-trunc))
(defmethod open-args-for-redirect ((r dgreat))
  (declare (ignore r))
  (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-append))
(defmethod open-args-for-redirect ((r lessgreat))
  (declare (ignore r))
  (logior sb-posix:o-rdwr sb-posix:o-creat))

(defgeneric fd-from-description (description)
  (:documentation
   "Given a description of a place, produce a file descriptor for that place.

This function implements part of `bind-fd' and should not be called
directly."))
(defmethod fd-from-description ((fd integer))
  fd)
(defmethod fd-from-description ((io-file io-file))
  (with-slots (redirect filename) io-file
    (let ((fd (open-retained (coerce (expansion-for-word filename :split-fields nil :expand-pathname t)
                                     'simple-string)
                             (open-args-for-redirect redirect)
                             *umask*)))
      (fd-autorelease fd))))

(defparameter *fd-bindings* nil
  "This variable contains information about how fds should be bound
when a new process is spawned.

This variable should not be accessed directly.  You should add
bindings with `bind-fd' and query bindings with `get-fd'. See also
`squash-fd-bindings'.")

(defun bind-fd (fd description)
  "Extend `*fd-bindings*' to include a binding for `fd' to the thing
implied by `description'.

Note: `description' is interpreted by the `fd-from-description'
generic function.

This function doesn't actually modify the given fd in the current
process.  Instead, it will simply store information about what the
named fd should be bound to in spawned processes.  This may involve
allocating a new fd in this process."
  (let ((from-fd (fd-from-description description)))
    (push (cons fd from-fd) *fd-bindings*)))

(defun separator-par-p (separator)
  "Return non-nil iff the given separator non-terminal describes a
& (par) separator."
  (check-type separator separator)
  (with-slots (separator-op) separator
    (when (slot-boundp separator 'separator-op)
      (typep separator-op 'par))))

(define-condition invalid-fd (error)
  ((fd
    :type integer
    :initarg :fd
    :accessor invalid-fd-fd
    :initform (required)))
  (:report (lambda (c s) (format s "Redirect from invalid fd: ~A~%" (invalid-fd-fd c))))
  (:documentation
   "A condition that indicates that an invalid fd has been
requested.

This represents an error in the shell expression.

An fd is considered invalid if it hasn't been bound by the shell
expression."))

(defun get-fd (fd)
  "Return the fd (in this process) will be dup'd into to the given
fd (in a spawned subprocesses).

See `bind-fd'."
  (let ((binding (assoc fd *fd-bindings*)))
    (when binding
      (return-from get-fd fd)))
  (when (fd-managed-p fd)
    (error 'invalid-fd :fd fd))
  (handler-case (sb-posix:fcntl fd sb-posix:f-getfd)
    (sb-posix:syscall-error ()
      (error 'invalid-fd :fd fd)))
  fd)

(defgeneric handle-redirect (redirect &optional fd-override)
  (:documentation
   "Bind fds (as necessary) to actualize the redirect requested."))

(defmethod handle-redirect ((r io-redirect) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (assert (slot-boundp r 'io-number))

  (labels
      ((to-int (io-number)
         (parse-integer (token-value io-number))))
    (with-slots (io-number io-file io-here) r
      (cond
        ((slot-boundp r 'io-here)
         (error 'not-implemented :message "Here-documents are not implemented"))

        ((slot-boundp r 'io-file)
         (handle-redirect io-file (to-int io-number)))

        (t
         (error "Impossible"))))))

(defmethod handle-redirect ((r io-file) &optional fd-override)
  (labels
      ((to-int (filename)
         (let* ((fd-string (token-value filename)))
           (parse-integer fd-string)))
       (fd (default) (or fd-override default)))
    (with-slots (redirect filename) r
      (etypecase redirect
        (less
         (bind-fd (fd 0) r))

        (lessand
         (bind-fd (fd 0) (get-fd (to-int filename))))

        (great
         (bind-fd (fd 1) r))

        (greatand
         (bind-fd (fd 1) (get-fd (to-int filename))))

        (dgreat
         (bind-fd (fd 1) r))

        (lessgreat
         (bind-fd (fd 0) r))

        (clobber
         (bind-fd (fd 1) r))))))

(defmethod handle-redirect ((r io-here) &optional fd-override)
  (declare (ignore fd-override))
  (error 'not-implemented :message "Here-documents are not implemented"))

(defmethod handle-redirect ((r redirect-list) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (with-slots (io-redirect redirect-list-tail) r
    (handle-redirect io-redirect)
    (when redirect-list-tail
      (handle-redirect redirect-list-tail))))

(defmethod handle-redirect ((r redirect-list-tail) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (with-slots (io-redirect redirect-list-tail) r
    (handle-redirect io-redirect)
    (when redirect-list-tail
      (handle-redirect redirect-list-tail))))

(defun squash-fd-bindings (&optional (fd-bindings *fd-bindings*))
  (let ((fd-table (make-hash-table))
        (already-set (make-hash-table))
        (reversed-bindings (reverse fd-bindings))
        squashed)
    (dolist (pair reversed-bindings)
      (destructuring-bind (target-fd . value-fd) pair
        (setf (gethash target-fd fd-table) (gethash value-fd fd-table value-fd))))

    (dolist (pair reversed-bindings)
      (destructuring-bind (target-fd . value-fd) pair
        (declare (ignore value-fd))
        (unless (gethash target-fd already-set)
          (push (cons target-fd (gethash target-fd fd-table)) squashed)
          (setf (gethash target-fd already-set) t))))
    (debug-log 'status "Squashed ~A => ~A" fd-bindings squashed)
    squashed))

(defun evaluate-background-job (sy)
  (declare (ignore sy))
  (error 'not-implemented :message "Background jobs aren't implemented")
  (truthy-exit-status))

(defun evaluate-synchronous-job (sy)
  (evaluate sy))

(defparameter *special-variables-to-preserve-during-async*
  '(*environment*))

(defun evaluate-async-job (sy completion-handler)
  (let* ((symbols *special-variables-to-preserve-during-async*)
         (symbol-values (mapcar #'symbol-value symbols))
         (fd-bindings (squash-fd-bindings))
         (fds-to-retain (delete-duplicates (mapcar #'cdr fd-bindings))))
    (labels
        ((async-eval ()
           (progv symbols symbol-values
             (with-fd-scope ()
               (setf *fd-bindings* fd-bindings)
               (dolist (fd fds-to-retain)
                 (fd-autorelease fd))

               (let* ((result (evaluate sy)))
                 (funcall completion-handler result))))
           (debug-log 'status "Thread exit ~A" sy)))
      (dolist (fd fds-to-retain)
        (fd-retain fd))
      (make-thread #'async-eval))))

(defun exit-true-p (exit-thing)
  (zerop exit-thing))

(defun exit-false-p (exit-thing)
  (not (exit-true-p exit-thing)))

(defun invert-exit-status (exit-thing)
  (if (exit-true-p exit-thing)
      1
      0))

(defun truthy-exit-status ()
  0)

(defun exit-status (&key pid exit-code exit-signal stop-signal)
  (declare (ignore pid))
  (+ (if exit-code exit-code 0) (if exit-signal 128 0) (if stop-signal 128 0)))

(defgeneric evaluate (syntax-tree))

(defmethod evaluate (sy)
  (error 'not-implemented :message (format nil "Cannot eval ~A" (class-name (class-of sy)))))

(defmethod evaluate ((sy complete-command))
  (with-slots (newline-list complete-command) sy
    (if (slot-boundp sy 'complete-command)
        (return-from evaluate (evaluate-synchronous-job complete-command))
        (return-from evaluate (truthy-exit-status)))))

(defun evaluate-command-list (sy)
  (with-slots (and-or separator-op command-list-tail) sy
    (let ((no-wait (typep separator-op 'par)))

      (unless command-list-tail
        (if no-wait
            (return-from evaluate-command-list (evaluate-background-job and-or))
            (return-from evaluate-command-list (evaluate-synchronous-job and-or))))

      (if no-wait
          (evaluate-background-job sy)
          (evaluate-synchronous-job and-or))

      (return-from evaluate-command-list (evaluate-synchronous-job command-list-tail)))))

(defmethod evaluate ((sy command-list))
  (evaluate-command-list sy))
(defmethod evaluate ((sy command-list-tail))
  (evaluate-command-list sy))

(defun evaluate-and-or (sy)
  (with-slots (pipeline and-or-tail) sy
    (unless and-or-tail
      (return-from evaluate-and-or (evaluate-synchronous-job pipeline)))

    (let ((result (evaluate-synchronous-job pipeline)))
      (declare (ignore result))
      (error 'not-implemented :message "&& and || are not implemented"))))

(defmethod evaluate ((sy and-or))
  (evaluate-and-or sy))
(defmethod evaluate ((sy and-or-tail))
  (evaluate-and-or sy))

(defmethod evaluate ((sy pipeline))
  (with-slots (bang pipe-sequence) sy
    (let ((result (evaluate-synchronous-job pipe-sequence)))
      (return-from evaluate (invert-exit-status result)))))

(defconstant +pipe-read-fd+ 0)
(defconstant +pipe-write-fd+ 1)

(defun evaluate-pipe-sequence (sy)
  (let ((vector (make-extensible-vector))
        (results (make-extensible-vector))
        (semaphore (make-semaphore))
        write-fd)
    (labels
        ((visit (thing)
           (with-slots (command pipe-sequence-tail) thing
             (vector-push-extend command vector)
             (vector-push-extend nil results)
             (when pipe-sequence-tail
               (visit pipe-sequence-tail))))
         (store (index thing)
           (setf (aref results index) thing)
           (semaphore-signal semaphore))
         (run-command (index read-end write-end)
           (with-fd-scope ()
             (when read-end
               (bind-fd +pipe-read-fd+ read-end))
             (when write-end
               (bind-fd +pipe-write-fd+ write-end))
             (evaluate-async-job (aref vector index)
                                 (lambda (result) (store index result))))))
      (visit sy)
      (assert (< 1 (length vector)))
      (loop :for index :from (- (length vector) 1) :downto 1 :do
         (multiple-value-bind (read-end write-end) (pipe-retained)
           (run-command index read-end write-fd)
           (when write-fd
             (fd-release write-fd))
           (setf write-fd write-end)
           (fd-release read-end)))
      (assert write-fd)
      (run-command 0 nil write-fd)
      (fd-release write-fd)
      (loop :for n :below (length vector) :do
         (semaphore-wait semaphore))
      (return-from evaluate-pipe-sequence (aref results (- (length results) 1))))))

(defmethod evaluate ((sy pipe-sequence))
  (with-slots (command pipe-sequence-tail) sy
    (unless pipe-sequence-tail
      (return-from evaluate (evaluate-synchronous-job command)))

    (return-from evaluate (evaluate-pipe-sequence sy))))

(defmethod evaluate ((sy command))
  (with-slots (compound-command redirect-list) sy
    (with-fd-scope ()
      (handle-redirect redirect-list)
      (return-from evaluate (evaluate-synchronous-job compound-command)))))

(defmethod evaluate ((sy subshell))
  (declare (ignore sy))
  (error 'not-implemented :message "Subshells not implemented"))

(defmethod evaluate ((sy compound-list))
  (with-slots (newline-list term) sy
    (return-from evaluate (evaluate-synchronous-job term))))

(defun evaluate-term (sy)
  (with-slots (and-or separator term-tail) sy
    (when (separator-par-p separator)
      (evaluate-background-job and-or))

    (if term-tail
        (return-from evaluate-term (evaluate-synchronous-job term-tail))
        (return-from evaluate-term (truthy-exit-status)))))

(defmethod evaluate ((sy term))
  (evaluate-term sy))
(defmethod evaluate ((sy term-tail))
  (evaluate-term sy))

(defun cmd-prefix-parts (prefix)
  (with-slots (io-redirect assignment-word cmd-prefix-tail) prefix
    (multiple-value-bind (assignments redirects)
        (when cmd-prefix-tail
          (cmd-prefix-parts cmd-prefix-tail))

      (when (slot-boundp prefix 'io-redirect)
        (push io-redirect redirects))

      (when (slot-boundp prefix 'assignment-word)
        (push assignment-word assignments))

      (values assignments redirects))))

(defun cmd-suffix-parts (suffix)
  (with-slots (io-redirect a-word cmd-suffix-tail) suffix
    (multiple-value-bind (arguments redirects)
        (when cmd-suffix-tail
          (cmd-suffix-parts cmd-suffix-tail))

      (when (slot-boundp suffix 'io-redirect)
        (push io-redirect redirects))

      (when (slot-boundp suffix 'a-word)
        (push a-word arguments))

      (values arguments redirects))))

(defun simple-command-parts (sy)
  (let (assignments
        arguments
        redirects)
    (with-slots (cmd-prefix cmd-word cmd-name cmd-suffix) sy
      (when (slot-boundp sy 'cmd-prefix)
        (multiple-value-bind (prefix-assignments prefix-redirects) (cmd-prefix-parts cmd-prefix)
          (dolist (a prefix-assignments)
            (push a assignments))
          (dolist (r prefix-redirects)
            (push r redirects))))

      (when (slot-boundp sy 'cmd-name)
        (push cmd-name arguments))

      (when (slot-boundp sy 'cmd-word)
        (push cmd-word arguments))

      (when (slot-boundp sy 'cmd-suffix)
        (multiple-value-bind (suffix-arguments suffix-redirects) (cmd-suffix-parts cmd-suffix)
          (dolist (a suffix-arguments)
            (push a arguments))
          (dolist (r suffix-redirects)
            (push r redirects))))

      (values (nreverse assignments) (nreverse arguments) (nreverse redirects)))))

(defun evaluate-assignment-word (assignment-word)
  (with-accessors ((value assignment-word-value-word) (name assignment-word-name)) assignment-word
    (let ((expanded (expansion-for-word
                     value
                     :expand-aliases nil
                     :expand-pathname nil
                     :split-fields nil)))
      (setf (env (simple-word-text name)) expanded))))

(defun evaluate-command-free (assignments redirects)
  (dolist (assign assignments)
    (evaluate-assignment-word assign))
  (with-fd-scope ()
    (dolist (redirect redirects)
      (handle-redirect redirect)))
  (truthy-exit-status))

(defmethod evaluate ((sy simple-command))
  (with-slots (cmd-prefix cmd-word cmd-name cmd-suffix) sy
    (multiple-value-bind (assignments arguments redirects) (simple-command-parts sy)
      (debug-log 'status "EXEC: ~A ~A ~A~%" assignments arguments redirects)
      (when (zerop (length arguments))
        (return-from evaluate (evaluate-command-free assignments redirects)))

      (with-environment-scope ()
        (dolist (assign assignments)
          (evaluate-assignment-word assign))
        (setf arguments (expansion-for-words arguments :expand-aliases t :expand-pathname t))
        (with-fd-scope ()
          (dolist (r redirects)
            (handle-redirect r))
          (let* ((bindings (squash-fd-bindings))
                 pid
                 status)
            (when-let ((builtin (lookup-builtin (fset:first arguments))))
              (return-from evaluate
                (exit-status :exit-code (funcall builtin arguments))))

            (with-living-fds (fds)
              (setf pid (run arguments
                             :fd-alist (reverse bindings)
                             :managed-fds fds
                             :environment (linearized-exported-environment)))
              (debug-log 'status "PID ~A = ~A" pid arguments))
            (setf status (nth-value 1 (sb-posix:waitpid pid sb-posix:wuntraced)))
            (debug-log 'status "EXITED ~A" pid)
            (when (sb-posix:wifstopped status)
              (warn "Stopped jobs should get a job number, but they don't"))

            (exit-status :pid pid
                         :exit-code (when (sb-posix:wifexited status)
                                      (sb-posix:wexitstatus status))
                         :exit-signal (when (sb-posix:wifsignaled status)
                                        (sb-posix:wtermsig status))
                         :stop-signal (when (sb-posix:wifstopped status)
                                        (sb-posix:wstopsig status)))))))))

(define-condition not-an-exit-code (warning)
  ((actual-type
    :initarg :actual-type
    :accessor not-an-exit-code-actual-type
    :initform (required)
    :type symbol)
   (eval-target
    :initarg :eval-target
    :accessor not-an-exit-code-eval-target
    :initform (required)))
  (:report (lambda (c s) (format s "~A is not an exit code.  Given ~A~%"
                                 (not-an-exit-code-actual-type c) (not-an-exit-code-eval-target c)))))

(defmethod evaluate :around (sy)
  (let ((result (call-next-method)))
    (unless (typep result 'integer)
      (warn 'not-an-exit-code :actual-type (class-name (class-of result)) :eval-target sy))
    result))

(defmethod evaluate ((s string))
  (do-iterator (command (command-iterator (token-iterator (make-string-input-stream s))))
    (evaluate command)))
