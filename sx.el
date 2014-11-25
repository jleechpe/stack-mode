;;; sx.el --- Core functions of the sx package.      -*- lexical-binding: t; -*-

;; Copyright (C) 2014  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; URL: https://github.com/vermiculus/stack-mode/
;; Version: 0.1
;; Keywords: help, hypermedia, tools
;; Package-Requires: ((emacs "24.1") (cl-lib "0.5") (json "1.3") (markdown-mode "2.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file defines basic commands used by all other parts of
;; StackMode.

;;; Code:
(require 'tabulated-list)

(defconst sx-version "0.1" "Version of the `sx' package.")


;;; User commands
(defun sx-version ()
  "Print and return the version of the `sx' package."
  (interactive)
  (message "%s: %s" 'sx-version sx-version)
  sx-version)

;;;###autoload
(defun sx-bug-report ()
  "File a bug report about the `sx' package."
  (interactive)
  (browse-url "https://github.com/vermiculus/stack-mode/issues/new"))


;;; Browsing filter
(defvar sx-browse-filter
  '((question.body_markdown
     question.comments
     question.answers
     question.last_editor
     question.accepted_answer_id
     question.link
     question.upvoted
     question.downvoted
     user.display_name
     comment.owner
     comment.body_markdown
     comment.body
     comment.link
     comment.edited
     comment.creation_date
     comment.upvoted
     comment.score
     answer.last_editor
     answer.link
     answer.owner
     answer.body_markdown
     answer.upvoted
     answer.downvoted
     answer.comments)
    (user.profile_image shallow_user.profile_image))
  "The filter applied when retrieving question data.
See `sx-question-get-questions' and `sx-question-get-question'.")


;;; Utility Functions

(defmacro sx-sorted-insert-skip-first (newelt list &optional predicate)
  "Inserted NEWELT into LIST sorted by PREDICATE.
This is designed for the (site id id ...) lists.  So the first car
is intentionally skipped."
  `(let ((tail ,list)
         (x ,newelt))
     (while (and ;; We're not at the end.
             (cdr-safe tail)
             ;; We're not at the right place.
             (,(or predicate #'<) x (cadr tail)))
       (setq tail (cdr tail)))
     (setcdr tail (cons x (cdr tail)))))

(defun sx-message (format-string &rest args)
  "Display FORMAT-STRING as a message with ARGS.
See `format'."
  (message "[stack] %s" (apply #'format format-string args)))

(defun sx-message-help-echo ()
  "If there's a 'help-echo property under point, message it."
  (let ((echo (get-text-property (point) 'help-echo)))
    (when echo (message "%s" echo))))

(defun sx--thing-as-string (thing &optional sequence-sep)
  "Return a string representation of THING.
If THING is already a string, just return it.

Optional argument SEQUENCE-SEP is the separator applied between
elements of a sequence."
  (cond
   ((stringp thing) thing)
   ((symbolp thing) (symbol-name thing))
   ((numberp thing) (number-to-string thing))
   ((sequencep thing)
    (mapconcat #'sx--thing-as-string
               thing (if sequence-sep sequence-sep ";")))))

(defun sx--filter-data (data desired-tree)
  "Filter DATA and return the DESIRED-TREE.

For example:

  (sx--filter-data
    '((prop1 . value1)
      (prop2 . value2)
      (prop3
       (test1 . 1)
       (test2 . 2))
      (prop4 . t))
    '(prop1 (prop3 test2)))

would yield

  ((prop1 . value1)
   (prop3
    (test2 . 2)))"
  (if (vectorp data)
      (apply #'vector
             (mapcar (lambda (entry)
                       (sx--filter-data
                        entry desired-tree))
                     data))
    (delq
     nil
     (mapcar (lambda (cons-cell)
               ;; @TODO the resolution of `f' is O(2n) in the worst
               ;; case.  It may be faster to implement the same
               ;; functionality as a `while' loop to stop looking the
               ;; list once it has found a match.  Do speed tests.
               ;; See edfab4443ec3d376c31a38bef12d305838d3fa2e.
               (let ((f (or (memq (car cons-cell) desired-tree)
                            (assoc (car cons-cell) desired-tree))))
                 (when f
                   (if (and (sequencep (cdr cons-cell))
                            (sequencep (elt (cdr cons-cell) 0)))
                       (cons (car cons-cell)
                             (sx--filter-data
                              (cdr cons-cell) (cdr f)))
                     cons-cell))))
             data))))


;;; Printing request data
(defvar sx--overlays nil
  "Overlays created by sx on this buffer.")
(make-variable-buffer-local 'sx--overlays)

(defmacro sx--wrap-in-overlay (properties &rest body)
  "Start a scope with overlay PROPERTIES and execute BODY.
Overlay is pushed on the buffer-local variable `sx--overlays' and
given PROPERTIES.

Return the result of BODY."
  (declare (indent 1)
           (debug t))
  `(let ((p (point-marker))
         (result (progn ,@body)))
     (let ((ov (make-overlay p (point)))
           (props ,properties))
       (while props
         (overlay-put ov (pop props) (pop props)))
       (push ov sx--overlays))
     result))

(defmacro sx--wrap-in-text-property (properties &rest body)
  "Start a scope with PROPERTIES and execute BODY.
Return the result of BODY."
  (declare (indent 1)
           (debug t))
  `(let ((p (point-marker))
         (result (progn ,@body)))
     (add-text-properties p (point) ,properties)
     result))


;;; Using data in buffer
(defun sx--data-here ()
  "Get the text property `sx--data-here'."
  (or (get-text-property (point) 'sx--data-here)
      (and (derived-mode-p 'sx-question-list-mode)
           (tabulated-list-get-id))))

(defun sx--maybe-update-display ()
  "Refresh the question list if we're inside it."
  (cond
   ((derived-mode-p 'sx-question-list-mode)
    (sx-question-list-refresh 'redisplay 'no-update))
   ((derived-mode-p 'sx-question-mode)
    (sx-question-list-refresh 'redisplay 'no-update))))

(defun sx--copy-data (from to)
  "Copy all fields of alist FORM onto TO.
Only fields contained in TO are copied."
  (setcar to (car from))
  (setcdr to (cdr from)))

(defun sx-visit (data)
  "Visit DATA in a web browser.
DATA can be a question, answer, or comment. Interactively, it is
derived from point position.
If DATA is a question, also mark it as read."
  (interactive (list (sx--data-here)))
  (sx-assoc-let data
    (when (stringp .link)
      (browse-url .link))
    (when (and .title (fboundp 'sx-question--mark-read))
      (sx-question--mark-read data)
      (sx--maybe-update-display))))

(defun sx-toggle-upvote (data)
  "Apply or remove upvote from DATA.
DATA can be a question, answer, or comment. Interactively, it is
guessed from context at point."
  (interactive (list (sx--data-here)))
  (let ((result
         (sx-assoc-let data
           (sx-set-vote data "upvote" (null (eq .upvoted t))))))
    (when (> (length result) 0)
      (sx--copy-data (elt result 0) data)))
  (sx--maybe-update-display))

(defun sx-toggle-downvote (data)
  "Apply or remove downvote from DATA.
DATA can be a question or an answer. Interactively, it is guessed
from context at point."
  (interactive (list (sx--data-here)))
  (let ((result
         (sx-assoc-let data
           (sx-set-vote data "downvote" (null (eq .downvoted t))))))
    (when (> (length result) 0)
      (sx--copy-data (elt result 0) data)))
  (sx--maybe-update-display))

(defun sx-set-vote (data type status)
  "Set the DATA's vote TYPE to STATUS.
DATA can be a question, answer, or comment.
TYPE can be \"upvote\" or \"downvote\".
Status is a boolean."
  (sx-assoc-let data
    (sx-method-call
        (cond
         (.comment_id "comments")
         (.answer_id "answers")
         (.question_id "questions"))
      :id (or .comment_id .answer_id .question_id)
      :submethod (concat type (unless status "/undo"))
      :auth 'warn
      :url-method "POST"
      :filter sx-browse-filter
      :site .site)))


;;; Assoc-let
(defun sx--site (data)
  "Get the site in which DATA belongs.
DATA can be a question, answer, comment, or user (or any object
with a `link' property).
DATA can also be the link itself."
  (let ((link (if (stringp data) data
                (cdr (assoc 'link data)))))
    (unless (stringp link)
      (error "Data has no link property"))
    (replace-regexp-in-string
     "^https?://\\(?:\\(?1:[^/]+\\)\\.stackexchange\\|\\(?2:[^/]+\\)\\)\\.[^.]+/.*$"
     "\\1\\2" link)))

(defun sx--deep-dot-search (data)
  "Find symbols somewhere inside DATA which start with a `.'.
Returns a list where each element is a cons cell.  The car is the
symbol, the cdr is the symbol without the `.'."
  (cond
   ((symbolp data)
    (let ((name (symbol-name data)))
      (when (string-match "\\`\\." name)
        ;; Return the cons cell inside a list, so it can be appended
        ;; with other results in the clause below.
        (list (cons data (intern (replace-match "" nil nil name)))))))
   ((not (listp data)) nil)
   (t (apply
       #'append
       (remove nil (mapcar #'sx--deep-dot-search data))))))

(defmacro sx-assoc-let (alist &rest body)
  "Use dotted symbols let-bound to their values in ALIST and execute BODY.
Dotted symbol is any symbol starting with a `.'.  Only those
present in BODY are letbound, which leads to optimal performance.
The .site symbol is special, it is derived from the .link symbol
using `sx--site'.

For instance, the following code

  (sx-assoc-let alist
    (list .title .body))

is equivalent to

  (let ((.title (cdr (assoc 'title alist)))
        (.body (cdr (assoc 'body alist))))
    (list .title .body))"
  (declare (indent 1) (debug t))
  (let* ((symbol-alist (sx--deep-dot-search body))
         (has-site (assoc '.site symbol-alist)))
    `(let ,(append
            (when has-site `((.site (sx--site (cdr (assoc 'link ,alist))))))
            (mapcar (lambda (x) `(,(car x) (cdr (assoc ',(cdr x) ,alist))))
                    (remove '(.site . site) (delete-dups symbol-alist))))
       ,@body)))

(defcustom sx-init-hook nil
  "Hook run when stack-mode initializes.
Run after `sx-init--internal-hook'."
  :group 'sx
  :type 'hook)

(defvar sx-init--internal-hook nil
  "Hook run when stack-mode initializes.
This is used internally to set initial values for variables such
as filters.")

(defun sx--< (property x y &optional predicate)
  "Non-nil if PROPERTY attribute of alist X is less than that of Y.
With optional argument PREDICATE, use it instead of `<'."
  (funcall (or predicate #'<)
           (cdr (assoc property x))
           (cdr (assoc property y))))

(defmacro sx-init-variable (variable value &optional setter)
  "Set VARIABLE to VALUE using SETTER.
SETTER should be a function of two arguments.  If SETTER is nil,
`set' is used."
  (eval
   `(add-hook
     'sx-init--internal-hook
     (lambda ()
       (,(or setter #'setq) ,variable ,value))))
  nil)

(defvar sx-initialized nil
  "Nil if sx hasn't been initialized yet.
If it has, holds the time at which initialization happened.")

(defun sx-initialize (&optional force)
  "Run initialization hooks if they haven't been run yet.
These are `sx-init--internal-hook' and `sx-init-hook'.

If FORCE is non-nil, run them even if they've already been run."
  (when (or force (not sx-initialized))
    (prog1
        (run-hooks 'sx-init--internal-hook
                   'sx-init-hook)
      (setq sx-initialized (current-time)))))

(provide 'sx)
;;; sx.el ends here

;; Local Variables:
;; indent-tabs-mode: nil
;; End:
