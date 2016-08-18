(in-package :shcl-test.lexer)
(in-suite lexer)

(defun lexes-to-token-types (string &rest tokens)
  (let ((real-tokens (tokenize string)))
    (unless (equal (length real-tokens) (length tokens))
      (return-from lexes-to-token-types nil))
    (loop :for token :across real-tokens
     :for class :in tokens :do
     (unless (typep token class)
       (return-from lexes-to-token-types nil))))
  t)

(def-test basics (:compile-at :definition-time)
  (is (lexes-to-token-types "foobar" 'simple-word))
  (is (lexes-to-token-types "foo$(bar)" 'compound-word))
  (is (lexes-to-token-types "FOO=bar" 'assignment-word))
  (is (lexes-to-token-types "FOO=\"asdf\"qwer$(pwd)" 'assignment-word))
  (is (lexes-to-token-types "valid_name43aNd_more" 'name))
  (is (lexes-to-token-types "3>" 'io-number 'great))
  (is (lexes-to-token-types "3 >" 'simple-word 'great))
  (is (lexes-to-token-types ">>" 'dgreat))
  (is (lexes-to-token-types "&&" 'and-if))
  (is (lexes-to-token-types "&&" 'literal-token))
  (is (lexes-to-token-types (string #\linefeed) 'newline))
  (is (lexes-to-token-types "if" 'reserved-word))
  (is (lexes-to-token-types "if" 'if-word))
  (is (lexes-to-token-types "'single quote'" 'single-quote))
  (is (lexes-to-token-types "\\q" 'single-quote))
  (is (lexes-to-token-types "\"double quotes $variable  escaped quote \\\"  end\"" 'double-quote))
  (is (lexes-to-token-types "$(sub command word $variable)" 'command-word))
  (is (lexes-to-token-types "$variable" 'variable-expansion-word))
  (is (lexes-to-token-types "$1" 'variable-expansion-word))
  (is (lexes-to-token-types "some words # and the rest" 'simple-word 'simple-word)))

(def-test word-boundaries (:compile-at :definition-time)
  (is (lexes-to-token-types (format nil "spaces    seperate  ~C   words  " #\tab) 'simple-word 'simple-word 'simple-word))
  (is (lexes-to-token-types ">new-word" 'great 'simple-word))
  (is (lexes-to-token-types "word>" 'simple-word 'great))
  (is (lexes-to-token-types (format nil "first~%second") 'simple-word 'newline 'simple-word))
  (is (lexes-to-token-types (format nil "part\\~%part") 'simple-word)))

(def-test basics-failing (:compile-at :definition-time :suite lexer-failing)
  (is (lexes-to-token-types "`sub command`" 'command-word)))

(defclass form-token (token)
  ((form
   :initarg :form
   :reader form-token-form)))

(defun make-form (value)
  (make-instance 'form-token :form value))

(def-test extensible-reading (:compile-at :definition-time)
  (let* ((*shell-readtable* *shell-readtable*)
         (stream (make-string-input-stream "[(+ 1 2 3)#,\"asdf\"#.stuff"))
         s-reader-ran)
    (reset-shell-readtable)
    (labels
        (([-reader (s i c)
           (declare (ignore i c))
           (make-form (read s)))
         (comma-reader (s i c)
           (declare (ignore i c))
           (make-form (read s)))
         (default-dot-reader (s i c)
           (declare (ignore s i c))
           (make-form 'stuff))
         (default-s-reader (s i c)
           (declare (ignore s i c))
           (setf s-reader-ran t)
           "s"))
      ;; Simple reader
      (set-character-handler #\[ #'[-reader)
      (is (equal
           '(+ 1 2 3)
           (form-token-form (shell-extensible-read stream))))

      ;; Dispatch reader
      (make-shell-dispatch-character #\# :default-handler (constantly t))
      (set-shell-dispatch-character #\# #\, #'comma-reader)
      ;; two-character sequence
      (is (equal
           "asdf"
           (form-token-form (shell-extensible-read stream))))

      ;; Dispatch char fallback (and commenting)
      (is (equal
           t
           (shell-extensible-read stream)))

      ;; Ultimate fallback (No matches at all)
      (is (equal
           nil
           (shell-extensible-read stream)))

      (is (equal (read-char stream nil :eof) #\.))

      ;; Dispatch char fallback (normal case)
      (make-shell-dispatch-character #\s :default-handler #'default-s-reader)
      (is (equal
           "s"
           (shell-extensible-read stream)))
      (is (eq
           t
           s-reader-ran)))))
