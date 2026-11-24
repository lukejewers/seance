;;; seance-test.el --- Tests for seance -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'seance)
(require 'map)

(defvar ghostel-annotation-function)

(defconst seance-test-hook
  (expand-file-name "../bin/seance-hook"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defconst seance-test-statusline
  (expand-file-name "../bin/seance-statusline"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro seance-test-with-terminal (buffer &rest body)
  "Run BODY with BUFFER bound to a fresh terminal buffer tagged \"1\"."
  (declare (indent 1))
  (let ((buf (make-symbol "buf")))
    `(let* ((seance--agents (make-hash-table :test #'equal))
            (seance-notify-function #'ignore)
            (,buf (generate-new-buffer "*seance-test*"))
            (,buffer ,buf))
       (unwind-protect
           (progn
             (with-current-buffer ,buf
               (setq seance--id "1"))
             ,@body)
         (kill-buffer ,buf)))))

(defun seance-test-report (id &rest fields)
  "Report a hook event with FIELDS, a plist of symbol keys, for ID."
  (seance-report id (json-serialize (map-into fields 'alist))))

(defun seance-test-status (id)
  "Return the status of the agent tagged ID."
  (when-let* ((agent (gethash id seance--agents)))
    (seance-agent-status agent)))

(ert-deftest seance-test-event-status ()
  (should (eq (seance--event-status '((hook_event_name . "SessionStart"))) 'idle))
  (should (eq (seance--event-status '((hook_event_name . "UserPromptSubmit"))) 'working))
  (should (eq (seance--event-status '((hook_event_name . "PostToolUse"))) 'working))
  (should (eq (seance--event-status '((hook_event_name . "Notification")
                                          (notification_type . "permission_prompt")))
              'blocked))
  (should (eq (seance--event-status '((hook_event_name . "PostToolUseFailure"))) 'working))
  (should (eq (seance--event-status '((hook_event_name . "Stop"))) 'done))
  (should (eq (seance--event-status '((hook_event_name . "StopFailure"))) 'done))
  (should (eq (seance--event-status '((hook_event_name . "Interrupt"))) 'idle))
  (should (eq (seance--event-status '((hook_event_name . "SessionEnd"))) 'ended))
  (should (eq (seance--event-status '((hook_event_name . "SessionEnd")
                                      (reason . "prompt_input_exit")))
              'ended))
  (dolist (reason '("clear" "resume"))
    (should-not (seance--event-status `((hook_event_name . "SessionEnd")
                                        (reason . ,reason)))))
  (dolist (type '(nil "permission_prompt" "worker_permission_prompt" "ui_prompt"))
    (should (eq (seance--event-status `((hook_event_name . "Notification")
                                        (notification_type . ,type)))
                'blocked)))
  (dolist (type '("idle_prompt" "auth_success" "elicitation_response"))
    (should-not (seance--event-status `((hook_event_name . "Notification")
                                        (notification_type . ,type)))))
  (should-not (seance--event-status '((hook_event_name . "PostToolUse")
                                          (agent_id . "sub"))))
  (should-not (seance--event-status '((hook_event_name . "PreCompact")))))

(ert-deftest seance-test-report-tracks-lifecycle ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "SessionStart" 'cwd "/tmp/project")
    (should (eq (seance-test-status "1") 'idle))
    (should (equal (seance-agent-cwd (gethash "1" seance--agents)) "/tmp/project"))
    (should (eq (seance-agent-buffer (gethash "1" seance--agents)) terminal))
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
    (should (eq (seance-test-status "1") 'working))
    (seance-test-report "1" 'hook_event_name "Notification"
                            'notification_type "permission_prompt"
                            'message "Claude needs your permission to use Bash")
    (should (eq (seance-test-status "1") 'blocked))
    (should (equal (seance-agent-message (gethash "1" seance--agents))
                   "Claude needs your permission to use Bash"))
    (seance-test-report "1" 'hook_event_name "PostToolUse")
    (should (eq (seance-test-status "1") 'working))
    (should-not (seance-agent-message (gethash "1" seance--agents)))
    (seance-test-report "1" 'hook_event_name "Stop")
    (should (eq (seance-test-status "1") 'done))
    (seance-test-report "1" 'hook_event_name "SessionEnd")
    (should-not (gethash "1" seance--agents))))

(ert-deftest seance-test-report-ignores-unknown-terminal ()
  (seance-test-with-terminal _terminal
    (seance-test-report "99" 'hook_event_name "Stop")
    (should (= (hash-table-count seance--agents) 0))))

(ert-deftest seance-test-notifies-once-when-not-watching ()
  (seance-test-with-terminal _terminal
    (let* ((notified nil)
           (seance-notify-function (lambda (agent) (push (seance-agent-status agent) notified))))
      (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
      (seance-test-report "1" 'hook_event_name "Notification" 'notification_type "permission_prompt")
      (seance-test-report "1" 'hook_event_name "Notification" 'notification_type "permission_prompt")
      (seance-test-report "1" 'hook_event_name "Stop")
      (should (equal notified '(done blocked))))))

(ert-deftest seance-test-done-while-watching-is-idle ()
  (seance-test-with-terminal terminal
    (let* ((notified nil)
           (seance-notify-function (lambda (_agent) (setq notified t))))
      (save-window-excursion
        (set-window-buffer (selected-window) terminal)
        (seance-test-report "1" 'hook_event_name "Stop"))
      (should (eq (seance-test-status "1") 'idle))
      (should-not notified))))

(ert-deftest seance-test-selecting-buffer-marks-done-seen ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Stop")
    (should (eq (seance-test-status "1") 'done))
    (save-window-excursion
      (set-window-buffer (selected-window) terminal)
      (seance--mark-seen))
    (should (eq (seance-test-status "1") 'idle))))

(ert-deftest seance-test-killing-buffer-forgets-agent ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Stop")
    (with-current-buffer terminal
      (seance--forget-current-buffer))
    (should-not (gethash "1" seance--agents))))

(ert-deftest seance-test-tag-terminal-sets-environment ()
  (with-temp-buffer
    (let ((process-environment (copy-sequence process-environment))
          (seance--next-id 41))
      (seance--tag-terminal)
      (should (equal seance--id "42"))
      (should (equal (getenv "SEANCE_ID") "42")))))

(ert-deftest seance-test-next-prefers-oldest-blocked ()
  (let ((seance--agents (make-hash-table :test #'equal))
        (done (generate-new-buffer "done"))
        (old-blocked (generate-new-buffer "old-blocked"))
        (new-blocked (generate-new-buffer "new-blocked")))
    (unwind-protect
        (progn
          (puthash "1" (seance-agent-create :id "1" :buffer done :status 'done :changed 1)
                   seance--agents)
          (puthash "2" (seance-agent-create :id "2" :buffer new-blocked :status 'blocked :changed 3)
                   seance--agents)
          (puthash "3" (seance-agent-create :id "3" :buffer old-blocked :status 'blocked :changed 2)
                   seance--agents)
          (should (equal (mapcar #'seance-agent-id (seance--sorted-agents)) '("3" "2" "1")))
          (save-window-excursion
            (with-current-buffer old-blocked
              (seance-next)
              (should (eq (window-buffer (selected-window)) new-blocked))))
          (should (equal (seance--mode-line) " [2 blocked, 1 done]")))
      (mapc #'kill-buffer (list done old-blocked new-blocked)))))

(ert-deftest seance-test-board-lists-agents ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Notification"
                            'notification_type "permission_prompt"
                            'message "Needs approval" 'cwd "/tmp/project")
    (save-window-excursion
      (seance)
      (should (string-match-p "blocked.*seance-test.*/tmp/project.*Needs approval"
                              (buffer-string)))
      (goto-char (point-min))
      (seance-list-visit)
      (should (eq (current-buffer) terminal)))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-board-pops-up-at-bottom ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (save-window-excursion
      (delete-other-windows)
      (let ((origin (selected-window)))
        (seance)
        (should (eq (current-buffer) (get-buffer seance-buffer-name)))
        (should (window-parameter nil 'seance-popup))
        (should (< (window-height) (window-height origin)))
        (should (eq (window-in-direction 'above) origin))
        (goto-char (point-min))
        (seance-list-visit)
        (should (one-window-p))
        (should (eq (selected-window) origin))
        (should (eq (window-buffer origin) terminal))))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-refresh-tick-keeps-popup-size ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
    (let ((seance-refresh-interval nil))
      (save-window-excursion
        (delete-other-windows)
        (seance)
        (enlarge-window 5)
        (let ((height (window-height)))
          (seance--refresh-tick)
          (should (= (window-height) height))
          (seance--refresh)
          (should (< (window-height) height)))))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-board-shows-blocked-message-as-title ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Notification"
                            'notification_type "permission_prompt"
                            'message "Needs approval" 'cwd "/tmp")
    (with-current-buffer terminal
      (setq-local ghostel-title "✳ Fix login bug"))
    (save-window-excursion
      (seance)
      (should (string-match-p "Needs approval" (buffer-string)))
      (should-not (string-match-p "Fix login bug" (buffer-string))))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-board-kills-agent ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (save-window-excursion
      (seance)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'yes-or-no-p) #'ignore))
        (seance-list-kill))
      (should (buffer-live-p terminal))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (seance-list-kill))
      (should-not (buffer-live-p terminal))
      (should (= (buffer-size) 0)))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-board-shows-terminal-title ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (with-current-buffer terminal
      (setq-local ghostel-title "✳ Fix login bug"))
    (save-window-excursion
      (seance)
      (should (string-match-p "working.*seance-test.*/tmp.*Fix login bug"
                              (buffer-string)))
      (should-not (string-match-p "✳" (buffer-string))))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-board-without-title ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "SessionStart" 'cwd "/tmp")
    (should (equal (seance--agent-title (gethash "1" seance--agents)) ""))))

(ert-deftest seance-test-annotation-shows-status ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (with-current-buffer terminal
      (should (eq ghostel-annotation-function #'seance--annotation))
      (should (equal (funcall ghostel-annotation-function) "working")))))

(ert-deftest seance-test-switch-to-agent-reads-agents ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Stop" 'cwd "/tmp/project")
    (with-current-buffer terminal
      (setq-local ghostel-title "✳ Fix login bug"))
    (let (seen-default seen-annotation)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest args)
                   (let* ((name (buffer-name terminal))
                          (metadata (funcall collection "" nil 'metadata)))
                     (setq seen-default (nth 4 args)
                           seen-annotation
                           (funcall (alist-get 'annotation-function (cdr metadata))
                                    name))
                     name))))
        (save-window-excursion
          (with-temp-buffer
            (call-interactively #'seance-switch-to-agent)
            (should (eq (window-buffer) terminal)))))
      (should (equal seen-default (buffer-name terminal)))
      (should (string-match-p "done.*Fix login bug.*/tmp/project" seen-annotation)))))

(ert-deftest seance-test-buffer-name-follows-title ()
  (with-temp-buffer
    (setq-local seance--base-name "claude: seance")
    (should (equal (seance--buffer-name nil) "*claude: seance*"))
    (should (equal (seance--buffer-name "✳ Claude Code") "*claude: seance*"))
    (should (equal (seance--buffer-name "⠂ Fix login bug")
                   "*claude: seance - Fix login bug*"))
    (should (equal (seance--buffer-name "✳ Fix login bug")
                   (seance--buffer-name "⠐ Fix login bug")))
    (setq-local seance--base-name "pi: seance")
    (should (equal (seance--buffer-name "π - seance") "*pi: seance*"))
    (should (equal (seance--buffer-name "π - Fix login - bug - seance")
                   "*pi: seance - Fix login - bug*"))))

(ert-deftest seance-test-board-highlights-line ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
    (save-window-excursion
      (seance)
      (should hl-line-mode)
      (should (overlay-start hl-line-overlay)))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-switch-to-agent-without-agents ()
  (let ((seance--agents (make-hash-table :test #'equal)))
    (should-error (seance--read-agent-buffer "Agent") :type 'user-error)))

(ert-deftest seance-test-report-records-context ()
  (seance-test-with-terminal _terminal
    (should-not (seance-test-report "1" 'hook_event_name "Info" 'context_tokens 100))
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (should (eq (seance-test-report "1" 'hook_event_name "Info"
                                    'context_tokens 52400 'context_percent 26.2)
                t))
    (let ((agent (gethash "1" seance--agents)))
      (should (= (seance-agent-context-tokens agent) 52400))
      (should (equal (seance--format-context agent) "52k 26%"))
      (should (eq (seance-test-status "1") 'working))
      (seance-test-report "1" 'hook_event_name "Info"
                          'context_tokens :null 'context_percent :null)
      (should (equal (seance--format-context agent) ""))
      (seance-test-report "1" 'hook_event_name "Info" 'context_tokens 812)
      (should (equal (seance--format-context agent) "812"))
      (seance-test-report "1" 'hook_event_name "Stop")
      (should (equal (seance--format-context agent) "812"))
      (seance-test-report "1" 'hook_event_name "SessionStart")
      (should (equal (seance--format-context agent) "")))))

(ert-deftest seance-test-interrupt-leaves-agent-idle ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
    (seance-test-report "1" 'hook_event_name "Interrupt")
    (should (eq (seance-test-status "1") 'idle))))

(defun seance-test-type (buffer key &optional command)
  "Note KEY, sent by COMMAND, as typed into BUFFER."
  (with-current-buffer buffer
    (let ((last-command-event key)
          (this-command command))
      (seance--note-input))))

(ert-deftest seance-test-answering-prompt-clears-blocked ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Notification"
                        'notification_type "permission_prompt"
                        'message "Claude needs your permission to use Bash")
    (seance-test-type terminal ?1)
    (should (eq (seance-test-status "1") 'working))
    (should-not (seance-agent-message (gethash "1" seance--agents)))
    (seance-test-type terminal ?x)
    (should (eq (seance-test-status "1") 'working))))

(ert-deftest seance-test-interrupt-key-leaves-agent-idle ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit")
    (seance-test-type terminal 'escape)
    (should (eq (seance-test-status "1") 'idle))
    (seance-test-report "1" 'hook_event_name "Notification"
                        'notification_type "permission_prompt")
    (seance-test-type terminal ?\C-c 'ghostel-send-C-c)
    (should (eq (seance-test-status "1") 'idle))))

(ert-deftest seance-test-input-leaves-done-alone ()
  (seance-test-with-terminal terminal
    (seance-test-report "1" 'hook_event_name "Stop")
    (seance-test-type terminal 'escape)
    (should (eq (seance-test-status "1") 'done))))

(ert-deftest seance-test-board-refresh-timer ()
  (let ((seance--refresh-timer nil)
        (seance-buffer-name "*seance-timer-test*"))
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create seance-buffer-name)
            (seance-list-mode))
          (should (timerp seance--refresh-timer))
          (let ((timer seance--refresh-timer))
            (with-current-buffer seance-buffer-name
              (seance-list-mode))
            (should (eq seance--refresh-timer timer)))
          (kill-buffer seance-buffer-name)
          (seance--refresh-tick)
          (should-not seance--refresh-timer))
      (seance--stop-refresh-timer)
      (when (get-buffer seance-buffer-name)
        (kill-buffer seance-buffer-name)))))

(ert-deftest seance-test-board-refresh-timer-disabled ()
  (let ((seance--refresh-timer nil)
        (seance-refresh-interval nil))
    (with-temp-buffer
      (seance-list-mode)
      (should-not seance--refresh-timer))))

(defun seance-test-dead-pid ()
  "Return the process ID of a process that has exited."
  (let ((process (start-process "seance-test" nil "true")))
    (while (process-live-p process)
      (accept-process-output process 0.05))
    (process-id process)))

(ert-deftest seance-test-ignores-agents-the-agent-runs ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'pid (emacs-pid))
    ;; A `claude -p' the agent runs reports under the same SEANCE_ID.
    (should-not (seance-test-report "1" 'hook_event_name "SessionStart" 'pid 1
                                    'model_name "Haiku"))
    (seance-test-report "1" 'hook_event_name "SessionEnd" 'pid 1)
    (should (eq (seance-test-status "1") 'working))
    (should-not (seance-agent-model (gethash "1" seance--agents)))
    (seance-test-report "1" 'hook_event_name "Stop" 'pid (emacs-pid))
    (should (eq (seance-test-status "1") 'done))))

(ert-deftest seance-test-new-process-takes-over-after-exit ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'pid (seance-test-dead-pid))
    ;; The agent died without a SessionEnd, and a new one started.
    (seance-test-report "1" 'hook_event_name "SessionStart" 'pid (emacs-pid))
    (should (eq (seance-test-status "1") 'idle))
    (should (eql (seance-agent-pid (gethash "1" seance--agents)) (emacs-pid)))))

(ert-deftest seance-test-clear-keeps-agent ()
  ;; /clear's SessionEnd may reach Emacs after its SessionStart.
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "SessionStart")
    (seance-test-report "1" 'hook_event_name "SessionEnd" 'reason "clear")
    (should (eq (seance-test-status "1") 'idle))))

(ert-deftest seance-test-report-records-model ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "SessionStart")
    (should (eq (seance-test-report "1" 'hook_event_name "Info" 'model_name "Opus 5.5")
                t))
    (let ((agent (gethash "1" seance--agents)))
      (should (equal (seance-agent-model agent) "Opus 5.5"))
      ;; Other events, and Claude Code's own model field, leave it alone.
      (seance-test-report "1" 'hook_event_name "SessionStart" 'model "claude-opus-5-5")
      (should (equal (seance-agent-model agent) "Opus 5.5"))
      (seance-test-report "1" 'hook_event_name "Info" 'model_name :null)
      (should-not (seance-agent-model agent)))))

(ert-deftest seance-test-board-shows-context ()
  (seance-test-with-terminal _terminal
    (seance-test-report "1" 'hook_event_name "UserPromptSubmit" 'cwd "/tmp")
    (seance-test-report "1" 'hook_event_name "Info" 'model_name "Sonnet 5.5"
                        'context_tokens 1250000 'context_percent 62.5)
    (save-window-excursion
      (seance)
      (should (string-match-p "working.*seance-test.*Sonnet 5\\.5.*1\\.2M 62%.*/tmp"
                              (buffer-string))))
    (kill-buffer seance-buffer-name)))

(ert-deftest seance-test-format-tokens ()
  (should (equal (seance--format-tokens 0) "0"))
  (should (equal (seance--format-tokens 999) "999"))
  (should (equal (seance--format-tokens 52400) "52k"))
  (should (equal (seance--format-tokens 999400) "999k"))
  (should (equal (seance--format-tokens 999600) "1.0M")))

(ert-deftest seance-test-format-age ()
  (should (equal (seance--format-age 5) "5s"))
  (should (equal (seance--format-age 125) "2m"))
  (should (equal (seance--format-age 7300) "2h"))
  (should (equal (seance--format-age 200000) "2d")))

(defun seance-test-run-hook (env input)
  "Run the hook script with ENV and stdin INPUT.
Return its exit code and the form it passed to emacsclient."
  (let* ((dir (make-temp-file "seance" t))
         (capture (expand-file-name "eval" dir))
         (client (expand-file-name "emacsclient" dir))
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > " (shell-quote-argument capture) "\n"))
          (set-file-modes client #o755)
          (let* ((process-environment
                  (append (list (concat "SEANCE_EMACSCLIENT=" client)) env process-environment))
                 (code (with-temp-buffer
                         (insert input)
                         (call-process-region (point-min) (point-max) seance-test-hook
                                              nil nil nil))))
            (list code
                  (when (file-exists-p capture)
                    (with-temp-buffer
                      (insert-file-contents capture)
                      (car (read-from-string (buffer-string))))))))
      (delete-directory dir t))))

(ert-deftest seance-test-hook-quotes-event-for-emacs ()
  (let* ((message "Say \"hi\" to C:\\path\nnext line ünïcode 🎉 \e[0m")
         (input (json-serialize `((hook_event_name . "Notification")
                                  (message . ,message)
                                  (cwd . "/tmp/project")
                                  (tool_response . ,(make-string 300000 ?x)))))
         (result (seance-test-run-hook '("SEANCE_ID=7") input))
         (form (nth 1 result))
         (event (json-parse-string (nth 2 form) :object-type 'alist :null-object nil)))
    (should (= (car result) 0))
    (should (eq (nth 0 form) 'seance-report))
    (should (equal (nth 1 form) "7"))
    (should (equal (alist-get 'message event) message))
    (should (equal (alist-get 'cwd event) "/tmp/project"))
    (should-not (alist-get 'tool_response event))))

(ert-deftest seance-test-hook-passes-context ()
  (let* ((input "{\"hook_event_name\":\"Info\",\"model_name\":\"Opus\",\"model\":\"x\",\"context_tokens\":5,\"context_percent\":null}")
         (form (nth 1 (seance-test-run-hook '("SEANCE_ID=1") input)))
         (event (json-parse-string (nth 2 form) :object-type 'alist :null-object :null)))
    (should (equal (alist-get 'model_name event) "Opus"))
    (should-not (assq 'model event))
    (should (equal (alist-get 'context_tokens event) 5))
    (should (eq (alist-get 'context_percent event) :null))))

(defun seance-test-run-statusline (env input &rest args)
  "Run the status line script twice with ENV, stdin INPUT and ARGS.
Return the output of each run and the forms passed to emacsclient."
  (let* ((dir (make-temp-file "seance" t))
         (capture (expand-file-name "eval" dir))
         (client (expand-file-name "emacsclient" dir))
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s\\n' \"$2\" >> " (shell-quote-argument capture)
                    "\necho t\n"))
          (set-file-modes client #o755)
          (let ((process-environment
                 (append env
                         (list (concat "SEANCE_EMACSCLIENT=" client)
                               (concat "XDG_RUNTIME_DIR=" dir)
                               (concat "XDG_CACHE_HOME=" dir))
                         process-environment)))
            (append
             (cl-loop repeat 2
                      collect (with-temp-buffer
                                (insert input)
                                (apply #'call-process-region (point-min) (point-max)
                                       seance-test-statusline t t nil args)
                                (buffer-string)))
             (list (when (file-exists-p capture)
                     (with-temp-buffer
                       (insert-file-contents capture)
                       (let (forms)
                         (condition-case nil
                             (while t (push (read (current-buffer)) forms))
                           (end-of-file))
                         (nreverse forms))))))))
      (delete-directory dir t))))

(defconst seance-test-statusline-input
  (json-serialize
   '((session_id . "abc")
     (model . ((display_name . "Opus")))
     (context_window . ((context_window_size . 200000)
                        (used_percentage . 26)
                        (current_usage . ((input_tokens . 4)
                                          (output_tokens . 500)
                                          (cache_creation_input_tokens . 600)
                                          (cache_read_input_tokens . 51396))))))))

(ert-deftest seance-test-statusline-reports-context-once ()
  (pcase-let ((`(,first ,second ,forms)
               (seance-test-run-statusline '("SEANCE_ID=3") seance-test-statusline-input
                                           "jq -r .model.display_name")))
    (should (equal first "Opus\n"))
    (should (equal second "Opus\n"))
    (should (= (length forms) 1))
    (should (equal (nth 1 (car forms)) "3"))
    (let ((event (json-parse-string (nth 2 (car forms)) :object-type 'alist)))
      (should (equal (alist-get 'hook_event_name event) "Info"))
      (should (equal (alist-get 'model_name event) "Opus"))
      (should (equal (alist-get 'context_tokens event) 52000))
      (should (equal (alist-get 'context_percent event) 26)))))

(ert-deftest seance-test-statusline-cache-without-runtime-dir ()
  ;; With no XDG_RUNTIME_DIR the cache goes in XDG_CACHE_HOME, never a
  ;; shared directory such as /tmp, and still stops repeat reports.
  (pcase-let ((`(,_ ,_ ,forms)
               (seance-test-run-statusline '("SEANCE_ID=3" "XDG_RUNTIME_DIR" "TMPDIR=/nonexistent")
                                           seance-test-statusline-input)))
    (should (= (length forms) 1))))

(ert-deftest seance-test-statusline-unknown-context ()
  (pcase-let ((`(,_ ,_ ,forms)
               (seance-test-run-statusline
                '("SEANCE_ID=3")
                "{\"session_id\":\"abc\",\"context_window\":{\"used_percentage\":7,\"current_usage\":null}}")))
    (let ((event (json-parse-string (nth 2 (car forms)) :object-type 'alist
                                    :null-object :null)))
      (should (eq (alist-get 'context_tokens event) :null))
      (should (eq (alist-get 'context_percent event) :null)))))

(ert-deftest seance-test-statusline-outside-seance ()
  (pcase-let ((`(,first ,_ ,forms)
               (seance-test-run-statusline '("SEANCE_ID") seance-test-statusline-input
                                           "echo plain")))
    (should (equal first "plain\n"))
    (should-not forms)))

(ert-deftest seance-test-hook-passes-pid-and-reason ()
  (let* ((input "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"clear\"}")
         (form (nth 1 (seance-test-run-hook '("SEANCE_ID=1" "CLAUDE_PID=4242") input)))
         (event (json-parse-string (nth 2 form) :object-type 'alist)))
    (should (equal (alist-get 'reason event) "clear"))
    (should (equal (alist-get 'pid event) 4242)))
  ;; Pi sends its own pid, which wins over an inherited CLAUDE_PID.
  (let* ((input "{\"hook_event_name\":\"Stop\",\"pid\":7}")
         (form (nth 1 (seance-test-run-hook '("SEANCE_ID=1" "CLAUDE_PID=4242") input))))
    (should (equal (alist-get 'pid (json-parse-string (nth 2 form) :object-type 'alist)) 7)))
  (let* ((form (nth 1 (seance-test-run-hook '("SEANCE_ID=1" "CLAUDE_PID")
                                            "{\"hook_event_name\":\"Stop\"}"))))
    (should (eq (alist-get 'pid (json-parse-string (nth 2 form) :object-type 'alist
                                                   :null-object :null))
                :null))))

(ert-deftest seance-test-hook-skips-untracked-terminals ()
  (dolist (env '(("SEANCE_ID") ("SEANCE_ID=") ("SEANCE_ID=1;rm")))
    (let ((result (seance-test-run-hook env "{\"hook_event_name\":\"Stop\"}")))
      (should (= (car result) 0))
      (should-not (nth 1 result)))))

(ert-deftest seance-test-hook-prints-nothing ()
  ;; Claude Code adds the output of some hooks to the conversation.
  (let ((process-environment (append '("SEANCE_ID=1" "SEANCE_EMACSCLIENT=echo")
                                     process-environment)))
    (with-temp-buffer
      (insert "{\"hook_event_name\":\"SessionStart\"}")
      (should (= (call-process-region (point-min) (point-max) seance-test-hook t t nil) 0))
      (should (equal (buffer-string) "")))))

(ert-deftest seance-test-hook-ignores-emacsclient-failure ()
  (let ((process-environment (cons "SEANCE_ID=1" process-environment)))
    (should (= (with-temp-buffer
                 (insert "{\"hook_event_name\":\"Stop\"}")
                 (let ((process-environment (cons "SEANCE_EMACSCLIENT=false" process-environment)))
                   (call-process-region (point-min) (point-max) seance-test-hook nil nil nil)))
               0))))

;; Launching agents

(defmacro seance-test-with-fake-ghostel (calls &rest body)
  "Run BODY with ghostel stubbed out, recording `ghostel-exec' calls in CALLS."
  (declare (indent 1))
  (let ((log (make-symbol "log")))
    `(let ((,log nil))
       (cl-letf (((symbol-function 'ghostel-mode) #'ignore)
                 ((symbol-function 'ghostel-exec)
                  (lambda (buffer program &optional args _identity)
                    (push (list buffer program args
                                (buffer-local-value 'default-directory buffer))
                          ,log))))
         (cl-symbol-macrolet ((,calls ,log))
           ,@body)))))

(ert-deftest seance-test-launch-runs-agent-in-directory ()
  (let ((seance-agent-commands '(("claude" "claude" "--verbose")))
        (seance-load-integrations nil))
    (seance-test-with-fake-ghostel calls
      (let ((buffer (seance-launch "claude" "/tmp/project")))
        (unwind-protect
            (progn
              (should (equal (buffer-name buffer) "*claude: project*"))
              (should (equal calls `((,buffer "claude" ("--verbose") "/tmp/project/")))))
          (kill-buffer buffer))))))

(ert-deftest seance-test-launch-rejects-unknown-agent ()
  (let ((seance-agent-commands '(("claude" "claude"))))
    (seance-test-with-fake-ghostel calls
      (should-error (seance-launch "nope" "/tmp/") :type 'user-error)
      (should-not calls))))

(ert-deftest seance-test-launch-kills-buffer-when-spawn-fails ()
  (let ((seance-agent-commands '(("pi" "pi"))))
    (seance-test-with-fake-ghostel _calls
      (cl-letf (((symbol-function 'ghostel-exec)
                 (lambda (&rest _) (error "No such program"))))
        (should-error (seance-launch "pi" "/tmp/project"))
        (should-not (get-buffer "*pi: project*"))))))

(ert-deftest seance-test-launch-directory ()
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) '(transient . "/src/here/")))
            ((symbol-function 'project-prompt-project-dir) (lambda (&rest _) "/src/chosen/")))
    (should (equal (seance--launch-directory) "/src/here/"))
    (should (equal (seance--launch-directory t) "/src/chosen/")))
  (cl-letf (((symbol-function 'project-current) #'ignore)
            ((symbol-function 'project-prompt-project-dir) (lambda (&rest _) "/src/chosen/")))
    (should (equal (seance--launch-directory) "/src/chosen/"))))

(ert-deftest seance-test-launch-loads-integrations ()
  (let ((seance-agent-commands '(("claude" "claude" "--verbose")
                                 ("pi" "/usr/bin/pi")))
        (seance-load-integrations t))
    (seance-test-with-fake-ghostel calls
      (dolist (agent '("claude" "pi"))
        (kill-buffer (seance-launch agent "/tmp/project")))
      (pcase-let ((`((,_ ,_ ,pi-args ,_) (,_ ,_ ,claude-args ,_)) calls))
        (should (equal (seq-take claude-args 3)
                       (list "--plugin-dir" (directory-file-name seance--root)
                             "--settings")))
        (should (equal (car (last claude-args)) "--verbose"))
        (should (equal pi-args
                       (list "-e" (expand-file-name "pi/seance.ts" seance--root))))))))

(defmacro seance-test-with-claude-settings (user &rest body)
  "Run BODY with `project' bound to a fresh project directory.
The user's Claude settings hold the JSON string USER, unless it is nil."
  (declare (indent 1))
  (let ((root (make-symbol "root")))
    `(let* ((,root (make-temp-file "seance" t))
            (process-environment
             (cons (concat "CLAUDE_CONFIG_DIR=" (expand-file-name "config" ,root))
                   process-environment)))
       (unwind-protect
           (progn
             (make-directory (expand-file-name "config" ,root))
             (make-directory (expand-file-name "project/.claude" ,root) t)
             (when ,user
               (with-temp-file (expand-file-name "config/settings.json" ,root)
                 (insert ,user)))
             (let ((project (expand-file-name "project/" ,root)))
               ,@body))
         (delete-directory ,root t)))))

(defun seance-test-statusline-setting (directory)
  "Return the statusLine `seance--claude-settings' makes for DIRECTORY."
  (alist-get 'statusLine
             (json-parse-string (seance--claude-settings directory)
                                :object-type 'alist :false-object :false)))

(ert-deftest seance-test-claude-settings-without-statusline ()
  (seance-test-with-claude-settings nil
    (let ((statusline (seance-test-statusline-setting project)))
      (should (equal (alist-get 'type statusline) "command"))
      (should (equal (alist-get 'command statusline)
                     (shell-quote-argument
                      (expand-file-name "bin/seance-statusline" seance--root)))))))

(ert-deftest seance-test-claude-settings-wraps-user-statusline ()
  (seance-test-with-claude-settings
      "{\"statusLine\":{\"type\":\"command\",\"command\":\"~/bin/line 'a b'\",\"padding\":2,\"hideVimModeIndicator\":false}}"
    (let ((statusline (seance-test-statusline-setting project)))
      (should (equal (alist-get 'padding statusline) 2))
      (should (eq (alist-get 'hideVimModeIndicator statusline) :false))
      (should (string-suffix-p (concat " " (shell-quote-argument "~/bin/line 'a b'"))
                               (alist-get 'command statusline))))
    ;; Project settings win over the user's.
    (with-temp-file (expand-file-name ".claude/settings.json" project)
      (insert "{\"statusLine\":{\"type\":\"command\",\"command\":\"project-line\"}}"))
    (should (string-suffix-p " project-line"
                             (alist-get 'command (seance-test-statusline-setting project))))))

(ert-deftest seance-test-claude-statusline-can-be-disabled ()
  (let ((seance-claude-statusline nil))
    (should (equal (seance--integration-args "claude" "/tmp/")
                   (list "--plugin-dir" (directory-file-name seance--root))))))

(ert-deftest seance-test-integration-args-skip-other-programs ()
  (should-not (seance--integration-args "aider")))

(ert-deftest seance-test-integration-files-exist ()
  (should (file-exists-p (expand-file-name "hooks/hooks.json" seance--root)))
  (should (file-executable-p (expand-file-name "bin/seance-send" seance--root)))
  (should (file-executable-p (expand-file-name "bin/seance-hook" seance--root)))
  (should (file-executable-p (expand-file-name "bin/seance-statusline" seance--root))))

;;; seance-test.el ends here
