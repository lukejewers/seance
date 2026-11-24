;;; seance.el --- Status board for AI agents running in ghostel -*- lexical-binding: t; -*-

;; Author: Luke Jewers
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes

;;; Commentary:

;; Tracks Claude Code sessions running in ghostel buffers.  Each ghostel
;; terminal gets a SEANCE_ID environment variable when it spawns.
;; Claude Code hooks run bin/seance-hook, which reports lifecycle
;; events back to Emacs with emacsclient.  Agents show up in a board
;; buffer, a mode-line lighter and notifications.  See README.md.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'server)
(require 'subr-x)
(require 'hl-line)
(require 'tabulated-list)

(defvar ghostel-pre-spawn-hook)
(defvar ghostel-title)
(defvar ghostel-annotation-function)
(declare-function ghostel-mode "ghostel")
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel--on-user-input "ghostel")

(defgroup seance nil
  "Status board for AI agents running in ghostel."
  :group 'tools
  :prefix "seance-")

(defcustom seance-notify-statuses '(blocked done)
  "Statuses that call `seance-notify-function' when an agent enters them."
  :type '(set (const blocked) (const done) (const working) (const idle)))

(defcustom seance-notify-function #'seance-notify-message
  "Function called with an `seance-agent' that needs attention.
It is only called when the agent's buffer is not in the selected window."
  :type 'function)

(defcustom seance-buffer-name "*seance*"
  "Name of the board buffer."
  :type 'string)

(defcustom seance-refresh-interval 10
  "Seconds between redraws of the board while it is shown.
The redraw keeps the Since column current between agent events.  Nil
redraws only when an agent reports something."
  :type '(choice (const :tag "Only on agent events" nil) number))

(defcustom seance-start-server t
  "Whether `seance-mode' starts the Emacs server for emacsclient."
  :type 'boolean)

(defcustom seance-agent-commands '(("claude" "claude")
                                   ("pi" "pi"))
  "Agents `seance-launch' can start.
Each element is (NAME PROGRAM ARGS...).  PROGRAM is looked up in
`exec-path' and run directly, without a shell."
  :type '(alist :key-type (string :tag "Name")
                :value-type (repeat :tag "Program and arguments" string)))

(defcustom seance-load-integrations t
  "Whether `seance-launch' loads seance's agent integrations itself.
When non-nil, Claude Code gets this checkout as a plugin with
--plugin-dir and Pi gets pi/seance.ts with -e, so launched agents
report to the board without installing anything.  Turn this off if
you have installed the integrations and do not want them loaded twice."
  :type 'boolean)

(defcustom seance-claude-statusline t
  "Whether `seance-launch' wraps Claude Code's status line.
When non-nil, and `seance-load-integrations' is too, Claude Code runs
bin/seance-statusline as its status line command.  That reports the
model and how much of the context window is used to the board, then
runs the status
line command from your Claude settings, if any, so the status line looks
the same as before."
  :type 'boolean)

(defcustom seance-rename-buffers t
  "Whether `seance-launch' names agent buffers after their terminal title.
When non-nil, a buffer starts as \"*claude: project*\" and is renamed to
\"*claude: project - TOPIC*\" as the agent sets its title.  Renaming the
buffer yourself stops this for that buffer."
  :type 'boolean)

(defconst seance--root
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding seance.el and its agent integrations.")

(defface seance-blocked '((t :inherit error))
  "Face for agents waiting on you.")

(defface seance-done '((t :inherit success))
  "Face for agents that finished while you were elsewhere.")

(defface seance-working '((t :inherit warning))
  "Face for agents that are working.")

(defface seance-idle '((t :inherit shadow))
  "Face for idle agents.")

(cl-defstruct (seance-agent (:constructor seance-agent-create))
  id buffer status message cwd changed context-tokens context-percent model pid)

(defvar seance--agents (make-hash-table :test #'equal)
  "Agents keyed by SEANCE_ID.")

(defvar seance--next-id 0
  "Last SEANCE_ID handed to a terminal.")

(defvar-local seance--id nil
  "SEANCE_ID of the terminal in this buffer.")
(put 'seance--id 'permanent-local t)

(defconst seance--status-order '(blocked done working idle)
  "Statuses from most to least in need of attention.")

(defconst seance--blocking-notifications
  '(nil "permission_prompt" "worker_permission_prompt" "ui_prompt")
  "Notification types that mean the agent is waiting on you.
Claude Code also notifies for things that need nothing from you, such
as a finished login or an answered MCP question.  nil is for agents that
send no type; ui_prompt is Pi's.")

(defun seance--event-status (event)
  "Return the status implied by hook EVENT, or nil to ignore it.
EVENT is an alist parsed from Claude Code hook input.  The status
`ended' means the session is over."
  (pcase (alist-get 'hook_event_name event)
    ("SessionStart" 'idle)
    ("UserPromptSubmit" 'working)
    ((or "PostToolUse" "PostToolUseFailure")
     (unless (alist-get 'agent_id event) 'working))
    ("Notification" (and (member (alist-get 'notification_type event)
                                 seance--blocking-notifications)
                         'blocked))
    ((or "Stop" "StopFailure") 'done)
    ("Interrupt" 'idle)
    ;; After /clear or /resume the same process starts a new session.
    ("SessionEnd" (unless (member (alist-get 'reason event) '("clear" "resume"))
                    'ended))))

(defun seance-report (id json)
  "Record the Claude Code hook event JSON for the terminal tagged ID.
Called by bin/seance-hook through emacsclient."
  (let* ((event (json-parse-string json :object-type 'alist
                                   :null-object nil :false-object nil))
         (status (seance--event-status event)))
    (unless (seance--foreign-p id event)
      (when status
        (seance--update id status event))
      (seance--update-info id event))))

(defun seance--foreign-p (id event)
  "Return non-nil if EVENT is not from the agent tagged ID.
Programs the agent runs inherit its terminal's SEANCE_ID, so an agent
it starts, such as `claude -p', reports under the same ID.  EVENT's
pid tells them apart.  A new process takes over the ID once the
agent's own process has exited."
  (when-let* ((pid (alist-get 'pid event))
              (agent (gethash id seance--agents))
              (own (seance-agent-pid agent)))
    (and (/= pid own) (process-attributes own) t)))

(defun seance--update-info (id event)
  "Record the model and context use in EVENT for the agent tagged ID.
EVENT carries them as model_name, context_tokens and context_percent,
any of which may be null when unknown.  A SessionStart event without
the context fields clears the context use.  Returns t when EVENT had
something to record."
  (when-let* ((agent (gethash id seance--agents)))
    (let ((model (assq 'model_name event))
          (tokens (assq 'context_tokens event))
          (percent (assq 'context_percent event))
          (changed nil))
      (when model
        (unless (equal (seance-agent-model agent) (cdr model))
          (setf (seance-agent-model agent) (cdr model)
                changed t)))
      (when (or tokens percent
                (equal (alist-get 'hook_event_name event) "SessionStart"))
        (unless (and (eql (seance-agent-context-tokens agent) (cdr tokens))
                     (eql (seance-agent-context-percent agent) (cdr percent)))
          (setf (seance-agent-context-tokens agent) (cdr tokens)
                (seance-agent-context-percent agent) (cdr percent)
                changed t)))
      (when changed
        (seance--refresh))
      (and (or model tokens percent) t))))

(defun seance--buffer-for-id (id)
  "Return the live buffer whose terminal is tagged ID, or nil."
  (seq-find (lambda (buffer) (equal (buffer-local-value 'seance--id buffer) id))
            (buffer-list)))

(defun seance--watching-p (buffer)
  "Return non-nil if BUFFER is shown in the selected window."
  (eq buffer (window-buffer (selected-window))))

(defun seance--update (id status event)
  "Set the agent tagged ID to STATUS, using details from hook EVENT."
  (let ((buffer (seance--buffer-for-id id)))
    (if (or (eq status 'ended) (not buffer))
        (remhash id seance--agents)
      (let* ((agent (or (gethash id seance--agents)
                        (puthash id (seance-agent-create :id id) seance--agents)))
             (watching (seance--watching-p buffer))
             (status (if (and (eq status 'done) watching) 'idle status)))
        (with-current-buffer buffer
          (setq-local ghostel-annotation-function #'seance--annotation))
        (setf (seance-agent-buffer agent) buffer
              (seance-agent-cwd agent) (alist-get 'cwd event)
              (seance-agent-pid agent) (or (alist-get 'pid event)
                                           (seance-agent-pid agent)))
        (when (and (seance--set-status agent status (alist-get 'message event))
                   (memq status seance-notify-statuses)
                   (not watching))
          (funcall seance-notify-function agent)))))
  (seance--refresh))

(defun seance--set-status (agent status &optional message)
  "Set AGENT to STATUS, and return non-nil if that changed its status.
MESSAGE says what a blocked agent is waiting for; other statuses
have none."
  (setf (seance-agent-message agent) (and (eq status 'blocked) message))
  (unless (eq status (seance-agent-status agent))
    (setf (seance-agent-status agent) status
          (seance-agent-changed agent) (float-time))
    t))

(defun seance--note-input (&rest _)
  "Update the agent in this buffer for the key being sent to it.
Runs after `ghostel--on-user-input', which ghostel calls for every
key it sends to the terminal.  Claude Code runs no hook when you
interrupt a turn, so Esc or C-c sets a blocked or working agent idle,
and any other key sets a blocked agent working, as you have answered
its prompt.  The agent's next hook event overrides either guess."
  (when-let* ((agent (and seance--id (gethash seance--id seance--agents)))
              (status (seance-agent-status agent))
              (new (if (or (eq this-command 'ghostel-send-C-c)
                           (memq last-command-event '(escape 27 3)))
                       (and (memq status '(blocked working)) 'idle)
                     (and (eq status 'blocked) 'working)))
              ((seance--set-status agent new)))
    (seance--refresh)))

(defun seance--status-face (status)
  "Return the face for STATUS."
  (intern (format "seance-%s" status)))

(defun seance--status-label (status)
  "Return STATUS as a propertized string."
  (propertize (symbol-name status) 'face (seance--status-face status)))

(defun seance-notify-message (agent)
  "Echo that AGENT needs attention."
  (message "%s: %s%s"
           (buffer-name (seance-agent-buffer agent))
           (seance--status-label (seance-agent-status agent))
           (if-let* ((text (seance-agent-message agent)))
               (concat " - " text)
             "")))

(defun seance--agent< (a b)
  "Return non-nil if agent A needs attention before agent B."
  (let ((rank-a (seq-position seance--status-order (seance-agent-status a)))
        (rank-b (seq-position seance--status-order (seance-agent-status b))))
    (if (= rank-a rank-b)
        (< (seance-agent-changed a) (seance-agent-changed b))
      (< rank-a rank-b))))

(defun seance--sorted-agents ()
  "Return agents with live buffers, most in need of attention first."
  (sort (seq-filter (lambda (agent) (buffer-live-p (seance-agent-buffer agent)))
                    (hash-table-values seance--agents))
        #'seance--agent<))

(defun seance--count (status)
  "Return how many agents have STATUS."
  (seq-count (lambda (agent) (eq (seance-agent-status agent) status))
             (seance--sorted-agents)))

(defun seance--mode-line ()
  "Return the mode-line lighter for `seance-mode'."
  (let ((parts (seq-keep (lambda (status)
                           (let ((count (seance--count status)))
                             (when (> count 0)
                               (propertize (format "%d %s" count status)
                                           'face (seance--status-face status)))))
                         '(blocked done))))
    (if parts
        (concat " [" (string-join parts ", ") "]")
      "")))

(defun seance--format-age (seconds)
  "Return SECONDS as a short age such as 42s, 5m, 3h or 2d."
  (let ((seconds (max 0 (floor seconds))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun seance--clean-title (title)
  "Return the topic in terminal TITLE, or \"\" if it has none.
Claude Code starts its title with a spinner or \"✳\", which this
drops.  Pi's title is \"π - NAME - DIR\", or \"π - DIR\" until the
session has a name, so this returns NAME or \"\"."
  (cond ((not (stringp title)) "")
        ((string-match "\\`\\(?:π\\|pi\\) - \\(.+\\)\\'" title)
         (string-join (butlast (split-string (match-string 1 title) " - ")) " - "))
        (t (replace-regexp-in-string "\\`[^[:alnum:][:space:]]\\{1,2\\} +" "" title))))

(defun seance--agent-title (agent)
  "Return the terminal title of AGENT's buffer, or the empty string."
  (seance--clean-title (with-current-buffer (seance-agent-buffer agent)
                         (and (boundp 'ghostel-title) ghostel-title))))

(defvar-local seance--base-name nil
  "Buffer name, without the asterisks, that `seance-launch' gave this buffer.")

(defconst seance--generic-titles '("Claude Code" "pi")
  "Terminal titles that say nothing about what the agent is doing.")

(defun seance--buffer-name (title)
  "Return the agent buffer name for terminal TITLE.
A `ghostel-buffer-name-function' for buffers made by `seance-launch'."
  (let ((topic (string-trim (seance--clean-title title))))
    (if (or (string-empty-p topic) (member topic seance--generic-titles))
        (format "*%s*" seance--base-name)
      (format "*%s - %s*" seance--base-name
              (truncate-string-to-width topic 40 nil nil t)))))

(defun seance--agent-summary (agent)
  "Return what AGENT is blocked on, or else its terminal title."
  (or (seance-agent-message agent) (seance--agent-title agent)))

(defun seance--annotation ()
  "Return the current buffer's agent status for ghostel's buffer pickers.
The value of `ghostel-annotation-function' in tracked buffers."
  (when-let* ((agent (and seance--id (gethash seance--id seance--agents))))
    (seance--status-label (seance-agent-status agent))))

(defun seance--format-tokens (tokens)
  "Return TOKENS as a short count such as 812, 52k or 1.2M."
  (cond ((< tokens 1000) (format "%d" tokens))
        ((< tokens 999500) (format "%dk" (round tokens 1000)))
        (t (format "%.1fM" (/ tokens 1e6)))))

(defun seance--format-context (agent)
  "Return AGENT's context use such as \"52k 26%\", or the empty string."
  (let ((tokens (seance-agent-context-tokens agent))
        (percent (seance-agent-context-percent agent)))
    (string-join (delq nil (list (and (numberp tokens) (seance--format-tokens tokens))
                                 (and (numberp percent) (format "%d%%" (round percent)))))
                 " ")))

(defun seance--entry (agent)
  "Return the `tabulated-list-entries' entry for AGENT."
  (list (seance-agent-id agent)
        (vector (seance--status-label (seance-agent-status agent))
                (buffer-name (seance-agent-buffer agent))
                (or (seance-agent-model agent) "")
                (seance--format-context agent)
                (abbreviate-file-name (or (seance-agent-cwd agent) ""))
                (seance--format-age (- (float-time) (seance-agent-changed agent)))
                (seance--agent-summary agent))))

(defun seance--populate ()
  "Fill `tabulated-list-entries' with the current agents."
  (setq tabulated-list-entries (mapcar #'seance--entry (seance--sorted-agents))))

(defun seance--redraw-board (board)
  "Refill the rows of BOARD, the board buffer."
  (with-current-buffer board
    (when (derived-mode-p 'seance-list-mode)
      (seance--populate)
      (tabulated-list-print t)
      ;; hl-line moves its overlay only after a command, not a redraw.
      (when hl-line-mode
        (hl-line-highlight)))))

(defun seance--refresh ()
  "Redraw the board, fit its popup to the agents, and update mode lines."
  (when-let* ((board (get-buffer seance-buffer-name)))
    (seance--redraw-board board)
    (dolist (window (get-buffer-window-list board nil t))
      (when (window-parameter window 'seance-popup)
        (seance--fit-popup window))))
  (force-mode-line-update t))

(defvar seance--refresh-timer nil
  "Timer that redraws the board while it is shown.")

(defun seance--refresh-tick ()
  "Redraw the board if it is shown; stop the timer once it is killed.
Only agent events add or remove rows, so this leaves the popup's size
alone, in case you have resized it."
  (let ((board (get-buffer seance-buffer-name)))
    (cond ((not board) (seance--stop-refresh-timer))
          ((get-buffer-window board t) (seance--redraw-board board)))))

(defun seance--stop-refresh-timer ()
  "Stop redrawing the board on a timer."
  (when seance--refresh-timer
    (cancel-timer seance--refresh-timer)
    (setq seance--refresh-timer nil)))

(defun seance--fit-popup (window)
  "Shrink or grow WINDOW to fit the board, up to half the frame."
  (fit-window-to-buffer window (/ (frame-height (window-frame window)) 2)))

(defun seance--list-agent ()
  "Return the live agent on the current line of the board."
  (let ((agent (gethash (tabulated-list-get-id) seance--agents)))
    (unless (and agent (buffer-live-p (seance-agent-buffer agent)))
      (user-error "No agent on this line"))
    agent))

(defun seance-list-kill ()
  "Kill the agent on the current line, after confirming."
  (interactive)
  (let ((buffer (seance-agent-buffer (seance--list-agent))))
    (when (yes-or-no-p (format "Kill agent in %s? " (buffer-name buffer)))
      ;; Already confirmed, so skip the running-process query.
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))
      (seance--refresh))))

(defun seance-list-visit ()
  "Switch to the agent on the current line."
  (interactive)
  (let ((agent (seance--list-agent)))
    (when (window-parameter nil 'seance-popup)
      (quit-window))
    (pop-to-buffer (seance-agent-buffer agent) display-buffer--same-window-action)))

(defvar-keymap seance-list-mode-map
  :parent tabulated-list-mode-map
  "RET" #'seance-list-visit
  "o" #'seance-list-visit
  "k" #'seance-list-kill)

(define-derived-mode seance-list-mode tabulated-list-mode "Seance"
  "Major mode for the agent board."
  (setq tabulated-list-format [("Status" 8 nil)
                               ("Buffer" 24 nil)
                               ("Model" 14 nil)
                               ("Context" 9 nil)
                               ("Directory" 32 nil)
                               ("Since" 6 nil)
                               ("Title" 0 nil)])
  (setq tabulated-list-padding 1)
  (hl-line-mode 1)
  (add-hook 'tabulated-list-revert-hook #'seance--populate nil t)
  (tabulated-list-init-header)
  (when (and seance-refresh-interval (not seance--refresh-timer))
    (setq seance--refresh-timer
          (run-with-timer seance-refresh-interval seance-refresh-interval
                          #'seance--refresh-tick))))

;;;###autoload
(defun seance ()
  "Pop up the agent board at the bottom of the frame, like `bs-show'.
Visiting an agent closes the board and shows the agent in the window
it was called from.  Customize `display-buffer-alist' to place the
board elsewhere."
  (interactive)
  (let ((board (get-buffer-create seance-buffer-name)))
    (with-current-buffer board
      ;; Every time, so the column layout matches this version of the code.
      (seance-list-mode))
    (seance--redraw-board board)
    (let* ((windows (window-list nil 'no-minibuf))
           (window (display-buffer board '((display-buffer-reuse-window
                                            display-buffer-at-bottom)
                                           (window-height . seance--fit-popup)))))
      (when window
        (unless (memq window windows)
          (set-window-parameter window 'seance-popup t))
        (select-window window)))))

;;;###autoload
(defun seance-next ()
  "Switch to the agent that has waited longest for attention.
Blocked agents come before agents that have finished."
  (interactive)
  (if-let* ((agent (seq-find (lambda (agent)
                               (and (memq (seance-agent-status agent) '(blocked done))
                                    (not (eq (seance-agent-buffer agent) (current-buffer)))))
                             (seance--sorted-agents))))
      (pop-to-buffer (seance-agent-buffer agent))
    (message "No agents need attention")))

(defun seance--read-json-file (file)
  "Return the JSON object in FILE as an alist, or nil if it can't be read."
  (when (file-readable-p file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'alist
                           :null-object :null :false-object :false)))))

(defun seance--claude-statusline (directory)
  "Return the statusLine setting Claude Code would use in DIRECTORY.
Looks in the project's local and shared settings, then the user's, and
returns the first statusLine found as an alist, or nil."
  (let ((config (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude")))
    (seq-some (lambda (file)
                (let ((statusline (alist-get 'statusLine (seance--read-json-file file))))
                  (and (consp statusline) statusline)))
              (list (expand-file-name ".claude/settings.local.json" directory)
                    (expand-file-name ".claude/settings.json" directory)
                    (expand-file-name "settings.json" config)))))

(defun seance--claude-settings (directory)
  "Return the --settings JSON that wraps the status line in DIRECTORY.
The status line command becomes bin/seance-statusline, given the
command from the user's own statusLine setting, if any, to run.  The
setting's other keys, such as padding, are kept."
  (let* ((statusline (seance--claude-statusline directory))
         (command (alist-get 'command statusline))
         (wrapper (shell-quote-argument
                   (expand-file-name "bin/seance-statusline" seance--root))))
    (json-serialize
     `((statusLine
        . ((type . "command")
           ,@(seq-remove (lambda (entry) (memq (car entry) '(type command)))
                         statusline)
           (command . ,(if (and (stringp command) (not (string-empty-p command)))
                           (concat wrapper " " (shell-quote-argument command))
                         wrapper)))))
     :null-object :null :false-object :false)))

(defun seance--integration-args (program &optional directory)
  "Return arguments that load seance's integration into PROGRAM.
PROGRAM is matched by its file name: claude or pi.  DIRECTORY is where
it will run, used to find Claude Code's project settings.  Returns nil
for other programs, or when the integration files are missing."
  (let ((plugin (expand-file-name ".claude-plugin/plugin.json" seance--root))
        (extension (expand-file-name "pi/seance.ts" seance--root)))
    (pcase (file-name-nondirectory program)
      ("claude" (when (file-exists-p plugin)
                  (append (list "--plugin-dir" (directory-file-name seance--root))
                          (and seance-claude-statusline
                               (list "--settings"
                                     (seance--claude-settings
                                      (or directory default-directory)))))))
      ("pi" (when (file-exists-p extension)
              (list "-e" extension))))))

(defvar seance--agent-history nil
  "Minibuffer history of agent names for `seance-launch'.")

(defun seance--read-agent ()
  "Read the name of an agent in `seance-agent-commands'."
  (let ((default (or (car seance--agent-history)
                     (caar seance-agent-commands))))
    (completing-read (format-prompt "Agent" default)
                     seance-agent-commands nil t nil
                     'seance--agent-history default)))

(defun seance--launch-directory (&optional choose)
  "Return the directory to launch an agent in.
That is the current project's root, unless CHOOSE is non-nil or there
is no current project, in which case ask for a project."
  (or (and (not choose)
           (when-let* ((project (project-current)))
             (project-root project)))
      (project-prompt-project-dir)))

;;;###autoload
(defun seance-launch (agent directory)
  "Start AGENT in a new ghostel terminal in DIRECTORY.
AGENT is a name in `seance-agent-commands'.  Interactively, DIRECTORY
is the current project's root; with a prefix argument, or outside a
project, choose a project.  Returns the new buffer."
  (interactive (list (seance--read-agent)
                     (seance--launch-directory current-prefix-arg)))
  (unless (fboundp 'ghostel-exec)
    (require 'ghostel))
  (let* ((command (or (cdr (assoc agent seance-agent-commands))
                      (user-error "Unknown agent: %s" agent)))
         (directory (file-name-as-directory (expand-file-name directory)))
         (base (format "%s: %s" agent
                       (file-name-nondirectory (directory-file-name directory))))
         (buffer (generate-new-buffer (format "*%s*" base))))
    (with-current-buffer buffer
      (setq default-directory directory)
      ;; Before display, so `display-buffer-alist' rules can match the mode.
      (ghostel-mode)
      (when seance-rename-buffers
        (setq-local seance--base-name base
                    ghostel-buffer-name-function #'seance--buffer-name)))
    ;; Display first, so the terminal is sized to its window.
    (pop-to-buffer buffer (append display-buffer--same-window-action
                                  '((category . comint))))
    (condition-case err
        (ghostel-exec buffer (car command)
                      (append (and seance-load-integrations
                                   (seance--integration-args (car command) directory))
                              (cdr command)))
      ((error quit)
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    buffer))

(defun seance--tag-terminal ()
  "Give the terminal about to spawn in this buffer a fresh SEANCE_ID."
  (when seance--id
    (remhash seance--id seance--agents))
  (setq seance--id (number-to-string (cl-incf seance--next-id)))
  (setenv "SEANCE_ID" seance--id))

(defun seance--forget-current-buffer ()
  "Stop tracking the agent in the buffer being killed."
  (when seance--id
    (remhash seance--id seance--agents)
    (seance--refresh)))

(defun seance--mark-seen (&rest _)
  "Mark a finished agent idle once its buffer is selected."
  (when-let* ((id (buffer-local-value 'seance--id (window-buffer (selected-window))))
              (agent (gethash id seance--agents))
              ((eq (seance-agent-status agent) 'done)))
    (seance--set-status agent 'idle)
    (seance--refresh)))

(defun seance--read-agent-buffer (prompt)
  "Read the name of an agent buffer with PROMPT and return the buffer.
Candidates are ordered by need for attention, and annotated with the
agent's status, terminal title and directory.  The default is the first
one that is not the current buffer."
  (let* ((agents (or (seance--sorted-agents) (user-error "No agents")))
         (table (mapcar (lambda (agent)
                          (cons (buffer-name (seance-agent-buffer agent)) agent))
                        agents))
         (width (apply #'max (mapcar (lambda (entry) (string-width (car entry)))
                                     table)))
         (annotate
          (lambda (name)
            (when-let* ((agent (cdr (assoc name table))))
              (concat (make-string (- (1+ width) (string-width name)) ?\s)
                      (string-pad (seance--status-label (seance-agent-status agent)) 8)
                      (truncate-string-to-width (seance--agent-summary agent) 40
                                                nil ?\s t)
                      "  "
                      (abbreviate-file-name (or (seance-agent-cwd agent) ""))))))
         (collection
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata (category . buffer)
                           (annotation-function . ,annotate)
                           (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action table string pred))))
         (default (car (or (seq-find (lambda (entry)
                                       (not (eq (seance-agent-buffer (cdr entry))
                                                (current-buffer))))
                                     table)
                           (car table))))
         (name (completing-read (format-prompt prompt default)
                                collection nil t nil nil default)))
    (seance-agent-buffer (cdr (assoc name table)))))

;;;###autoload
(defun seance-switch-to-agent (buffer)
  "Switch to the agent BUFFER.
Interactively, choose from the tracked agents, the ones most in need of
attention first."
  (interactive (list (seance--read-agent-buffer "Agent")))
  (pop-to-buffer buffer (append display-buffer--same-window-action
                                '((category . comint)))))

(defvar-keymap seance-command-map
  "a" #'seance-launch
  "b" #'seance-switch-to-agent
  "l" #'seance
  "C-b" #'seance
  "n" #'seance-next)

;;;###autoload
(define-minor-mode seance-mode
  "Track AI agents running in ghostel buffers.
Only terminals spawned while this mode is on are tracked."
  :global t
  :lighter (:eval (seance--mode-line))
  (if seance-mode
      (progn
        (when (and seance-start-server (not (server-running-p)))
          (server-start))
        (add-hook 'ghostel-pre-spawn-hook #'seance--tag-terminal)
        (add-hook 'kill-buffer-hook #'seance--forget-current-buffer)
        (add-hook 'window-selection-change-functions #'seance--mark-seen)
        (add-hook 'window-buffer-change-functions #'seance--mark-seen)
        (advice-add 'ghostel--on-user-input :after #'seance--note-input))
    (advice-remove 'ghostel--on-user-input #'seance--note-input)
    (seance--stop-refresh-timer)
    (remove-hook 'ghostel-pre-spawn-hook #'seance--tag-terminal)
    (remove-hook 'kill-buffer-hook #'seance--forget-current-buffer)
    (remove-hook 'window-selection-change-functions #'seance--mark-seen)
    (remove-hook 'window-buffer-change-functions #'seance--mark-seen)))

(provide 'seance)
;;; seance.el ends here
