(defpackage :shcl-test/iterator
  (:use :common-lisp :prove :shcl/core/iterator)
  (:import-from :shcl/core/utility #:optimization-settings))
(in-package :shcl-test/iterator)

(optimization-settings)

(plan 2)

(deftest iterator-tests
  (let* ((vector #(1 2 3 4 5))
         (list '(a b c d e))
         (seq (fset:seq 'q 'w 'e 'r))
         (vector-iterator (vector-iterator vector))
         (list-iterator (list-iterator list))
         (generic-iterator (iterator seq)))
    (is (coerce (iterator-values vector-iterator) 'list)
        (coerce vector 'list)
        :test #'equal)
    (is (coerce (iterator-values list-iterator) 'list)
        list
        :test #'equal)
    (is (coerce (iterator-values generic-iterator) 'list)
        (fset:convert 'list seq)
        :test #'equal)))

(deftest lookahead-iterator-tests
  (let* ((count 5)
         (iter (make-iterator (:type 'lookahead-iterator)
                 (when (equal 0 count)
                   (stop))
                 (decf count)))
         fork)
    (is 5 count :test #'equal)
    (is 4 (peek-lookahead-iterator iter) :test #'equal)
    (is 4 count :test #'equal)
    (setf fork (fork-lookahead-iterator iter))
    (is 4 (peek-lookahead-iterator fork) :test #'equal)
    (is 4 (peek-lookahead-iterator iter) :test #'equal)
    (is 4 count :test #'equal)
    (is 4 (next iter) :test #'equal)
    (is 3 (next iter) :test #'equal)
    (is 2 (next iter) :test #'equal)
    (is 2 count :test #'equal)
    (is 4 (peek-lookahead-iterator fork) :test #'equal)
    (is 2 count :test #'equal)
    (is 4 (next fork) :test #'equal)
    (is 3 (next fork) :test #'equal)
    (is 2 count :test #'equal)
    (is 1 (next iter) :test #'equal)
    (is 1 count :test #'equal)
    (move-lookahead-to fork iter)
    (is 0 (next iter) :test #'equal)
    (is 0 count :test #'equal)
    (is nil (next iter) :test #'equal)
    (is 0 count :test #'equal)
    (is 0 (next fork) :test #'equal)
    (is 0 count :test #'equal)
    (is nil (next fork) :test #'equal)
    (is 0 count :test #'equal)))
