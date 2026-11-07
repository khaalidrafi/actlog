;;; test.el --- ERT suite for actlog -*- lexical-binding: t; -*-

;; TZ is pinned so day boundaries and CLOCK timestamps are deterministic.

(require 'ert)
(set-time-zone-rule "UTC")

(unless (bound-and-true-p actlog--loaded)
  (load (expand-file-name "actlog.el" (file-name-directory load-file-name)))
  (setq actlog--loaded t))

(require 'org)
(require 'org-clock)

(defvar actlog-test--dirs nil
  "Temp directories made by the suite, cleaned in `actlog-test--clean'.")

(defun actlog-test--clean ()
  (dolist (d actlog-test--dirs)
    (ignore-errors (delete-directory d 'recursive)))
  (setq actlog-test--dirs nil))

(defun actlog-test--temp (name)
  (let* ((parent (make-temp-file "actlog-test-" 'directory))
         (dir (expand-file-name name parent)))
    (push parent actlog-test--dirs)
    (make-directory dir t)
    dir))

(defmacro actlog-test--env (&rest body)
  "Run BODY with a hermetic actlog: temp journal + state, fresh books."
  `(let* ((dir (actlog-test--temp "env"))
          (actlog-org-dir (expand-file-name "j" dir))
          (actlog-state-file (expand-file-name "state.el" dir))
          (actlog--day nil)
          (actlog--totals nil)
          (actlog--current-key nil)
          (actlog--current-mode nil)
          (actlog--since nil)
          (actlog--session-secs 0)
          (actlog--last-sample nil))
     (unwind-protect
         (progn ,@body)
       (actlog-test--clean))))

(defun actlog-test--secs (sec min hour day month year)
  "Epoch float for the given UTC wall time."
  (time-to-seconds
   (encode-time sec min hour day month year 0)))

(defun actlog-test--show (buf)
  "Return BUF's contents as a string."
  (with-current-buffer buf (buffer-string)))

;;; ---------------------------------------------------------------------
;;; Activity identification
;;; ---------------------------------------------------------------------

(ert-deftest actlog-key-project-file ()
  (actlog-test--env
   (let* ((proj (actlog-test--temp "projX"))
          (gitdir (expand-file-name ".git" proj)))
     (make-directory gitdir t)
     (with-temp-file (expand-file-name "a.el" proj) (insert "x"))
     (let ((buf (find-file-noselect (expand-file-name "a.el" proj))))
       (set-window-buffer (selected-window) buf)
       (let ((am (actlog--activity-key)))
         (should (equal (car am) "projX"))
         ;; MODE is the display name (mode-name), not the symbol.
         ;; Emacs 30 renamed it to "ELisp".
         (should (equal (cdr am) "ELisp")))
       (set-window-buffer (selected-window)
                          (get-buffer-create "*scratch*"))
       (kill-buffer buf)))))

(ert-deftest actlog-key-no-project-falls-to-dir ()
  (actlog-test--env
   (let* ((plain (actlog-test--temp "downloads"))
          (file (expand-file-name "note.txt" plain)))
     (with-temp-file file (insert "hi"))
     (let ((buf (find-file-noselect file)))
       (set-window-buffer (selected-window) buf)
       ;; No .git anywhere above the temp tree -> project-current nil.
       (should (equal (car (actlog--activity-key)) "Files:downloads"))
       (kill-buffer buf)))))

(ert-deftest actlog-key-special-buffer-uses-mode ()
  (actlog-test--env
   (let ((buf (get-buffer-create "*actlog test special*")))
     (with-current-buffer buf (text-mode))
     (set-window-buffer (selected-window) buf)
     (should (equal (car (actlog--activity-key)) "Emacs:Text"))
     (kill-buffer buf))))

(ert-deftest actlog-key-ignored-buffers-skip ()
  (actlog-test--env
   (let ((buf (get-buffer-create "*Messages*")))
     (set-window-buffer (selected-window) buf)
     (should (null (actlog--activity-key)))
     ;; Restore the window to a plain buffer.  Never kill *Messages*:
     ;; batch ERT writes its own reporting through it, and killing it
     ;; makes ert-run-test die with a dead-marker error.
     (set-window-buffer (selected-window)
                        (get-buffer-create "*scratch*")))))

;;; ---------------------------------------------------------------------
;;; Accounting
;;; ---------------------------------------------------------------------

(ert-deftest actlog-account-accrues-live-only ()
  (actlog-test--env
   (actlog--account "k" "m" 1000.0 0)
   (should (equal actlog--current-key "k"))
   (should (= actlog--since 1000.0))
   (actlog--account "k" "m" 1060.0 0)
   ;; Totals stay empty while the session is open...
   (should (null actlog--totals))
   ;; ...and the live accumulator carries the time.
   (should (= actlog--session-secs 60.0))
   (should (= (actlog--today-total) 60.0))))

(ert-deftest actlog-account-switch-closes-previous ()
  (actlog-test--env
   (actlog--account "k" "m" 1000.0 0)
   (actlog--account "k" "m" 1060.0 0)
   (actlog--account "k2" "m2" 1120.0 0)
   ;; k closed with exactly its live 60 s, no double counting.
   (should (= (cdr (assoc "k" actlog--totals)) 60.0))
   (should (equal actlog--current-key "k2"))
   (should (= actlog--since 1120.0))
   (should (= actlog--session-secs 0.0))))

(ert-deftest actlog-account-idle-stops-crediting ()
  (actlog-test--env
   (actlog--account "k" "m" 1000.0 0)
   ;; Still active (under the threshold): grace accrues.
   (actlog--account "k" "m" 1060.0 0)
   (should (= actlog--session-secs 60.0))
   ;; Now a 200 s idle sample at 1300: credit ends where idleness
   ;; began (1100), and only the live 60 s are journaled.
   (actlog--account "k" "m" 1300.0 200.0)
   (should (= (cdr (assoc "k" actlog--totals)) 60.0))
   ;; The idle stretch opened no phantom session time.
   (should (= actlog--session-secs 0.0))
   (should (= actlog--since 1300.0))))

(ert-deftest actlog-account-max-gap-discards-suspension ()
  (actlog-test--env
   (actlog--account "k" "m" 1000.0 0)
   (actlog--account "k" "m" 1060.0 0)
   ;; A 1940 s gap: process was suspended.  Pre-gap work is closed at
   ;; the last sample, the gap itself is never credited.
   (actlog--account "k" "m" 3000.0 0)
   (should (= (cdr (assoc "k" actlog--totals)) 60.0))
   (should (= actlog--since 3000.0))
   (should (= actlog--session-secs 0.0))))

(ert-deftest actlog-account-day-rollover-splits-midnight ()
  (actlog-test--env
   (setq actlog--day "2026-11-06"
         actlog--current-key "k" actlog--current-mode "m"
         actlog--since (actlog-test--secs 50 59 23 6 11 2026)
         actlog--session-secs 600.0)
   (let* ((old-file (actlog-journal-file "2026-11-06"))
          (new-file (actlog-journal-file "2026-11-07")))
     (actlog--account "k" "m"
                      (actlog-test--secs 10 0 0 7 11 2026) 0)
     ;; Rolled over.
     (should (equal actlog--day "2026-11-07"))
     (should (null actlog--totals))
     ;; Pre-midnight live seconds (10 s worth before 00:00) landed in
     ;; the OLD day's file.
     (should (file-exists-p old-file))
     (should (string-match-p
              "^CLOCK: .+ =>  0:00$" (actlog-test--show
                                      (find-file-noselect old-file))))
     (should-not (file-exists-p new-file)))))

(ert-deftest actlog-flush-closes-and-reopens ()
  (actlog-test--env
   (setq actlog--current-key "k" actlog--current-mode "m"
         actlog--since (- (time-to-seconds) 120.0)
         actlog--session-secs 120.0)
   (let* ((day (actlog-day-string))
          (file (actlog-journal-file day)))
     (actlog--flush)
     (should (file-exists-p file))
     (should (= (cdr (assoc "k" actlog--totals)) 120.0))
     (should (= actlog--session-secs 0.0))
     ;; State persisted for crash recovery.
     (should (file-exists-p actlog-state-file)))))

;;; ---------------------------------------------------------------------
;;; Org journal
;;; ---------------------------------------------------------------------

(ert-deftest actlog-journal-creates-entry-with-clock ()
  (actlog-test--env
   (let* ((start (actlog-test--secs 0 20 11 7 11 2026))
          (end (+ start 300.0))
          (file (actlog-journal-file "2026-11-07")))
     (actlog--journal-clock "2026-11-07" "telega-org"
                            "emacs-lisp-mode" start end)
     (should (file-exists-p file))
     (let ((text (actlog-test--show (find-file-noselect file))))
       (should (string-match-p "^\\* 2026-11-07 Sat$" text))
       (should (string-match-p "^\\*\\* telega-org$" text))
       (should (string-match-p "^:MODE: emacs-lisp-mode$" text))
       (should (string-match-p
                "^CLOCK: \\[2026-11-07 Sat 11:20\\]--\\[2026-11-07 Sat 11:25\\] =>  0:05$"
                text))
       (kill-buffer (find-buffer-visiting file))))))

(ert-deftest actlog-journal-merges-sessions-into-one-entry ()
  (actlog-test--env
   (let* ((start (actlog-test--secs 0 20 11 7 11 2026))
          (file (progn
                  (actlog--journal-clock "2026-11-07" "k" "m"
                                         start (+ start 300.0))
                  (actlog--journal-clock "2026-11-07" "k" "m"
                                         (+ start 600.0) (+ start 900.0))
                  (actlog-journal-file "2026-11-07"))))
     (with-current-buffer (find-file-noselect file)
       ;; One entry, one drawer, two CLOCK sessions.
       (should (= (count-matches "^\\*\\* k$") 1))
       (should (= (count-matches "^:LOGBOOK:$") 1))
       (should (= (count-matches "^CLOCK: ") 2))
       (kill-buffer)))))

(ert-deftest actlog-parse-day-sums-clock-lines ()
  (actlog-test--env
   (let ((start (actlog-test--secs 0 20 11 7 11 2026)))
     (actlog--journal-clock "2026-11-07" "a" "m" start (+ start 3600.0))
     (actlog--journal-clock "2026-11-07" "a" "m"
                            (+ start 7200.0) (+ start 7260.0))
     (actlog--journal-clock "2026-11-07" "b" "m2"
                            (+ start 3600.0) (+ start 5400.0))
     (let ((totals (actlog--parse-day "2026-11-07")))
       (should (= (cdr (assoc "a" totals)) 3660.0))
       (should (= (cdr (assoc "b" totals)) 1800.0))))))

(ert-deftest actlog-journal-reads-as-real-org-clock-data ()
  (actlog-test--env
   (let* ((start (actlog-test--secs 0 20 11 7 11 2026))
          (file (progn
                  (actlog--journal-clock "2026-11-07" "a" "m"
                                         start (+ start 1500.0))
                  (actlog--journal-clock "2026-11-07" "b" "m"
                                         start (+ start 600.0))
                  (actlog-journal-file "2026-11-07")))
          (buf (find-file-noselect file)))
     (with-current-buffer buf
       (org-mode)
       (org-clock-sum)
       ;; 25 min + 10 min of real Org clock time, read back by Org
       ;; itself -- the "Org integration" law, checked from org's side.
       (should (= org-clock-file-total-minutes 35)))
     (kill-buffer buf))))

(ert-deftest actlog-summary-table-sorts-and-totals ()
  (actlog-test--env
   (let ((table (actlog-summary-table
                 '(("b" . 900.0) ("a" . 60.0)))))
     (should (string-match-p "^| Activity | Time |$" table))
     ;; Sorted by activity name, not insertion order.
     (should (< (string-match "^| a " table)
                (string-match "^| b " table)))
     (should (string-match-p "^| Total | 0:16 |$" table)))))

(ert-deftest actlog-fmt-dur-floors-to-minutes ()
  (should (equal (actlog--fmt-dur 59.0) "0:00"))
  (should (equal (actlog--fmt-dur 60.0) "0:01"))
  (should (equal (actlog--fmt-dur 3661.0) "1:01"))
  (should (equal (actlog--fmt-dur 0.0) "0:00")))

;;; ---------------------------------------------------------------------
;;; State persistence
;;; ---------------------------------------------------------------------

(ert-deftest actlog-state-round-trips ()
  (actlog-test--env
   (setq actlog--day (actlog-day-string)
         actlog--totals '(("k" . 125.0))
         actlog--current-key "k" actlog--current-mode "m"
         actlog--since 12345.0
         actlog--session-secs 45.0)
   (actlog--save-state)
   (setq actlog--day nil actlog--totals nil actlog--current-key nil
         actlog--current-mode nil actlog--since nil
         actlog--session-secs 0)
   (should (actlog--load-state))
   (should (equal actlog--totals '(("k" . 125.0))))
   (should (equal actlog--current-key "k"))
   (should (= actlog--session-secs 45.0))
   (should (= actlog--since 12345.0))))

(ert-deftest actlog-state-corrupt-file-tolerated ()
  (actlog-test--env
   (with-temp-file actlog-state-file (insert "this is not ( a plist"))
   (should-not (actlog--load-state))
   ;; Books stay fresh, never broken.
   (should (null actlog--totals))))

(ert-deftest actlog-state-other-day-dropped ()
  (actlog-test--env
   (setq actlog--day (actlog-day-string))
   (with-temp-file actlog-state-file
     (prin1 `(actlog-state :version 1 :day "2001-01-01"
                           :totals (("old" . 99.0)))
            (current-buffer)))
   (should-not (actlog--load-state))
   (should (null actlog--totals))))

;;; ---------------------------------------------------------------------
;;; Mode plumbing
;;; ---------------------------------------------------------------------

(ert-deftest actlog-mode-starts-and-stops-cleanly ()
  (actlog-test--env
   (unwind-protect
       (progn
         (actlog-mode 1)
         (should actlog-mode)
         (should (timerp actlog--sampler-timer))
         (should (timerp actlog--flusher-timer))
         (should (member 'actlog--mode-line global-mode-string))
         (should (member #'actlog--shutdown kill-emacs-hook))
         (actlog-mode -1)
         (should-not actlog-mode)
         (should (null actlog--sampler-timer))
         (should (null actlog--flusher-timer))
         (should-not (member 'actlog--mode-line global-mode-string))
         (should-not (member #'actlog--shutdown kill-emacs-hook)))
     (when actlog-mode (actlog-mode -1)))))

(ert-deftest actlog-tick-attributes-current-buffer ()
  (actlog-test--env
   (let* ((proj (actlog-test--temp "tickproj"))
          (gitdir (expand-file-name ".git" proj)))
     (make-directory gitdir t)
     (let ((buf (find-file-noselect
                 (prog1 (expand-file-name "b.el" proj)
                   (with-temp-file (expand-file-name "b.el" proj)
                     (insert "x"))))))
       (set-window-buffer (selected-window) buf)
       (actlog--tick)
       (should (equal actlog--current-key "tickproj"))
       (should (equal actlog--current-mode "ELisp"))
       (kill-buffer buf)))))

(ert-deftest actlog-report-renders-today-table ()
  (actlog-test--env
   (let* ((start (actlog-test--secs 0 20 11 7 11 2026))
          (today (actlog-day-string))
          (day (progn
                 (actlog--journal-clock today "a" "m" start
                                        (+ start 60.0))
                 today))
          (buf (actlog-report day)))
     (with-current-buffer buf
       ;; Escape the + -- in a regexp it is a quantifier.
       (should (string-match-p "^#\\+title: Actlog " (buffer-string)))
       (should (string-match-p "^| a | 0:01 |$" (buffer-string)))
       (should (string-match-p "^| Total | 0:01 |$" (buffer-string)))))))

(provide 'actlog-test)
;;; test.el ends here
