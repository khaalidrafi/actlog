;;; actlog.el --- Activity tracking with Org integration -*- lexical-binding: t; -*-

;; Author: z.ai-agent <noreply@z.ai>
;; Maintainer: Khalid Rafi <khaalidrafi@gmail.com>
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: org, convenience, tools
;; URL: https://github.com/khaalidrafi/actlog

;;; Commentary:

;; StayFree, rebuilt inside Emacs: `actlog-mode' watches which buffer is
;; front, credits the elapsed wall time to that activity, and writes the
;; result as plain Org clock data you own.
;;
;; An "activity" is the Emacs-side equivalent of StayFree's per-app row:
;;
;;   - a file inside a project  ->  the project name    ("telega-org")
;;   - a file with no project   ->  "Files:<directory>" ("Files:downloads")
;;   - a special buffer         ->  "Emacs:<mode-name>" ("Emacs:Telega")
;;
;; Everything lands in one Org file per day under `actlog-org-dir'
;; (default: org-directory/actlog/): one entry per activity, one CLOCK
;; line per work session.  Because the journal is ordinary Org clock
;; data, `org-clock-report', the agenda and `org-clock-sum' all work on
;; it without this package being loaded.
;;
;; Commands:
;;   M-x actlog-mode          turn tracking on/off (global minor mode)
;;   M-x actlog-report        today's per-activity table (or any day)
;;   M-x actlog-open-journal  open the day's Org file
;;   M-x actlog-toggle        quick pause/resume
;;
;; Android notes (org.gnu.emacs / Termux, Emacs 30):
;;   - The sampler is a 15 s timer and the journal flusher a 5 min
;;     timer; both are trivial battery-wise.
;;   - When Android freezes or kills the process the sampler stops
;;     ticking.  A gap larger than `actlog-max-gap' (default 15 min)
;;     is treated as suspension and never credited, so you do not get
;;     phantom hours after the phone sat in your pocket.
;;   - Idleness (no input for `actlog-idle-threshold') stops crediting
;;     too, the same way StayFree stops when the screen is off.
;;   - State survives restarts via `actlog-state-file'; a flush every
;;     `actlog-flush-interval' bounds what a hard kill can lose.
;;
;; Scope, honestly: Android sandboxes apps away from each other, so
;; Emacs cannot read UsageStatsManager -- device-wide per-app usage
;; like StayFree's is not reachable from Elisp.  This package replaces
;; the part of StayFree you can actually live in Emacs: where your
;; Emacs hours go.  Everything stays on the device.

;;; Code:

