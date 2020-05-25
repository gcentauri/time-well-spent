;;; -*- lexical-binding: t; -*-

(require 'notifications)

;;; Entry Data Structure and Accessors
(defun tws-make-entry (goal category &optional estimate)
  (list 'goal goal
        'category category
        'time 0                   ; in seconds
        'estimate (or estimate 0) ; in hours
        'completed nil            ; t or nil or 
        'created nil              ; a time like (curren-time)
        'last-touched nil         ; nil or a time like (current-time)
        'status 'in-the-future    ; 'in-the-future, 'on-the-move or 'waiting
        'id nil
        'log nil))

(defun tws-accessor-forms (prop)
  (let ((fname (intern (concat "tws-" (symbol-name prop)))))
    (list 'progn
          `(defun ,fname (entry) (getf entry ',prop))
          `(gv-define-setter ,fname (val entry)
             (list 'setf (list 'getf entry '',prop) val)))))

(defmacro def-tws-accessors (&rest props)
  (cons 'progn (mapcar #'tws-accessor-forms props)))

(def-tws-accessors goal category time estimate completed created last-touched status id log)

(defun tws-waiting-on (entry reason)
  (setf (tws-status entry) 'waiting))

(defun tws-mark-incomplete (entry)
  (setf (tws-completed entry) nil))

(defun tws-mark-complete (entry)
  (setf (tws-completed entry) t))

(defun tws-make-on-the-move (entry)
  (setf (tws-status entry) 'on-the-move))

(defun tws-make-in-the-future (entry)
  (setf (tws-status entry) 'in-the-future))

(defun tws-touch-entry (entry)
  (setf (tws-last-touched entry) (current-time)))

(defun tws-add-time (entry secs)
  (setf (tws-time entry)
        (+ (tws-time entry)
           secs)))

(defvar *tws-on-the-move-str* "🚀")
(defvar *tws-in-the-future-str* "🤔")
(defvar *tws-waiting-str* "⏳")
(defvar *tws-in-progress-icon* "🚧")
(defvar *tws-goal-reached-icon* "☑")

(defvar *tws-entry-format-string* "%35s -- %-25s (≅ %-4s Hrs) %s %s %s" 
  "Shoots for 90 Charcters wide. Its format is
   GOAL CATEGORY ESTIMATE STATUS SPENT COMPLETE

  COMPLETE is either ✓ or 🚧 or is blank.
  STATUS is one of 🚀, 🤔, ⏳
  SPENT is HH:MM
")



(defun tws-status-icon (entry)
  (case (tws-status entry)
    ('on-the-move *tws-on-the-move-str*)
    ('in-the-future *tws-in-the-future-str*)
    ('waiting *tws-waiting-str*)))


(defun tws-time-to-hh-mm (secs)
  (format "%02d:%02d"
          (/ secs 3600)
          (/ (mod secs 3600) 60)))

(defun tws-entry-to-string (entry &optional working-p)
  (format *tws-entry-format-string*
          (truncate-string-to-width (tws-goal entry) 35)
          (truncate-string-to-width (tws-category entry) 25)
          (truncate  (tws-estimate entry))
          (tws-status-icon entry)
          (tws-time-to-hh-mm (tws-time entry))
          (if working-p *tws-in-progress-icon*
            (if (tws-completed entry)  *tws-goal-reached-icon* " "))))

;;; Utilities
(defun tws-print-to-file (file form)
  (with-temp-buffer
    (prin1 form (current-buffer))
    (write-file file)))

(defun tws-read-from-file (file)
  (car (read-from-string
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string)))))

;;; Database Abstraction
(defun tws-make-fresh-db ()
  "Creates a fresh database instance."
  (list
   0       ; the next entry id
   ()      ; the entries
   nil     ; the working entry, nil or (start-time . entry-id) 
   ))

(defun tws-new-entry-id (db)
  "Returns a new entry ID, updates the internal database state."
  (incf (first db)))

(defun tws-db-entries (db)
  "Returns the database entries as a list."
  (second db))

(defun tws-db-working-entry (db)
  "Returns the database's working entry form"
  (third db))

(defun tws-currently-working-on-p (db entry-id)
  (and entry-id
       (eql entry-id
            (cdr (tws-db-working-entry db)))))

(defun tws-lookup-entry (db entry-id)
  (find-if (tws-query 'eql 'tws-id entry-id)
           (tws-db-entries db)))

(defun tws-stop-working (db)
  "Clears the working entry and updates the database with the
corresponding entry's new time."
  (when (tws-db-working-entry db)
    (let* ((entry-id (cdr (tws-db-working-entry db)))
           (start-time (float-time (car (tws-db-working-entry db))))
           (entry (tws-lookup-entry db entry-id))
           (now (float-time (current-time))))
      ;; clear the working-entry
      (setf (third db) nil)
      ;; update the entry with new times
      (tws-add-time entry (- now start-time))
      (tws-touch-entry entry))))

(defun tws-work-on (db entry)
  "Start working on entry with id ENTRY-ID."
  ;; stop any active work
  (tws-stop-working db)
  ;; add the new working entry and record its time
  (tws-make-on-the-move entry)
  (tws-mark-incomplete entry)
  (tws-touch-entry entry)
  (setf (third db) (cons (current-time) (tws-id entry))))

(defun tws-raw-insert-entry-into-db (entry db)
  "Performs no checks. Includes a entry into the DB. Meant to be
used by other functions that don't know about the internal
structure of the DB."
  (push entry (second db)))

(defun tws-delete-entry (id db)
  "Removes the entry with the provided Id from the database."
  (setf (second db)
        (delete-if (lambda (entry) (equal id (tws-id entry)))
                   (second db))))

(defun tws-run-query (pred db)
  (remove-if-not pred (tws-db-entries db)))

(defun tws-categories (db)
  (let ((result nil))
    (dolist (entry (tws-db-entries db) result)
      (pushnew (tws-category entry) result :test #'equal))))

;;; Utilities for building queries

(defun tws-query (compare accessor value)
  (lambda (entry) (funcall compare (funcall accessor entry) value)))

(defun tws-and (&rest preds)
  (lambda (entry)
    (labels ((rec (preds)
                  (if (not preds) t
                    (and (funcall (car preds) entry)
                         (rec (cdr preds))))))
      (rec preds))))

(defun tws-days-ago (days)
  (- (float-time (curren-time))
     (* days 24 60 60)))

(defun tws-not (pred)
  (lambda (entry) (not (funcall pred entry))))

;;; Functions for Interacting with The Global Database 
(defvar *tws-db-file* "~/.time-well-spent"
  "The file where the database will persist between emacs
  sessions.")

(defvar *tws-db* nil
  "Holds a entry database instance.")

(defun tws-init-fresh-db ()
  (setq *tws-db* (tws-make-fresh-db)))

(defun tws-save-db ()
  (tws-print-to-file *tws-db-file* *tws-db*))

(defun tws-load-db ()
  (setq *tws-db*
        (if (file-exists-p *tws-db-file*) (tws-read-from-file *tws-db-file*)
          (tws-make-fresh-db))))

(defun tws-add-entry (entry)
  ;; if the entry has an id, remove any entrys in the db with the same
  ;; id, otherwise give the entry an id.
  (if (tws-id entry)
      (tws-delete-entry (tws-id entry) *tws-db*)
      (setf (tws-id entry) (tws-new-entry-id *tws-db*)))
  ;; then push it to into the db
  (tws-raw-insert-entry-into-db entry *tws-db*))


;;; Timers 

(defvar *tws-idle-timeout* (* 5 60))
(defvar *tws-idle-timer-handle* nil)

(defun tws-stop-idle-timer ()
  (when *tws-idle-timer-handle*
    (cancel-timer *tws-idle-timer-handle*)
    (setq *tws-idle-timer-handle* nil)))

(defun tws-start-idle-timer ()
  (setq *tws-idle-timer-handle*
        (run-with-idle-timer *tws-idle-timeout*
                             nil
                             'tws-notify-and-stop)))

(defun tws-notify-and-stop ()
  (tws-stop-working *tws-db*)
  (tws-save-db)
  (tws-stop-idle-timer)
  (notifications-notify :title "Time Well Spent"
                        :body "Tracking Has Stopped Due to Idleness"
                        :timeout 0)
  (tws-refresh-buffer))

;;; TWS Buffer & Commands

(defvar *tws-buffer-name* "*Time Well Spent*")

(defvar *tws-displayed-entries* nil
  "List of entries currently being displayed.")

(defvar *tws-show-complete-also* nil)
(defvar *tws-show-future* t)
(defvar *tws-show-category* nil)



;(defun tws-true (entry) t)

(defun tws-build-filter ()
  (let ((filter (lambda (entry) t)))
    (when *tws-show-category*
      (setq filter (tws-and filter (tws-query 'equal 'tws-category *tws-show-category*))))
    (unless *tws-show-future*
      (setq filter (tws-and filter (tws-not (tws-query 'equal 'tws-status 'in-the-future)))))
    (unless *tws-show-complete-also*
      (setq filter (tws-and filter (tws-query 'eql 'tws-completed nil))))
    filter))

(defun tws-entry-compare (e1 e2)
  (let ((touched1 (tws-last-touched e1))
        (touched2 (tws-last-touched e2)))
    (cond ((and touched1 touched2)
           (> touched1 touched2))
          (e1 t)
          (e2 nil)
          (t nil))))

(defun tws-sort (entries)
  "Sorts entries in 'barski' order"
  (setq entries (sort entries 'tws-entry-compare))
  entries)

(defun tws-toggle-future-goals ()
  (interactive)
  (setq *tws-show-future* (not *tws-show-future*))
  (tws-refresh-buffer))

(defun tws-toggle-completed-goals ()
  (interactive)
  (setq *tws-show-complete-also* (not *tws-show-complete-also*))
  (tws-refresh-buffer))

(defun tws-show-all-goals ()
  (interactive)
  (setq *tws-show-complete-also* t)
  (setq *tws-show-future* t)
  (setq *tws-show-category* nil)
  (tws-refresh-buffer))

(defun tws-show-default ()
  (interactive)
  (setq *tws-show-category* nil)
  (setq *tws-show-future* t)
  (setq *tws-show-complete-also* nil)
  (tws-refresh-buffer))

(define-derived-mode time-well-spent-mode fundamental-mode "tws")

(defvar *tws-last-known-point* 0)

(defun tws-refresh-buffer ()
  (interactive)
  (setq *tws-last-known-point* (point))
  (setq *tws-displayed-entries*
        (tws-sort (copy-sequence (tws-run-query (tws-build-filter) *tws-db*))))
  (with-output-to-temp-buffer *tws-buffer-name*
    (with-current-buffer *tws-buffer-name*
      (time-well-spent-mode)
      (hl-line-mode)
      (dolist (entry *tws-displayed-entries*)
        (princ (tws-entry-to-string entry
                                    (tws-currently-working-on-p
                                     *tws-db*
                                     (tws-id entry))))
        (terpri))

      (read-only-mode)
      (use-local-map (copy-keymap (make-sparse-keymap)))
      (local-set-key (kbd "+") 'tws-create-entry)
      (local-set-key (kbd "<return>") 'tws-toggle-on-goal-at-line)
      (local-set-key (kbd "S") 'tws-stop)
      (local-set-key (kbd "A") 'tws-show-all-goals)
      (local-set-key (kbd "SPC") 'tws-show-goals-with-category-on-line)
      (local-set-key (kbd "C") 'tws-toggle-completed-goals)
      (local-set-key (kbd "F") 'tws-toggle-future-goals)
      (local-set-key (kbd "D") 'tws-show-default)
      (local-set-key (kbd "m") 'tws-toggle-mark-complete-on-line)
      (local-set-key (kbd "f") 'tws-put-into-future-on-line)
      (local-set-key (kbd "w") 'tws-mark-waiting-on-line)
      (local-set-key (kbd "d") 'tws-mark-on-the-move-on-line)
      (switch-to-buffer *tws-buffer-name*)))
  (goto-char *tws-last-known-point*))

(defun tws-mark-waiting-on-line ()
  (interactive)
  (let ((entry (tws-entry-on-line)))
    (when entry
      (tws-mark-incomplete entry)
      (tws-waiting-on entry "ignore")
      (tws-refresh-buffer))))

(defun tws-mark-on-the-move-on-line ()
  (interactive)
  (let ((entry (tws-entry-on-line)))
    (when entry
      (tws-mark-incomplete entry)
      (tws-make-on-the-move entry)
      (tws-refresh-buffer))))

(defun tws-put-into-future-on-line ()
  (interactive)
  (let ((entry (tws-entry-on-line)))
    (when entry
      (tws-make-in-the-future entry)
      (tws-mark-incomplete entry)
      (tws-refresh-buffer))))

(defun tws-toggle-mark-complete-on-line ()
  (interactive)
  (let ((entry (tws-entry-on-line)))
    (when entry
      (setf (tws-completed entry)
            (not (tws-completed entry)))
      (if (tws-completed entry)
          (tws-make-on-the-move entry))
      (tws-refresh-buffer))))

(defun tws-line-number-to-index (n)
  "Translates a line number from the TWS Buffer to an index into
the *tws-displayed-entries* list."
  (1- n))

(defun tws-entry-on-line ()
  (let ((n (tws-line-number-to-index (line-number-at-pos (point)))))
    (when (< -1 n (length *tws-displayed-entries*))
      (elt *tws-displayed-entries* n))))

(defun tws-show-goals-with-category-on-line ()
  (interactive)
  (let ((entry (tws-entry-on-line)))
    (when entry
      ;; if already showing a category, then clear it, otherwise show a category
      (setq *tws-show-category* (if *tws-show-category* nil (tws-category entry)))
      (tws-refresh-buffer))))

(defun tws-create-entry (category goal estimated)
  (interactive
   (list (completing-read "Category: " (cons "No Category" (tws-categories *tws-db*)))
         (read-string "Goal: ")
         (read-number "Estimated Hours: ")))
  (let ((entry (tws-make-entry goal category estimated)))
    (setf (tws-created entry) (current-time))
    (tws-add-entry entry)
    (tws-refresh-buffer)))

(defun tws-stop ()
  (interactive)
  (tws-stop-idle-timer)
  (tws-stop-working *tws-db*)
  (tws-save-db))

(defun tws-toggle-on-goal-at-line ()
  (interactive)
  (let ((entry-on-line (tws-entry-on-line)))
    (when entry-on-line
      (if (tws-currently-working-on-p *tws-db* (tws-id entry-on-line))
          (tws-stop)
        (progn
          (tws-stop)
          (tws-work-on *tws-db* entry-on-line)
          (tws-start-idle-timer)))
      (tws-refresh-buffer))))


(defun time-well-spent ()
  (interactive)
  (unless *tws-db*
    (tws-load-db))
  (tws-refresh-buffer))








