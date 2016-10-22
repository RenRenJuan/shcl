(defpackage :shcl/debug
  (:use :common-lisp :shcl/utility)
  (:import-from :closer-mop)
  (:import-from :fset)
  (:export #:graph-class-hierarchy))
(in-package :shcl/debug)

(optimization-settings)

(defun all-subclasses (class)
  (let ((result (fset:empty-set)))
    (dolist (subclass (closer-mop:class-direct-subclasses class))
      (fset:adjoinf result subclass)
      (fset:unionf result (all-subclasses subclass)))
    result))

(defgeneric graph-class-hierarchy (class stream))
(defmethod graph-class-hierarchy ((name symbol) stream)
  (graph-class-hierarchy (find-class name) stream))
(defmethod graph-class-hierarchy ((class standard-class) stream)
  (format stream "digraph G {~%")
  (let ((classes (fset:with (all-subclasses class) class)))
    (fset:do-set (the-class classes)
      (format stream "\"~A\" [color=gray]~%" (class-name the-class))
      (dolist (superclass (closer-mop:class-direct-superclasses the-class))
        (format stream "\"~A\" -> \"~A\"~%" (class-name the-class) (class-name superclass)))))
  (format stream "}~%"))