(require 'cl-lib)

(declare-function project-current "project" (&optional maybe-prompt dir))
(declare-function project-root "project" (project))

(defgroup actlog nil
  "Activity tracking with Org integration."
  :prefix "actlog-"
  :group 'org
  :link '(url-link :tag "Repository" "https://github.com/khaalidrafi/actlog"))

(defcustom actlog-interval 15
  "Seconds between activity samples."
  :type 'integer
  :group 'actlog)

(defcustom actlog-flush-interval 300
  "Seconds between journal flushes.
Each flush closes the running session (writing its CLOCK line) and
opens a fresh one, so a hard process kill can lose at most this many
seconds of journal.  Totals are updated continuously regardless."
  :type 'integer
  :group 'actlog)

(defcustom actlog-idle-threshold 180
  "Seconds of input idleness after which time stops accruing."
  :type 'integer
  :group 'actlog)

(defcustom actlog-max-gap 900
  "Largest sample gap, in seconds, that still counts as usage.
A gap bigger than this means the process was suspended or restarted
(common on Android) and the gap is discarded, not credited."
  :type 'integer
  :group 'actlog)

(defcustom actlog-org-dir nil
  "Directory holding the daily journal files, or nil to derive it.
When nil, the journal lives under `org-directory' (or \"~/org\")
in an \"actlog/\" subdirectory."
  :type '(choice directory (const nil))
  :group 'actlog)

(defcustom actlog-state-file nil
  "File keeping the tracking state across restarts, or nil to derive it.
When nil, \"actlog-state.el\" inside `user-emacs-directory'."
  :type '(choice file (const nil))
  :group 'actlog)

(defcustom actlog-ignore-buffer-regexps
  '("^ " "^\\*Completions\\*$" "^\\*Messages\\*$" "^\\*Warnings\\*$"
    "^\\*Compile-Log\\*$" "^\\*vc\\*$")
  "Buffers whose names match any regexp are never tracked."
  :type '(repeat regexp)
  :group 'actlog)

(defcustom actlog-lighter " Actlog"
  "Mode-line lighter for `actlog-mode'."
  :type 'string
  :group 'actlog)

;; ------------------------------------------------------------------------
;; Internal state (all plain, printable values -- the state file is
;; just `prin1' of a plist).
;; ------------------------------------------------------------------------

(defvar actlog--day nil
  "Day being tracked, \"YYYY-MM-DD\".")

(defvar actlog--totals nil
  "Alist (ACTIVITY-KEY . SECONDS) for `actlog--day'.")

(defvar actlog--current-key nil
  "Activity of the running session, or nil when none is open.")

(defvar actlog--current-mode nil
  "Major mode name of the running session.")

(defvar actlog--since nil
  "Float epoch seconds when the running session started.")

(defvar actlog--session-secs 0
  "Live seconds accrued by the running session, not yet closed.
Totals are only credited when a session closes, so this keeps the
mode line live without double-crediting the open window.")

(defvar actlog--last-sample nil
  "Float epoch seconds of the previous sample.")

(defvar actlog--sampler-timer nil)
(defvar actlog--flusher-timer nil)

(defvar actlog--mode-line nil
  "Dynamic mode-line string showing the running activity and total.")

;; ------------------------------------------------------------------------
;; Paths and formatting
;; ------------------------------------------------------------------------

(defun actlog-journal-dir ()
  "Return the journal directory."
  (directory-file-name
   (expand-file-name
    "actlog"
    (or actlog-org-dir
        (expand-file-name
         "org" (or (bound-and-true-p org-directory) "~/org"))))))

(defun actlog-journal-file (&optional day)
  "Return the journal file for DAY (default today)."
  (expand-file-name
   (concat (or day (actlog-day-string)) ".org")
   (concat (actlog-journal-dir) "/")))

(defun actlog-day-string (&optional time)
  "Return \"YYYY-MM-DD\" for TIME (default now)."
  (format-time-string "%Y-%m-%d" (or time (current-time))))

(defun actlog--fmt-dur (secs)
  "Format SECS as an Org clock duration \"H:MM\" (floor to minutes)."
  (let ((mins (floor (max 0 secs) 60)))
    (format "%d:%02d" (/ mins 60) (% mins 60))))

(defun actlog--ts (secs)
  "Format float epoch SECS as an inactive Org timestamp."
  (format-time-string "[%Y-%m-%d %a %H:%M]" (seconds-to-time secs)))

(defun actlog--clock-line (start end)
  "Return one Org CLOCK line for the window START..END (epoch floats)."
  (format "CLOCK: %s--%s =>  %s\n" (actlog--ts start) (actlog--ts end)
          (actlog--fmt-dur (- end start))))

;; ------------------------------------------------------------------------
;; Activity identification
;; ------------------------------------------------------------------------

(defun actlog--mode-name (buffer)
  "Return a display name for BUFFER's major mode."
  (let ((name (buffer-local-value 'mode-name buffer)))
    (format "%s" (if (consp name) (car name) name))))

(defun actlog--activity-key ()
  "Identify the current activity as (KEY . MODE), or nil when untracked.
KEY is the StayFree-style row (project, Files:dir or Emacs:mode),
MODE the major mode display name."
  (let ((buffer (window-buffer (selected-window))))
    (when (and buffer (not (active-minibuffer-window)))
      (let ((name (buffer-name buffer)))
        (unless (seq-some
                 (lambda (re) (string-match-p re name))
                 actlog-ignore-buffer-regexps)
          (let* ((file (buffer-local-value 'buffer-file-name buffer))
                 (mode (actlog--mode-name buffer)))
            (cond
             ((and file (file-exists-p file))
              (let* ((dir (file-name-directory file))
                     (proj (and (fboundp 'project-current)
                                (ignore-errors
                                  (project-current nil dir))))
                     (root (and proj (fboundp 'project-root)
                                (ignore-errors (project-root proj)))))
                (cons (cond
                       (root (file-name-nondirectory
                              (directory-file-name
                               (expand-file-name root))))
                       (dir (concat "Files:"
                                    (file-name-nondirectory
                                     (directory-file-name dir))))
                       (t "Files:?"))
                      mode)))
             (t (cons (concat "Emacs:" mode) mode)))))))))

;; ------------------------------------------------------------------------
;; Accounting
;; ------------------------------------------------------------------------

(defun actlog--add-total (key secs)
  "Add SECS to KEY's total for the tracked day."
  (when (> secs 0)
    (cl-incf (alist-get key actlog--totals 0 nil #'equal) secs)))

(defun actlog--close-session (key mode start end &optional day)
  "Credit the session KEY/MODE from START to END (epoch floats).
The window is written as a CLOCK line into DAY's journal file
(default: the day END falls on)."
  (when (and key (> end start))
    (actlog--add-total key (- end start))
    (let ((jday (or day (actlog-day-string (seconds-to-time end)))))
      (condition-case err
          (actlog--journal-clock jday key mode start end)
        (error (message "actlog: journal write failed: %s" err))))))

(defun actlog--day-start (day)
  "Return epoch float for local midnight of DAY (\"YYYY-MM-DD\")."
  (time-to-seconds (date-to-time (concat day " 00:00"))))

(defun actlog--close-live (end)
  "Close the running session, crediting its live seconds, ending at END.
The journaled window is exactly the live accrual (never more than the
session could honestly claim), so idle stretches inside it shrink it.
Resets the live accumulator; the session itself stays open (same key)
until the caller decides otherwise."
  (when (and actlog--current-key actlog--since
             (> actlog--session-secs 0))
    (let* ((end (max end actlog--since))
           (secs (min actlog--session-secs (- end actlog--since))))
      (when (> secs 0)
        (actlog--close-session actlog--current-key actlog--current-mode
                               (- end secs) end))))
  (setq actlog--session-secs 0))

(defun actlog--rotate-day-if-needed (now)
  "If NOW (epoch float) left `actlog--day', roll the books over.
The open session's pre-midnight seconds stay in the old day's file,
then the session continues in the new day."
  (let ((today (actlog-day-string (seconds-to-time now))))
    (unless (equal today actlog--day)
      (when (and actlog--current-key actlog--since)
        (let ((midnight (actlog--day-start today)))
          (when (> midnight actlog--since)
            (let ((secs (min actlog--session-secs
                             (- midnight actlog--since))))
              (when (> secs 0)
                (actlog--close-session actlog--current-key
                                       actlog--current-mode
                                       (- midnight secs) midnight
                                       actlog--day))))))
      (setq actlog--day today
            actlog--totals nil
            actlog--session-secs 0
            actlog--since now))))

(defun actlog--account (key mode now idle-secs)
  "Credit one sample: activity KEY/MODE at NOW (epoch float) with
IDLE-SECS of input idleness.  All bookkeeping paths funnel here.
Totals are credited only when sessions close, never per tick."
  (setq key (or key "Emacs:unknown") mode (or mode "unknown"))
  (let ((delta (if actlog--last-sample (- now actlog--last-sample) 0))
        (old-last actlog--last-sample))
    (setq actlog--last-sample now)
    (actlog--rotate-day-if-needed now)
    (cond
     ;; Process suspended or restarted: never credit the gap itself,
     ;; but do close what the pre-gap session honestly earned.
     ((> delta actlog-max-gap)
      (actlog--close-live old-last)
      (setq actlog--current-key key actlog--current-mode mode
            actlog--since now))
     ;; Same activity, user active: live accrual (credited at close).
     ((and (equal key actlog--current-key)
           (< idle-secs actlog-idle-threshold))
      (setq actlog--session-secs (+ actlog--session-secs delta)))
     ;; Activity switch or idleness: close the old window (an idle
     ;; stretch only counts up to where idleness began), open a new one.
     (t
      (actlog--close-live
       (if (>= idle-secs actlog-idle-threshold) (- now idle-secs) now))
      (setq actlog--current-key key actlog--current-mode mode
            actlog--since now)))))

(defun actlog--tick ()
  "One sampler pass."
  (let* ((now (time-to-seconds))
         (idle (if-let* ((it (current-idle-time))) (float-time it) 0))
         (am (actlog--activity-key)))
    (when am
      (actlog--account (car am) (cdr am) now idle)
      (actlog--update-mode-line))))

(defun actlog--flush ()
  "Close the running session into the journal and reopen it.
Bounds the loss a hard process kill can cause; also saves state."
  (when (and actlog--current-key actlog--since)
    (actlog--close-live (time-to-seconds))
    (setq actlog--since (time-to-seconds)))
  (actlog--save-state)
  (actlog--update-mode-line))

;; ------------------------------------------------------------------------
;; Org journal
;; ------------------------------------------------------------------------

(defun actlog--day-heading (day)
  "Return the level-1 heading text for DAY."
  (format "* %s %s" day
          (format-time-string "%a" (date-to-time (concat day " 12:00")))))

(defun actlog--ensure-day-heading (day)
  "In the current journal buffer, make sure DAY's heading exists.
Return the position right after the heading line (the section start)."
  (goto-char (point-min))
  (if (re-search-forward
       (concat "^" (regexp-quote (actlog--day-heading day)) "$") nil t)
      (line-end-position)
    (goto-char (point-max))
    (unless (eq (point-min) (point-max)) (insert "\n"))
    (insert (actlog--day-heading day) "\n")
    (point)))

(defun actlog--append-clock (day key mode start end)
  "In the current journal buffer, record one CLOCK session of KEY
and MODE (START..END epoch floats) under DAY's section.  The line
goes into the \"** KEY\" entry, creating the entry (with a :MODE:
property and a :LOGBOOK: drawer) on the first session of the day."
  (let* ((sec-beg (actlog--ensure-day-heading day))
         (sec-end (save-excursion
                    (goto-char sec-beg)
                    (if (re-search-forward "^\\* " nil t)
                        (match-beginning 0)
                      (point-max))))
         (headline (concat "^\\*\\* " (regexp-quote key) "$")))
    (goto-char sec-beg)
    (if (re-search-forward headline sec-end t)
        ;; Existing entry: insert just before its LOGBOOK's :END:.
        (let ((entry-beg (match-beginning 0))
              (entry-end (progn
                           (forward-line 1)
                           (or (re-search-forward "^\\*\\* " sec-end t)
                               sec-end))))
          (goto-char entry-beg)
          (if (re-search-forward "^:LOGBOOK:\n" entry-end t)
              (progn
                (goto-char (or (re-search-forward "^:END:\n" entry-end t)
                               entry-end))
                (forward-line 0)
                (insert (actlog--clock-line start end)))
            ;; Hand-made entry without a drawer: give it one after the
            ;; entry body, never touching its :PROPERTIES: :END:.
            (goto-char entry-end)
            (insert ":LOGBOOK:\n" (actlog--clock-line start end)
                    ":END:\n")))
      ;; New entry for this activity, at the end of the day section.
      (goto-char sec-end)
      (insert "\n** " key "\n"
              ":PROPERTIES:\n:MODE: " mode "\n:END:\n"
              ":LOGBOOK:\n"
              (actlog--clock-line start end)
              ":END:\n"))))

(defun actlog--journal-clock (day key mode start end)
  "Write one CLOCK session (START..END) of KEY/MODE into DAY's file."
  (let* ((file (actlog-journal-file day))
         (make-backup-files nil)
         (create-lockfiles nil))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (actlog--append-clock day key mode start end)
      (save-buffer)
      (kill-buffer))))

;; ------------------------------------------------------------------------
;; Reading the journal back (reports work without this package running)
;; ------------------------------------------------------------------------

(defun actlog--parse-day (day)
  "Sum DAY's journal into an alist (ACTIVITY-KEY . SECONDS)."
  (let ((file (actlog-journal-file day))
        (totals nil)
        (key nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((looking-at "^\\*\\* \\(.*\\)$")
            (setq key (match-string 1)))
           ((and key
                 (looking-at
                  "^CLOCK: \\[[^]]*\\]--\\[[^]]*\\] => +\\([0-9]+\\):\\([0-9]+\\)$"))
            (let ((mins (+ (* 60 (string-to-number (match-string 1)))
                           (string-to-number (match-string 2)))))
              (cl-incf (alist-get key totals 0 nil #'equal)
                       (* mins 60)))))
          (forward-line 1))))
    totals))

(defun actlog-summary-table (totals)
  "Render TOTALS (alist key->seconds) as an Org table string."
  (let* ((rows (cl-sort
                (mapcar (lambda (kv)
                          (list (car kv) (actlog--fmt-dur (cdr kv))))
                        totals)
                #'string< :key #'car))
         (total (actlog--fmt-dur
                 (cl-reduce #'+ (mapcar #'cdr totals)
                            :initial-value 0))))
    (concat "| Activity | Time |\n"
            "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
            (mapconcat (lambda (row)
                         (format "| %s | %s |\n" (car row) (cadr row)))
                       rows)
            "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
            (format "| Total | %s |\n" total))))

(defun actlog--today-total ()
  "Seconds tracked so far today (closed totals + the live session)."
  (+ (cl-reduce #'+ (mapcar #'cdr actlog--totals) :initial-value 0)
     actlog--session-secs))

(defun actlog--update-mode-line ()
  "Refresh the dynamic mode-line element."
  (setq actlog--mode-line
        (if actlog--current-key
            (format " A:%s %s" actlog--current-key
                    (actlog--fmt-dur (actlog--today-total)))
          " A:-")))

;; ------------------------------------------------------------------------
;; State persistence (Android kills processes without warning)
;; ------------------------------------------------------------------------

(defun actlog--save-state ()
  "Write the tracking state to `actlog-state-file'."
  (when actlog-state-file
    (condition-case err
        (let ((make-backup-files nil) (create-lockfiles nil))
          (make-directory
           (file-name-directory (expand-file-name actlog-state-file)) t)
          (with-temp-file actlog-state-file
            (prin1 `(actlog-state :version 1
                                  :day ,actlog--day
                                  :totals ,actlog--totals
                                  :key ,actlog--current-key
                                  :mode ,actlog--current-mode
                                  :since ,actlog--since
                                  :session-secs ,actlog--session-secs)
                   (current-buffer))))
      (error (message "actlog: state save failed: %s" err)))))

(defun actlog--load-state ()
  "Restore tracking state from `actlog-state-file'.
Tolerates corruption (a broken file means a fresh day, never an
error) and drops state belonging to another day -- that day's
journal already holds its time."
  (when (and actlog-state-file (file-exists-p actlog-state-file))
    (condition-case _
        (let* ((state (with-temp-buffer
                        (insert-file-contents actlog-state-file)
                        (read (current-buffer))))
               (plist (when (and (listp state)
                                 (eq (car state) 'actlog-state))
                        (cdr state))))
          (when (equal (plist-get plist :day) (actlog-day-string))
            (setq actlog--day (plist-get plist :day)
                  actlog--totals (copy-alist (plist-get plist :totals))
                  actlog--current-key (plist-get plist :key)
                  actlog--current-mode (plist-get plist :mode)
                  actlog--since (plist-get plist :since)
                  actlog--session-secs (or (plist-get plist :session-secs) 0)
                  actlog--last-sample nil)
            t))
      (error (message "actlog: unreadable state file, starting fresh")
             nil))))

;; ------------------------------------------------------------------------
;; Mode and commands
;; ------------------------------------------------------------------------

(defun actlog--start ()
  "Start timers, hooks and state for `actlog-mode'."
  (unless actlog-state-file
    (setq actlog-state-file
          (expand-file-name "actlog-state.el" user-emacs-directory)))
  (actlog--load-state)
  (unless actlog--day
    (setq actlog--day (actlog-day-string)))
  (setq actlog--since (or actlog--since (time-to-seconds))
        actlog--last-sample nil
        actlog--sampler-timer (run-at-time 0 actlog-interval
                                           #'actlog--tick)
        actlog--flusher-timer (run-at-time actlog-flush-interval
                                           actlog-flush-interval
                                           #'actlog--flush))
  (add-hook 'kill-emacs-hook #'actlog--shutdown)
  (add-to-list 'global-mode-string 'actlog--mode-line 'append)
  (actlog--update-mode-line))

(defun actlog--stop ()
  "Stop everything `actlog--start' set up, flushing first."
  (actlog--flush)
  (dolist (timer (list actlog--sampler-timer actlog--flusher-timer))
    (when timer (cancel-timer timer)))
  (setq actlog--sampler-timer nil actlog--flusher-timer nil)
  (remove-hook 'kill-emacs-hook #'actlog--shutdown)
  (setq global-mode-string (delq 'actlog--mode-line global-mode-string))
  (actlog--save-state))

(defun actlog--shutdown ()
  "Kill-emacs hook: close the open session and persist."
  (actlog--flush)
  (actlog--save-state))

;;;###autoload
(define-minor-mode actlog-mode
  "Track Emacs activity into an Org journal (StayFree, in Emacs)."
  :global t
  :lighter actlog-lighter
  :group 'actlog
  (if actlog-mode (actlog--start) (actlog--stop)))

;;;###autoload
(defun actlog-report (&optional day)
  "Show a per-activity time table for DAY (default today) in Org."
  (interactive)
  (require 'org nil t)
  (let* ((day (or day (actlog-day-string)))
         (totals (actlog--parse-day day))
         (buffer (get-buffer-create "*Actlog Report*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'org-mode) (org-mode) (fundamental-mode))
        (insert "#+title: Actlog " day "\n\n")
        (insert (if totals
                    (actlog-summary-table totals)
                  "Nothing tracked yet.\n"))
        (goto-char (point-min)))
      (display-buffer buffer))
    buffer))

;;;###autoload
(defun actlog-open-journal (&optional day)
  "Open DAY's (default today) journal file."
  (interactive)
  (find-file (actlog-journal-file day)))

;;;###autoload
(defun actlog-toggle ()
  "Pause or resume tracking."
  (interactive)
  (actlog-mode (if actlog-mode -1 1))
  (message "actlog: %s" (if actlog-mode "resumed" "paused")))

(provide 'actlog)
;;; actlog.el ends here
