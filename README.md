# seance

A status board for Claude Code and Pi sessions running in
[ghostel](https://github.com/dakra/ghostel) buffers. It uses Claude Code
hooks and `emacsclient`; there is no server or multiplexer to run.

- `M-x seance` lists each agent with its status (blocked, done, working,
  idle), buffer, topic (the terminal title Claude Code sets, or a Pi
  session's `/name`), model, context
  used (`52k 26%`), directory and time in its current state. A blocked
  agent shows what it is waiting for in place of its title. The board pops
  up at the bottom of the frame; `RET` visits the agent in the window you
  came from, `k` kills it and `q` closes the board.
- `M-x seance-launch` starts Claude Code or Pi in a new ghostel buffer at
  the current project's root. With a prefix argument, or outside a project,
  it asks for a project.
- `M-x seance-next` visits the agent that has waited longest: blocked ones
  first, then finished ones.
- `M-x seance-switch-to-agent` picks an agent buffer with
  `completing-read`, showing status, title and directory, most urgent
  first. Ghostel's own pickers (`ghostel-list-buffers`, `ghostel-project`)
  also show agent status.
- The mode line shows `[2 blocked, 1 done]` when an agent needs you.
- You get a message when an agent blocks or finishes and its buffer isn't
  in the selected window. A finished agent returns to idle once you view
  its buffer.

## How it works

1. `seance-mode` adds a `ghostel-pre-spawn-hook` that gives each new
   ghostel terminal a unique `SEANCE_ID` environment variable.
2. `claude` started in that terminal inherits it, and so do its hooks.
3. `bin/seance-hook` (run by the Claude plugin in `hooks/hooks.json`, or by
   `pi/seance.ts`) trims the hook's JSON input with `jq` and sends it to
   Emacs with `emacsclient --eval '(seance-report ID JSON)'`.

| Hook event           | Status                                      |
|----------------------|---------------------------------------------|
| `SessionStart`       | idle                                        |
| `UserPromptSubmit`   | working                                     |
| `PostToolUse`        | working (clears blocked after approval)     |
| `PostToolUseFailure` | working                                     |
| `Notification`       | blocked, when it asks for permission        |
| `Stop`               | done                                        |
| `StopFailure`        | done (the turn ended on an API error)       |
| `Interrupt` (Pi)     | idle (you aborted the run)                  |
| `SessionEnd`         | removed, unless after `/clear` or `/resume` |

Claude Code runs no hook when you interrupt a turn, so seance also
watches what you type into an agent's buffer. Esc or C-c sets a blocked or
working agent to idle, and any other key sets a blocked agent to working,
since you've answered its prompt. These are guesses; the agent's next hook
event replaces them. One case stays wrong: if you turn down a permission
prompt by picking "No" rather than pressing Esc, the agent shows as working
until you send it a new prompt.

Programs an agent runs inherit its `SEANCE_ID`, so an agent it starts
itself, such as `claude -p` in a script, reports under the same ID. Each
report carries the agent's process ID (`CLAUDE_PID` for Claude Code), and
Emacs ignores reports from another process while the agent's own is still
running.

Sessions outside a seance-tagged ghostel buffer have no `SEANCE_ID`, so the
hook exits immediately. It always exits 0 and times out after 5 seconds, so
a missing Emacs server never blocks the agent.

Hooks don't carry the model or context use, so those come from elsewhere:

- Claude Code: `bin/seance-statusline` runs as the session's status line.
  Claude Code passes it the model and context window usage after every
  message; it forwards changes to Emacs, then runs your own status line
  command so that still shows.
- Pi: `pi/seance.ts` reads `ctx.model` and `ctx.getContextUsage()` after
  every turn and on model switch.

Both columns are blank until the first reply, and again just after a
compaction.

## Requirements

- Emacs 29.1+, ghostel, `jq`, `timeout` (coreutils).
- An Emacs server. `seance-mode` starts one unless `seance-start-server`
  is nil.

## Install

```elisp
(use-package seance
  :vc (:url "https://github.com/lukejewers/seance")
  :after ghostel
  :bind-keymap ("C-c a" . seance-command-map)
  :config
  (seance-mode 1))
```

| Key         | Command                   |
|-------------|---------------------------|
| `C-c a a`   | `seance-launch`           |
| `C-c a b`   | `seance-switch-to-agent`  |
| `C-c a l`   | `seance` (the board)      |
| `C-c a C-b` | `seance` (alias)          |
| `C-c a n`   | `seance-next`             |

Only terminals spawned after `seance-mode` is enabled are tracked.

Agents started with `seance-launch` need no further setup. For that session
only, Claude Code gets this checkout as a plugin (`--plugin-dir`) and
`bin/seance-statusline` as its status line (`--settings`, wrapping the
`statusLine` from your project or user settings); Pi gets `pi/seance.ts`
(`-e`).

### Agents started by hand

To track agents you start yourself in a ghostel terminal, install the
integrations once. They do nothing outside a seance-tagged terminal.

- Claude Code (the repo is its own plugin marketplace):

  ```sh
  claude plugin marketplace add lukejewers/seance
  claude plugin install seance@seance
  ```

- Pi (the repo is a Pi package):

  ```sh
  pi install git:github.com/lukejewers/seance
  ```

Then set `seance-load-integrations` to nil so launched agents don't load
them twice.

A plugin can't set a status line, so for the Model and Context columns,
point `statusLine` in `~/.claude/settings.json` at the wrapper, passing your
own status line command (if any) as its argument:

```json
"statusLine": {
  "type": "command",
  "command": "~/projects/seance/bin/seance-statusline '~/bin/my-statusline'"
}
```

## Customising

- `seance-agent-commands`: agents offered by `seance-launch`, as
  `(NAME PROGRAM ARGS...)`. Defaults to `claude` and `pi`. The program runs
  without a shell, so it must be on `exec-path`. Its buffer closes when the
  agent exits, unless `ghostel-kill-buffer-on-exit` is nil.
- `seance-load-integrations`: whether `seance-launch` passes the plugin and
  extension flags. Default t.
- `seance-claude-statusline`: whether `seance-launch` wraps Claude Code's
  status line to fill the Model and Context columns. Default t.
- `seance-notify-function`: called with a `seance-agent` struct. The default
  echoes a message; `notify-send` or `alert` work too.
- `seance-notify-statuses`: statuses that notify. Default `(blocked done)`.
- `seance-refresh-interval`: seconds between redraws of the board while
  it's shown, which keeps the Since column current. Default 10; nil
  redraws only when an agent reports something.

## Development

```sh
make check
```

Byte-compiles the package and tests with warnings as errors, then runs the
ERT suite, which includes end-to-end runs of the hook and status line
scripts against a fake `emacsclient`.
