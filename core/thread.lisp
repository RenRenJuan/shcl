;; Copyright 2017 Bradley Jensen
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

(defpackage :shcl/core/thread
  (:use :common-lisp :shcl/core/utility :bordeaux-threads)
  (:export
   ;; Queues
   #:queue #:make-queue #:enqueue #:dequeue #:dequeue-no-block #:queue-p))
(in-package :shcl/core/thread)

(optimization-settings)

(defstruct (queue
             (:constructor %make-queue))
  "This struct is a standard queue data structure."
  front
  back
  (lock (make-lock))
  (cv (make-condition-variable)))

(defun make-queue ()
  "Create a new queue."
  (%make-queue))

(defun enqueue (item queue)
  "Add an item to the given queue."
  (with-accessors
        ((front queue-front) (back queue-back)
         (lock queue-lock) (cv queue-cv))
      queue
    (with-lock-held (lock)
      (cond
        ((null front)
         (setf front (cons item nil)
               back front))

        (t
         (setf (cdr back) (cons item nil)
               back (cdr back))))
      (condition-notify cv)
      nil)))

(defun %dequeue (queue &key (wait t))
  "The brains of `dequeue' and `dequeue-no-block'."
  (with-accessors
        ((front queue-front) (back queue-back)
         (lock queue-lock) (cv queue-cv))
      queue
    (with-lock-held (lock)
      (when (and (not wait) (null front))
        (return-from %dequeue (values nil nil)))
      (loop :while (null front) :do (condition-wait cv lock))
      (let ((item (car front)))
        (if (eq front back)
            (setf front nil
                  back nil)
            (setf front (cdr front)))
        (values item t)))))

(defun dequeue (queue)
  "Return and remove the item at the front of the queue.

This function will block if there are no items in the queue.  See
`dequeue-no-block'."
  (nth-value 0 (%dequeue queue)))

(defun dequeue-no-block (queue &optional default)
  "Return and remove the item at the front of the queue.

This function will return immediately if there aren't any items in the
queue."
  (multiple-value-bind (value valid) (%dequeue queue :wait nil)
    (if valid
        value
        default)))
